using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace SysInfo.Native;

/// <summary>
/// Process list with CPU % since the previous sample, for the System module (helper of the host, §4.6): a loop over
/// 500+ processes costs ~40 ms in PowerShell, ~3 ms here. One instance per caller ($script:), so that each runspace
/// has its own previous sample. Linux: /proc/&lt;pid&gt;/stat only (one read per process). Windows: Process.
/// The module keeps a PowerShell fallback for pwsh on its own.
/// <see cref="Shared"/> is one sample for every module of the app (System and Performance read the same processes).
/// </summary>
public sealed class ProcessSampler
{
    private Dictionary<int, double> _previous = [];
    private DateTime _previousAt;

    private static readonly ProcessSampler SharedSampler = new();
    private static readonly System.Threading.Lock SharedLock = new();
    private static ProcessSample[]? _shared;
    private static DateTime _sharedAt;
    private static bool _sharedHasCpu;

    /// <summary>
    /// Sample shared by the runspaces of the app: reused while younger than <paramref name="maxAgeMs"/>, unless it is a
    /// first sample (no CPU % yet). CPU % is measured since the previous shared sample.
    /// </summary>
    public static ProcessSample[] Shared(int maxAgeMs = 1500)
    {
        lock (SharedLock)
        {
            var now = DateTime.UtcNow;
            if (_shared is not null && _sharedHasCpu && (now - _sharedAt).TotalMilliseconds < maxAgeMs)
                return _shared;
            _sharedHasCpu = SharedSampler._previousAt != default;   // a first sample has no CPU %: not reused
            _shared = SharedSampler.Sample();
            _sharedAt = now;
            return _shared;
        }
    }

    /// <summary>All processes, worst CPU first (then memory). Cpu is null on the first sample.</summary>
    public ProcessSample[] Sample()
    {
        var now = DateTime.UtcNow;
        var raw = OperatingSystem.IsLinux() ? ReadLinux() : ReadDotNet();
        var elapsed = _previousAt == default ? 0 : (now - _previousAt).TotalMilliseconds;
        var logical = Environment.ProcessorCount;
        var current = new Dictionary<int, double>(raw.Count);

        var samples = new ProcessSample[raw.Count];
        for (var i = 0; i < raw.Count; i++)
        {
            var (id, name, cpuMs, memory) = raw[i];
            double? cpu = null;
            if (cpuMs >= 0)
            {
                current[id] = cpuMs;
                if (elapsed > 0 && _previous.TryGetValue(id, out var before))
                    cpu = Math.Round(Math.Max(0, 100 * (cpuMs - before) / (elapsed * logical)), 1);
            }
            samples[i] = new ProcessSample(name, id, cpu, memory);
        }
        _previous = current;
        _previousAt = now;

        Array.Sort(samples, (a, b) =>
        {
            var c = (b.Cpu ?? -1).CompareTo(a.Cpu ?? -1);
            return c != 0 ? c : b.Memory.CompareTo(a.Memory);
        });
        return samples;
    }

    // Program names of the processes whose comm is truncated, by PID.
    private Dictionary<int, string> _fullNames = [];

    private List<(int Id, string Name, double CpuMs, long Memory)> ReadLinux()
    {
        var page = Environment.SystemPageSize;
        var list = new List<(int, string, double, long)>(600);
        foreach (var dir in Directory.EnumerateDirectories("/proc"))
        {
            if (!int.TryParse(Path.GetFileName(dir), out var id))
                continue;
            string stat;
            try
            {
                stat = File.ReadAllText(dir + "/stat");
            }
            catch (IOException)
            {
                continue; // ended meanwhile
            }
            catch (UnauthorizedAccessException)
            {
                continue;
            }
            var open = stat.IndexOf('(');
            var close = stat.LastIndexOf(')');
            if (open < 0 || close < open)
                continue;
            var name = stat[(open + 1)..close];
            var fields = stat[(close + 2)..].Split(' ');
            if (fields.Length < 22)
                continue;
            // utime, stime in clock ticks (USER_HZ = 100); rss in pages.
            var cpuMs = (double.Parse(fields[11]) + double.Parse(fields[12])) * 10;
            var memory = long.Parse(fields[21]) * page;
            // comm is cut at 15 characters: take the program name from the command line then (kept per PID).
            if (name.Length == 15)
            {
                if (!_fullNames.TryGetValue(id, out var known) || !known.StartsWith(name, StringComparison.Ordinal))
                    _fullNames[id] = known = FullName(dir) ?? name;
                name = known;
            }
            list.Add((id, name, cpuMs, memory));
        }
        if (_fullNames.Count > 2 * list.Count + 100)
            _fullNames = list.Where(p => _fullNames.ContainsKey(p.Item1)).ToDictionary(p => p.Item1, p => _fullNames[p.Item1]);
        return list;
    }

    private static string? FullName(string dir)
    {
        try
        {
            var cmdline = File.ReadAllText(dir + "/cmdline");
            var first = cmdline.Split('\0', 2)[0];
            var file = Path.GetFileName(first.Split(' ', 2)[0]);
            return string.IsNullOrEmpty(file) ? null : file;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static List<(int Id, string Name, double CpuMs, long Memory)> ReadDotNet()
    {
        var list = new List<(int, string, double, long)>(300);
        foreach (var p in Process.GetProcesses())
        {
            using (p)
            {
                double cpu;
                try
                {
                    cpu = p.TotalProcessorTime.TotalMilliseconds;
                }
                catch (Exception)
                {
                    cpu = -1; // system process without rights: no CPU %
                }
                try
                {
                    list.Add((p.Id, p.ProcessName, cpu, p.WorkingSet64));
                }
                catch (InvalidOperationException)
                {
                    // ended meanwhile
                }
            }
        }
        return list;
    }
}

/// <summary>One process: same property names as the System module's own objects.</summary>
public sealed record ProcessSample(string Name, int Id, double? Cpu, long Memory)
{
    /// <summary>
    /// Processes grouped by name (a browser = one line for all its processes), worst CPU first, for the Performance
    /// module: CPU % summed, memory summed, number of processes.
    /// </summary>
    public static ProcessGroup[] GroupByName(ProcessSample[] samples) =>
        [.. samples.GroupBy(s => s.Name)
            .Select(g => new ProcessGroup(g.Key, g.Count(), Math.Round(g.Sum(s => s.Cpu ?? 0), 1), g.Sum(s => s.Memory)))
            .OrderByDescending(g => g.Cpu).ThenByDescending(g => g.Memory)];

    /// <summary>Groups by name, then the <paramref name="byCpu"/> heaviest by CPU and <paramref name="byMemory"/> by memory.</summary>
    public static ProcessGroup[] Heaviest(ProcessSample[] samples, int byCpu, int byMemory)
    {
        var groups = GroupByName(samples);
        return [.. groups.Take(byCpu).Union(groups.OrderByDescending(g => g.Memory).Take(byMemory))];
    }
}

/// <summary>Processes of the same name: count, CPU % (whole machine) and memory (bytes), summed.</summary>
/// <remarks>
/// <see cref="Heaviest"/> keeps, per sample, the groups the Performance module records: the first by CPU and the first
/// by memory (a group in both lists once).
/// </remarks>
public sealed record ProcessGroup(string Name, int Count, double Cpu, long Memory);
