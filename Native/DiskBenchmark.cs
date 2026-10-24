using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SysInfo.Native;

/// <summary>
/// Disk mini-benchmark for the Performance module (performance_benchmark_disk, helper of the host, §4.6): sequential
/// write then read of a test file, then random 4 KiB reads (queue depth 1). The work is cut in steps
/// (<see cref="WriteNext"/>, <see cref="ReadNext"/>, <see cref="RandomNext"/>) so that the module reports progress and
/// can be stopped between two steps. The file is deleted by <see cref="Dispose"/>.
/// The OS cache must not answer the reads: Windows opens the file without buffering (FILE_FLAG_NO_BUFFERING, aligned
/// buffers); Linux writes through the cache, syncs, then drops the file's pages (posix_fadvise DONTNEED, no root needed).
/// </summary>
public sealed class DiskBenchmark : IDisposable
{
    private const int Block = 4 * 1024 * 1024;   // sequential step
    private const int Small = 4096;              // random read size
    private const FileOptions NoBuffering = (FileOptions)0x20000000;

    private readonly SafeFileHandle _file;
    private readonly byte[] _memory;
    private readonly int _align;   // start of the 4 KiB-aligned area in _memory
    private readonly long _size;
    private long _offset;
    private readonly Stopwatch _clock = new();
    private readonly List<double> _latencies = [];
    private readonly Random _random = new(42);

    public DiskBenchmark(string path, long sizeBytes)
    {
        Path = path;
        _size = sizeBytes / Block * Block;
        if (_size <= 0)
            throw new ArgumentOutOfRangeException(nameof(sizeBytes));
        var options = OperatingSystem.IsWindows() ? NoBuffering | FileOptions.WriteThrough : FileOptions.None;
        _file = File.OpenHandle(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, options);
        // Pinned, so that its 4 KiB-aligned part keeps its address (unbuffered I/O needs aligned buffers).
        _memory = GC.AllocateArray<byte>(Block + Small, pinned: true);
        _align = (int)((Small - Marshal.UnsafeAddrOfPinnedArrayElement(_memory, 0) % Small) % Small);
        // Random data: some SSD controllers compress, zeros would flatter them.
        _random.NextBytes(Buffer(Block));
    }

    public string Path { get; }

    /// <summary>Share of the current phase done, 0 to 100.</summary>
    public double Percent { get; private set; }

    public double? WriteBytesPerSecond { get; private set; }
    public double? ReadBytesPerSecond { get; private set; }

    /// <summary>Random 4 KiB reads: average and 95th percentile latency (ms), operations per second.</summary>
    public double? RandomAverageMs => _latencies.Count == 0 ? null : _latencies.Average();
    public double? RandomP95Ms => _latencies.Count == 0 ? null : _latencies.Order().ElementAt((int)(_latencies.Count * 0.95));
    public double? RandomIops => _latencies.Count == 0 ? null : 1000 / _latencies.Average();

    /// <summary>Writes the next block; false when the file is complete (then synced, timed, and its cache dropped).</summary>
    public bool WriteNext()
    {
        if (_offset == 0)
            _clock.Restart();
        if (_offset < _size)
        {
            RandomAccess.Write(_file, Buffer(Block), _offset);
            _offset += Block;
            Percent = 100.0 * _offset / _size;
            return true;
        }
        RandomAccess.FlushToDisk(_file);
        _clock.Stop();
        WriteBytesPerSecond = _size / _clock.Elapsed.TotalSeconds;
        DropCache();
        _offset = 0;
        Percent = 0;
        return false;
    }

    /// <summary>Reads the next block; false when the whole file was read.</summary>
    public bool ReadNext()
    {
        if (_offset == 0)
            _clock.Restart();
        if (_offset < _size)
        {
            RandomAccess.Read(_file, Buffer(Block), _offset);
            _offset += Block;
            Percent = 100.0 * _offset / _size;
            return true;
        }
        _clock.Stop();
        ReadBytesPerSecond = _size / _clock.Elapsed.TotalSeconds;
        DropCache();
        _offset = 0;
        Percent = 0;
        return false;
    }

    /// <summary>Runs <paramref name="count"/> random 4 KiB reads; false once <paramref name="total"/> reads are done.</summary>
    public bool RandomNext(int count, int total)
    {
        if (_latencies.Count >= total)
            return false;
        Advise(1 /* POSIX_FADV_RANDOM: no read-ahead */);
        var blocks = _size / Small;
        for (var i = 0; i < count && _latencies.Count < total; i++)
        {
            var offset = _random.NextInt64(blocks) * Small;
            var start = Stopwatch.GetTimestamp();
            RandomAccess.Read(_file, Buffer(Small), offset);
            _latencies.Add(Stopwatch.GetElapsedTime(start).TotalMilliseconds);
        }
        Percent = 100.0 * _latencies.Count / total;
        return true;
    }

    private Span<byte> Buffer(int length) => _memory.AsSpan(_align, length);

    // Linux: drop the file's pages from the page cache, so that the next reads come from the disk.
    private void DropCache()
    {
        if (OperatingSystem.IsWindows())
            return;
        RandomAccess.FlushToDisk(_file);
        Advise(4 /* POSIX_FADV_DONTNEED */);
    }

    private void Advise(int advice)
    {
        if (OperatingSystem.IsLinux())
            posix_fadvise((int)_file.DangerousGetHandle(), 0, 0, advice);
    }

    [DllImport("libc", SetLastError = true)]
    private static extern int posix_fadvise(int fd, long offset, long length, int advice);

    public void Dispose()
    {
        _file.Dispose();
        try
        {
            File.Delete(Path);
        }
        catch (IOException)
        {
        }
    }
}
