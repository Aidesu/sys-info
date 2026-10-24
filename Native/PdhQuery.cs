using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SysInfo.Native;

/// <summary>
/// Windows performance counters through PDH (pdh.dll), for the Performance and Sensors modules (helper of the host,
/// §4.6): the query is opened once and collected at each refresh, ~1 ms, where Get-Counter takes ~1 s and a
/// Win32_PerfFormattedData query ~100 ms. Counter paths are in English (PdhAddEnglishCounter: any display language).
/// Rate counters need two collections: the first <see cref="Collect"/> returns null for them.
/// A path with a wildcard instance (\Thermal Zone Information(*)\Temperature) is read with <see cref="Instances"/>,
/// after <see cref="Collect"/>.
/// </summary>
public sealed class PdhQuery : IDisposable
{
    private readonly IntPtr _query;
    private readonly IntPtr[] _counters;

    public PdhQuery(IReadOnlyList<string> paths)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("PDH : Windows uniquement.");
        if (PdhOpenQuery(null, IntPtr.Zero, out _query) != 0)
            throw new InvalidOperationException("PdhOpenQuery a échoué.");
        _counters = new IntPtr[paths.Count];
        for (var i = 0; i < paths.Count; i++)
        {
            // A counter missing on this machine (no thermal zone…) stays IntPtr.Zero: its value is null.
            if (PdhAddEnglishCounter(_query, paths[i], IntPtr.Zero, out var counter) == 0)
                _counters[i] = counter;
        }
        PdhCollectQueryData(_query);
    }

    /// <summary>One value per path, in order; null when the counter is missing or not ready.</summary>
    public double?[] Collect()
    {
        PdhCollectQueryData(_query);
        var values = new double?[_counters.Length];
        for (var i = 0; i < _counters.Length; i++)
        {
            if (_counters[i] != IntPtr.Zero
                && PdhGetFormattedCounterValue(_counters[i], FmtDouble | FmtNoCap100, out _, out var value) == 0
                && value.CStatus is 0 or 1)
                values[i] = value.DoubleValue;
        }
        return values;
    }

    /// <summary>Values of every instance of a wildcard path (index in the constructor), by instance name, as of the last <see cref="Collect"/>.</summary>
    public Dictionary<string, double> Instances(int index)
    {
        var result = new Dictionary<string, double>();
        if (_counters[index] == IntPtr.Zero)
            return result;
        uint size = 0, count = 0;
        if (PdhGetFormattedCounterArray(_counters[index], FmtDouble | FmtNoCap100, ref size, ref count, IntPtr.Zero) != MoreData)
            return result;
        var buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            if (PdhGetFormattedCounterArray(_counters[index], FmtDouble | FmtNoCap100, ref size, ref count, buffer) != 0)
                return result;
            var itemSize = Marshal.SizeOf<CounterValueItem>();
            for (var i = 0; i < count; i++)
            {
                var item = Marshal.PtrToStructure<CounterValueItem>(buffer + i * itemSize);
                if (item.Value.CStatus is 0 or 1 && Marshal.PtrToStringUni(item.Name) is { } name)
                    result[name] = item.Value.DoubleValue;
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
        return result;
    }

    public void Dispose() => PdhCloseQuery(_query);

    private const uint FmtDouble = 0x00000200;
    private const uint FmtNoCap100 = 0x00008000;
    private const uint MoreData = 0x800007D2;

    [StructLayout(LayoutKind.Explicit)]
    private struct CounterValue
    {
        [FieldOffset(0)] public uint CStatus;
        [FieldOffset(8)] public double DoubleValue;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CounterValueItem
    {
        public IntPtr Name;
        public CounterValue Value;
    }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhOpenQuery(string? dataSource, IntPtr userData, out IntPtr query);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr userData, out IntPtr counter);

    [DllImport("pdh.dll")]
    private static extern uint PdhCollectQueryData(IntPtr query);

    [DllImport("pdh.dll")]
    private static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out CounterValue value);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode, EntryPoint = "PdhGetFormattedCounterArrayW")]
    private static extern uint PdhGetFormattedCounterArray(IntPtr counter, uint format, ref uint bufferSize, ref uint itemCount, IntPtr items);

    [DllImport("pdh.dll")]
    private static extern uint PdhCloseQuery(IntPtr query);
}
