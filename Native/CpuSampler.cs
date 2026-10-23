using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace SysInfo.Native;

/// <summary>
/// CPU usage (total and per logical processor, since the previous sample) and current frequency, for the System
/// module (helper of the host, §4.6). Read straight from the kernel, without WMI (a Win32_PerfFormattedData query every
/// 2 s costs ~100 ms and loads the WMI service) and without PowerShell loops.
/// Linux: /proc/stat and /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq.
/// Windows: NtQuerySystemInformation(SystemProcessorPerformanceInformation) and CallNtPowerInformation(ProcessorInformation).
/// One instance per caller ($script:): each keeps its previous sample.
/// </summary>
public sealed class CpuSampler
{
    private (double Busy, double Total)[]? _previous;

    /// <summary>Usage since the previous call; null values on the first call (no reference yet).</summary>
    public CpuSample Sample()
    {
        var now = OperatingSystem.IsWindows() ? ReadWindows() : ReadLinux();
        var previous = _previous;
        _previous = now;
        if (previous is null || previous.Length != now.Length)
            return new CpuSample(null, []);

        double? Percent(int i)
        {
            var total = now[i].Total - previous[i].Total;
            return total <= 0 ? null : Math.Round(Math.Clamp(100 * (now[i].Busy - previous[i].Busy) / total, 0, 100), 1);
        }
        // Index 0 = whole machine, then one entry per logical processor.
        return new CpuSample(Percent(0), [.. Enumerable.Range(1, now.Length - 1).Select(i => Percent(i) ?? 0)]);
    }

    /// <summary>Average current frequency of the logical processors, in GHz; null when not exposed.</summary>
    public static double? FrequencyGHz()
    {
        if (OperatingSystem.IsWindows())
            return WindowsFrequency();
        var values = new List<double>();
        foreach (var dir in Directory.EnumerateDirectories("/sys/devices/system/cpu", "cpu*"))
        {
            try
            {
                var text = File.ReadAllText(Path.Combine(dir, "cpufreq", "scaling_cur_freq"));
                if (double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var khz))
                    values.Add(khz);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
        return values.Count == 0 ? null : values.Average() / 1e6;
    }

    // /proc/stat: "cpu  user nice system idle iowait irq softirq steal …", then "cpuN …".
    private static (double Busy, double Total)[] ReadLinux()
    {
        var list = new List<(double, double)>();
        foreach (var line in File.ReadLines("/proc/stat"))
        {
            if (!line.StartsWith("cpu", StringComparison.Ordinal))
                break;
            var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            double total = 0;
            for (var i = 1; i <= 8 && i < fields.Length; i++)
                total += double.Parse(fields[i], CultureInfo.InvariantCulture);
            var idle = double.Parse(fields[4], CultureInfo.InvariantCulture) + double.Parse(fields[5], CultureInfo.InvariantCulture);
            list.Add((total - idle, total));
        }
        return [.. list];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessorPerformance
    {
        public long IdleTime;
        public long KernelTime; // includes idle time
        public long UserTime;
        public long DpcTime;
        public long InterruptTime;
        public uint InterruptCount;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQuerySystemInformation(int infoClass, [Out] ProcessorPerformance[] info, int length, out int returned);

    private static (double Busy, double Total)[] ReadWindows()
    {
        var count = Environment.ProcessorCount;
        var info = new ProcessorPerformance[count];
        var size = Marshal.SizeOf<ProcessorPerformance>() * count;
        if (NtQuerySystemInformation(8 /* SystemProcessorPerformanceInformation */, info, size, out _) != 0)
            return [];
        var result = new (double Busy, double Total)[count + 1];
        for (var i = 0; i < count; i++)
        {
            double total = info[i].KernelTime + info[i].UserTime;
            var busy = total - info[i].IdleTime;
            result[i + 1] = (busy, total);
            result[0] = (result[0].Busy + busy, result[0].Total + total);
        }
        return result;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessorPowerInformation
    {
        public uint Number;
        public uint MaxMhz;
        public uint CurrentMhz;
        public uint MhzLimit;
        public uint MaxIdleState;
        public uint CurrentIdleState;
    }

    [DllImport("powrprof.dll")]
    private static extern uint CallNtPowerInformation(int level, IntPtr input, uint inputLength, [Out] ProcessorPowerInformation[] output, uint outputLength);

    private static double? WindowsFrequency()
    {
        var count = Environment.ProcessorCount;
        var info = new ProcessorPowerInformation[count];
        var size = (uint)(Marshal.SizeOf<ProcessorPowerInformation>() * count);
        if (CallNtPowerInformation(11 /* ProcessorInformation */, IntPtr.Zero, 0, info, size) != 0)
            return null;
        return info.Average(p => (double)p.CurrentMhz) / 1000;
    }
}

/// <summary>Total usage (%) and per logical processor; Total is null on the first sample.</summary>
public sealed record CpuSample(double? Total, double[] Cores);
