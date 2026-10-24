using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace SysInfo.Native;

/// <summary>
/// Live load of the machine for the Performance module (helper of the host, §4.6): memory, physical disks, network and
/// pressure, since the previous sample. One instance per caller ($script:), each keeps its previous counters.
/// Linux: /proc/meminfo, /proc/diskstats, /proc/net/dev, /proc/vmstat (swap in / out), /proc/pressure (PSI).
/// Windows: GlobalMemoryStatusEx, GetPerformanceInfo (commit), PDH counters (PhysicalDisk(_Total), Memory\Pages/sec,
/// System\Processor Queue Length) and NetworkInterface statistics. No WMI.
/// </summary>
public sealed class PerfSampler : IDisposable
{
    private Counters? _previous;
    private DateTime _previousAt;
    private PdhQuery? _pdh;

    private static readonly string[] WindowsCounters =
    [
        @"\PhysicalDisk(_Total)\% Idle Time",
        @"\PhysicalDisk(_Total)\Avg. Disk sec/Transfer",
        @"\PhysicalDisk(_Total)\Current Disk Queue Length",
        @"\PhysicalDisk(_Total)\Disk Read Bytes/sec",
        @"\PhysicalDisk(_Total)\Disk Write Bytes/sec",
        @"\Memory\Pages/sec",
        @"\System\Processor Queue Length",
    ];

    /// <summary>Load since the previous call; rates are null on the first call (no reference yet).</summary>
    public PerfSample Sample()
    {
        var now = DateTime.UtcNow;
        var memory = OperatingSystem.IsWindows() ? WindowsMemory() : LinuxMemory();
        var counters = new Counters { Network = ReadNetwork() };
        if (!OperatingSystem.IsWindows())
            ReadLinuxCounters(counters);

        var previous = _previous;
        var seconds = previous is null ? 0 : (now - _previousAt).TotalSeconds;
        _previous = counters;
        _previousAt = now;

        var sample = new PerfSample { Memory = memory };
        if (OperatingSystem.IsWindows())
        {
            _pdh ??= new PdhQuery(WindowsCounters);
            var v = _pdh.Collect();
            sample.DiskBusy = v[0] is { } idle ? Math.Round(Math.Clamp(100 - idle, 0, 100), 1) : null;
            sample.DiskLatencyMs = v[1] is { } sec ? Math.Round(sec * 1000, 2) : null;
            sample.DiskQueue = v[2];
            sample.DiskRead = v[3];
            sample.DiskWrite = v[4];
            sample.PagesPerSecond = v[5];
            sample.CpuQueue = v[6];
        }
        if (previous is null || seconds <= 0)
            return sample;

        double Rate(double now, double before) => Math.Max(0, now - before) / seconds;
        sample.NetReceive = Rate(counters.Network.Received, previous.Network.Received);
        sample.NetSend = Rate(counters.Network.Sent, previous.Network.Sent);
        sample.LinkSpeed = counters.Network.Speed;

        if (!OperatingSystem.IsWindows())
        {
            sample.DiskRead = Rate(counters.SectorsRead, previous.SectorsRead) * 512;
            sample.DiskWrite = Rate(counters.SectorsWritten, previous.SectorsWritten) * 512;
            // io_ticks: ms during which a disk had I/O in flight; the busiest disk gives the % (as iostat %util).
            sample.DiskBusy = counters.BusyMs.Count == 0 ? null : Math.Round(Math.Clamp(
                counters.BusyMs.Max(d => previous.BusyMs.TryGetValue(d.Key, out var b) ? d.Value - b : 0) / (seconds * 10), 0, 100), 1);
            var ios = counters.Ios - previous.Ios;
            sample.DiskLatencyMs = ios > 0 ? Math.Round((counters.IoMs - previous.IoMs) / ios, 2) : 0;
            sample.DiskQueue = Math.Round(Rate(counters.WeightedMs, previous.WeightedMs) / 1000, 2);
            sample.PagesPerSecond = Rate(counters.SwapPages, previous.SwapPages);
            sample.Pressure = ReadPressure();
        }
        return sample;
    }

    public void Dispose() => _pdh?.Dispose();

    private sealed class Counters
    {
        public (double Received, double Sent, double? Speed) Network;
        public double SectorsRead, SectorsWritten, Ios, IoMs, WeightedMs, SwapPages;
        public Dictionary<string, double> BusyMs = [];
    }

    // Physical interfaces only: no loopback, tunnels, bridges or container / VM interfaces (counted twice otherwise).
    private static (double Received, double Sent, double? Speed) ReadNetwork()
    {
        double received = 0, sent = 0, speed = 0;
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up
                || nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel
                || IsVirtual(nic))
                continue;
            try
            {
                var stats = nic.GetIPStatistics();
                received += stats.BytesReceived;
                sent += stats.BytesSent;
                if (nic.Speed > 0)
                    speed = Math.Max(speed, nic.Speed);
            }
            catch (Exception ex) when (ex is NetworkInformationException or PlatformNotSupportedException)
            {
            }
        }
        return (received, sent, speed > 0 ? speed : null);
    }

    private static bool IsVirtual(NetworkInterface nic)
    {
        if (OperatingSystem.IsLinux())
            return !Directory.Exists($"/sys/class/net/{nic.Name}/device");
        var d = nic.Description;
        return d.Contains("Virtual", StringComparison.OrdinalIgnoreCase) || d.Contains("Hyper-V", StringComparison.OrdinalIgnoreCase)
            || d.Contains("VPN", StringComparison.OrdinalIgnoreCase) || d.Contains("Loopback", StringComparison.OrdinalIgnoreCase);
    }

    private static void ReadLinuxCounters(Counters c)
    {
        // /proc/diskstats: major minor name reads merged sectors ms writes merged sectors ms in-flight io_ticks weighted …
        foreach (var line in File.ReadLines("/proc/diskstats"))
        {
            var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (f.Length < 14 || !IsPhysicalDisk(f[2]))
                continue;
            double F(int i) => double.Parse(f[i], CultureInfo.InvariantCulture);
            c.Ios += F(3) + F(7);
            c.SectorsRead += F(5);
            c.IoMs += F(6) + F(10);
            c.SectorsWritten += F(9);
            c.BusyMs[f[2]] = F(12);
            c.WeightedMs += F(13);
        }
        foreach (var line in File.ReadLines("/proc/vmstat"))
        {
            if (line.StartsWith("pswpin ", StringComparison.Ordinal) || line.StartsWith("pswpout ", StringComparison.Ordinal))
                c.SwapPages += double.Parse(line.AsSpan(line.IndexOf(' ') + 1), CultureInfo.InvariantCulture);
        }
    }

    // Whole disks with a device behind them (no partitions, loop, ram, zram, device-mapper).
    private static readonly Dictionary<string, bool> PhysicalCache = [];

    private static bool IsPhysicalDisk(string name)
    {
        if (PhysicalCache.TryGetValue(name, out var physical))
            return physical;
        physical = Directory.Exists($"/sys/block/{name}/device") && !name.StartsWith("zram", StringComparison.Ordinal);
        PhysicalCache[name] = physical;
        return physical;
    }

    // /proc/pressure/{cpu,memory,io}: "some avg10=…" = share of the last 10 s during which at least one task waited.
    private static PressureSample? ReadPressure()
    {
        double? Read(string resource, string kind)
        {
            try
            {
                foreach (var line in File.ReadLines($"/proc/pressure/{resource}"))
                {
                    if (!line.StartsWith(kind, StringComparison.Ordinal))
                        continue;
                    var start = line.IndexOf("avg10=", StringComparison.Ordinal) + 6;
                    var end = line.IndexOf(' ', start);
                    return double.Parse(line.AsSpan(start, end - start), CultureInfo.InvariantCulture);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
            return null;
        }
        var cpu = Read("cpu", "some");
        if (cpu is null)
            return null;
        return new PressureSample(cpu, Read("memory", "some"), Read("memory", "full"), Read("io", "some"), Read("io", "full"));
    }

    private static MemorySample LinuxMemory()
    {
        var info = new Dictionary<string, double>();
        foreach (var line in File.ReadLines("/proc/meminfo"))
        {
            var colon = line.IndexOf(':');
            var value = line.AsSpan(colon + 1).Trim();
            var space = value.IndexOf(' ');
            if (double.TryParse(space > 0 ? value[..space] : value, NumberStyles.Float, CultureInfo.InvariantCulture, out var kib))
                info[line[..colon]] = kib * 1024;
        }
        double Get(string key) => info.TryGetValue(key, out var v) ? v : 0;
        var strict = File.Exists("/proc/sys/vm/overcommit_memory") && File.ReadAllText("/proc/sys/vm/overcommit_memory").Trim() == "2";
        return new MemorySample(
            Get("MemTotal"), info.ContainsKey("MemAvailable") ? Get("MemAvailable") : Get("MemFree"),
            Get("SwapTotal"), Get("SwapFree"), Get("Committed_AS"), strict ? Get("CommitLimit") : null);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatusEx
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhys;
        public ulong AvailPhys;
        public ulong TotalPageFile;
        public ulong AvailPageFile;
        public ulong TotalVirtual;
        public ulong AvailVirtual;
        public ulong AvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PerformanceInformation
    {
        public uint Size;
        public nuint CommitTotal;
        public nuint CommitLimit;
        public nuint CommitPeak;
        public nuint PhysicalTotal;
        public nuint PhysicalAvailable;
        public nuint SystemCache;
        public nuint KernelTotal;
        public nuint KernelPaged;
        public nuint KernelNonpaged;
        public nuint PageSize;
        public uint HandleCount;
        public uint ProcessCount;
        public uint ThreadCount;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buffer);

    [DllImport("psapi.dll", SetLastError = true)]
    private static extern bool GetPerformanceInfo(out PerformanceInformation info, uint size);

    private static MemorySample WindowsMemory()
    {
        var status = new MemoryStatusEx { Length = (uint)Marshal.SizeOf<MemoryStatusEx>() };
        GlobalMemoryStatusEx(ref status);
        double? committed = null, limit = null;
        if (GetPerformanceInfo(out var perf, (uint)Marshal.SizeOf<PerformanceInformation>()))
        {
            committed = (double)perf.CommitTotal * perf.PageSize;
            limit = (double)perf.CommitLimit * perf.PageSize;
        }
        // Page file = commit limit − physical memory (TotalPageFile counts both).
        var swapTotal = Math.Max(0, (double)status.TotalPageFile - status.TotalPhys);
        var swapUsed = Math.Max(0, ((double)status.TotalPageFile - status.AvailPageFile) - ((double)status.TotalPhys - status.AvailPhys));
        return new MemorySample(status.TotalPhys, status.AvailPhys, swapTotal, Math.Max(0, swapTotal - swapUsed), committed ?? 0, limit);
    }
}

/// <summary>One sample of <see cref="PerfSampler"/>: bytes and bytes per second; null = not measured yet or not available.</summary>
public sealed class PerfSample
{
    public required MemorySample Memory { get; init; }
    public double? DiskBusy { get; set; }
    public double? DiskRead { get; set; }
    public double? DiskWrite { get; set; }
    public double? DiskLatencyMs { get; set; }
    public double? DiskQueue { get; set; }
    public double? NetReceive { get; set; }
    public double? NetSend { get; set; }
    /// <summary>Fastest link among the physical interfaces, in bit/s.</summary>
    public double? LinkSpeed { get; set; }
    /// <summary>Pages swapped in + out per second (Linux), hard page faults per second (Windows, Memory\Pages/sec).</summary>
    public double? PagesPerSecond { get; set; }
    /// <summary>Threads waiting for a processor (Windows).</summary>
    public double? CpuQueue { get; set; }
    /// <summary>Linux PSI (avg10, %); null elsewhere or on kernels without PSI.</summary>
    public PressureSample? Pressure { get; set; }
}

/// <summary>Memory in bytes; CommitLimit is null when the system does not enforce it (Linux without strict overcommit).</summary>
public sealed record MemorySample(double Total, double Available, double SwapTotal, double SwapFree, double Committed, double? CommitLimit);

/// <summary>Linux pressure stall information, avg10 in %.</summary>
public sealed record PressureSample(double? Cpu, double? MemorySome, double? MemoryFull, double? IoSome, double? IoFull);
