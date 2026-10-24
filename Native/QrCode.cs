using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace SysInfo.Native;

/// <summary>
/// QR code for the inventory label (module Inventaire, helper of the host, §4.6), without a NuGet dependency:
/// byte mode (UTF-8), error correction level M (15 % of the symbol can be damaged), versions 1 to 10 (up to 213 bytes),
/// mask chosen by the standard penalty rules (ISO/IEC 18004). <see cref="ToSvg"/> draws it with its quiet zone.
/// </summary>
public sealed class QrCode
{
    // Versions 1 to 10, level M: total codewords, error correction blocks, error correction codewords per block.
    private static readonly int[] TotalCodewords = [26, 44, 70, 100, 134, 172, 196, 242, 292, 346];
    private static readonly int[] Blocks = [1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
    private static readonly int[] EccPerBlock = [10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
    private static readonly int[][] AlignmentPositions =
    [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
    ];

    private readonly bool[,] _modules;     // [row, column], true = dark
    private readonly bool[,] _function;

    public int Version { get; }
    public int Size { get; }
    public int Mask { get; private set; }

    private QrCode(int version)
    {
        Version = version;
        Size = version * 4 + 17;
        _modules = new bool[Size, Size];
        _function = new bool[Size, Size];
    }

    /// <summary>Dark module at (row, column).</summary>
    public bool this[int row, int column] => _modules[row, column];

    /// <summary>Encodes the text (UTF-8); throws when it is longer than 213 bytes.</summary>
    public static QrCode Encode(string text)
    {
        var data = Encoding.UTF8.GetBytes(text);
        var version = 0;
        for (var v = 1; v <= 10; v++)
        {
            var capacityBits = (TotalCodewords[v - 1] - Blocks[v - 1] * EccPerBlock[v - 1]) * 8;
            var needed = 4 + (v < 10 ? 8 : 16) + data.Length * 8;
            if (needed <= capacityBits)
            {
                version = v;
                break;
            }
        }
        if (version == 0)
            throw new ArgumentException("Texte trop long pour le QR code (213 octets au plus).", nameof(text));

        var qr = new QrCode(version);
        qr.DrawFunctionPatterns();
        var codewords = AddErrorCorrection(version, DataCodewords(version, data));
        qr.DrawCodewords(codewords);

        // Mask with the lowest penalty.
        var best = 0;
        var bestPenalty = int.MaxValue;
        for (var mask = 0; mask < 8; mask++)
        {
            qr.ApplyMask(mask);
            qr.DrawFormatBits(mask);
            var penalty = qr.Penalty();
            if (penalty < bestPenalty)
            {
                best = mask;
                bestPenalty = penalty;
            }
            qr.ApplyMask(mask);   // XOR again: undo
        }
        qr.Mask = best;
        qr.ApplyMask(best);
        qr.DrawFormatBits(best);
        return qr;
    }

    /// <summary>SVG drawing, one unit per module, with a 4-module quiet zone; <paramref name="pixelSize"/> sets the displayed size.</summary>
    public string ToSvg(int pixelSize = 160)
    {
        var full = Size + 8;
        var path = new StringBuilder();
        for (var r = 0; r < Size; r++)
        {
            for (var c = 0; c < Size; c++)
            {
                if (_modules[r, c])
                    path.Append(CultureInfo.InvariantCulture, $"M{c + 4},{r + 4}h1v1h-1z");
            }
        }
        return $"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {full} {full}\" width=\"{pixelSize}\" height=\"{pixelSize}\" shape-rendering=\"crispEdges\">" +
               $"<rect width=\"{full}\" height=\"{full}\" fill=\"#fff\"/><path d=\"{path}\" fill=\"#000\"/></svg>";
    }

    // Data segment (byte mode), terminator, padding to the data capacity of the version.
    private static byte[] DataCodewords(int version, byte[] data)
    {
        var capacity = TotalCodewords[version - 1] - Blocks[version - 1] * EccPerBlock[version - 1];
        var bits = new List<bool>();
        void Append(int value, int length)
        {
            for (var i = length - 1; i >= 0; i--)
                bits.Add(((value >> i) & 1) != 0);
        }
        Append(0b0100, 4);
        Append(data.Length, version < 10 ? 8 : 16);
        foreach (var b in data)
            Append(b, 8);
        Append(0, Math.Min(4, capacity * 8 - bits.Count));
        Append(0, (8 - bits.Count % 8) % 8);
        for (var pad = 0xEC; bits.Count < capacity * 8; pad ^= 0xEC ^ 0x11)
            Append(pad, 8);

        var result = new byte[capacity];
        for (var i = 0; i < bits.Count; i++)
        {
            if (bits[i])
                result[i >> 3] |= (byte)(0x80 >> (i & 7));
        }
        return result;
    }

    // Splits the data in blocks, adds Reed-Solomon codewords to each, interleaves.
    private static byte[] AddErrorCorrection(int version, byte[] data)
    {
        var blocks = Blocks[version - 1];
        var ecc = EccPerBlock[version - 1];
        var raw = TotalCodewords[version - 1];
        var shortBlocks = blocks - raw % blocks;
        var shortLength = raw / blocks;
        var divisor = ReedSolomonDivisor(ecc);

        var list = new List<byte[]>();
        for (int i = 0, k = 0; i < blocks; i++)
        {
            var length = shortLength - ecc + (i < shortBlocks ? 0 : 1);
            var dat = data[k..(k + length)];
            k += length;
            var block = new byte[shortLength + 1];
            var withEcc = dat.Concat(ReedSolomonRemainder(dat, divisor)).ToArray();
            if (i < shortBlocks)
            {
                // Short block: a dummy byte keeps the columns aligned, skipped when interleaving.
                Array.Copy(withEcc, 0, block, 0, length);
                Array.Copy(withEcc, length, block, length + 1, ecc);
            }
            else
            {
                withEcc.CopyTo(block, 0);
            }
            list.Add(block);
        }

        var result = new List<byte>(raw);
        for (var i = 0; i <= shortLength; i++)
        {
            for (var j = 0; j < list.Count; j++)
            {
                if (i != shortLength - ecc || j >= shortBlocks)
                    result.Add(list[j][i]);
            }
        }
        return [.. result];
    }

    private static byte[] ReedSolomonDivisor(int degree)
    {
        var result = new byte[degree];
        result[degree - 1] = 1;
        var root = 1;
        for (var i = 0; i < degree; i++)
        {
            for (var j = 0; j < degree; j++)
            {
                result[j] = Multiply(result[j], root);
                if (j + 1 < degree)
                    result[j] ^= result[j + 1];
            }
            root = Multiply(root, 0x02);
        }
        return result;
    }

    private static byte[] ReedSolomonRemainder(byte[] data, byte[] divisor)
    {
        var result = new byte[divisor.Length];
        foreach (var b in data)
        {
            var factor = b ^ result[0];
            Array.Copy(result, 1, result, 0, result.Length - 1);
            result[^1] = 0;
            for (var i = 0; i < result.Length; i++)
                result[i] ^= Multiply(divisor[i], factor);
        }
        return result;
    }

    // Product in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
    private static byte Multiply(int x, int y)
    {
        var z = 0;
        for (var i = 7; i >= 0; i--)
        {
            z = (z << 1) ^ ((z >> 7) * 0x11D);
            z ^= ((y >> i) & 1) * x;
        }
        return (byte)z;
    }

    private void Set(int column, int row, bool dark)
    {
        _modules[row, column] = dark;
        _function[row, column] = true;
    }

    private void DrawFunctionPatterns()
    {
        for (var i = 0; i < Size; i++)
        {
            Set(6, i, i % 2 == 0);
            Set(i, 6, i % 2 == 0);
        }
        DrawFinder(3, 3);
        DrawFinder(Size - 4, 3);
        DrawFinder(3, Size - 4);

        var positions = AlignmentPositions[Version - 1];
        var last = positions.Length - 1;
        for (var i = 0; i < positions.Length; i++)
        {
            for (var j = 0; j < positions.Length; j++)
            {
                if ((i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0))
                    continue;
                for (var dy = -2; dy <= 2; dy++)
                {
                    for (var dx = -2; dx <= 2; dx++)
                        Set(positions[i] + dx, positions[j] + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
                }
            }
        }

        DrawFormatBits(0);   // reserves the format areas (redrawn with the chosen mask)
        DrawVersionBits();
    }

    private void DrawFinder(int x, int y)
    {
        for (var dy = -4; dy <= 4; dy++)
        {
            for (var dx = -4; dx <= 4; dx++)
            {
                var distance = Math.Max(Math.Abs(dx), Math.Abs(dy));
                int xx = x + dx, yy = y + dy;
                if (xx >= 0 && xx < Size && yy >= 0 && yy < Size)
                    Set(xx, yy, distance != 2 && distance != 4);
            }
        }
    }

    // Level M (format bits 00) and mask, BCH(15, 5), XOR 0x5412; two copies.
    private void DrawFormatBits(int mask)
    {
        var data = 0 << 3 | mask;
        var rem = data;
        for (var i = 0; i < 10; i++)
            rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        var bits = (data << 10 | rem) ^ 0x5412;
        bool Bit(int i) => ((bits >> i) & 1) != 0;

        for (var i = 0; i <= 5; i++)
            Set(8, i, Bit(i));
        Set(8, 7, Bit(6));
        Set(8, 8, Bit(7));
        Set(7, 8, Bit(8));
        for (var i = 9; i < 15; i++)
            Set(14 - i, 8, Bit(i));

        for (var i = 0; i < 8; i++)
            Set(Size - 1 - i, 8, Bit(i));
        for (var i = 8; i < 15; i++)
            Set(8, Size - 15 + i, Bit(i));
        Set(8, Size - 8, true);   // always dark
    }

    // Versions 7 and above: version number, BCH(18, 6), two copies.
    private void DrawVersionBits()
    {
        if (Version < 7)
            return;
        var rem = Version;
        for (var i = 0; i < 12; i++)
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        var bits = (long)Version << 12 | (long)rem;
        for (var i = 0; i < 18; i++)
        {
            var bit = ((bits >> i) & 1) != 0;
            int a = Size - 11 + i % 3, b = i / 3;
            Set(a, b, bit);
            Set(b, a, bit);
        }
    }

    // Zigzag from the bottom-right corner, two columns at a time, skipping the vertical timing pattern.
    private void DrawCodewords(byte[] data)
    {
        var i = 0;
        for (var right = Size - 1; right >= 1; right -= 2)
        {
            if (right == 6)
                right = 5;
            for (var vert = 0; vert < Size; vert++)
            {
                for (var j = 0; j < 2; j++)
                {
                    var x = right - j;
                    var upward = ((right + 1) & 2) == 0;
                    var y = upward ? Size - 1 - vert : vert;
                    if (!_function[y, x] && i < data.Length * 8)
                    {
                        _modules[y, x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0;
                        i++;
                    }
                }
            }
        }
    }

    private void ApplyMask(int mask)
    {
        for (var y = 0; y < Size; y++)
        {
            for (var x = 0; x < Size; x++)
            {
                if (_function[y, x])
                    continue;
                var invert = mask switch
                {
                    0 => (x + y) % 2 == 0,
                    1 => y % 2 == 0,
                    2 => x % 3 == 0,
                    3 => (x + y) % 3 == 0,
                    4 => (x / 3 + y / 2) % 2 == 0,
                    5 => x * y % 2 + x * y % 3 == 0,
                    6 => (x * y % 2 + x * y % 3) % 2 == 0,
                    _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
                };
                if (invert)
                    _modules[y, x] = !_modules[y, x];
            }
        }
    }

    // Penalty rules: runs of 5+ same-color modules, 2×2 blocks, finder-like patterns, dark / light balance.
    private int Penalty()
    {
        var penalty = 0;
        for (var pass = 0; pass < 2; pass++)
        {
            for (var a = 0; a < Size; a++)
            {
                var run = 1;
                var line = new bool[Size];
                for (var b = 0; b < Size; b++)
                    line[b] = pass == 0 ? _modules[a, b] : _modules[b, a];
                for (var b = 1; b < Size; b++)
                {
                    if (line[b] == line[b - 1])
                    {
                        run++;
                        if (run == 5)
                            penalty += 3;
                        else if (run > 5)
                            penalty++;
                    }
                    else
                    {
                        run = 1;
                    }
                }
                // 1:1:3:1:1 dark pattern with 4 light modules on one side.
                for (var b = 0; b + 10 < Size; b++)
                {
                    bool P(int k, bool dark) => line[b + k] == dark;
                    var core = P(0, true) && P(1, false) && P(2, true) && P(3, true) && P(4, true) && P(5, false) && P(6, true);
                    if (core && P(7, false) && P(8, false) && P(9, false) && P(10, false))
                        penalty += 40;
                    var coreAfter = P(4, true) && P(5, false) && P(6, true) && P(7, true) && P(8, true) && P(9, false) && P(10, true);
                    if (coreAfter && P(0, false) && P(1, false) && P(2, false) && P(3, false))
                        penalty += 40;
                }
            }
        }
        for (var y = 0; y + 1 < Size; y++)
        {
            for (var x = 0; x + 1 < Size; x++)
            {
                var c = _modules[y, x];
                if (c == _modules[y, x + 1] && c == _modules[y + 1, x] && c == _modules[y + 1, x + 1])
                    penalty += 3;
            }
        }
        var dark = 0;
        foreach (var m in _modules)
        {
            if (m)
                dark++;
        }
        var total = Size * Size;
        penalty += Math.Abs(dark * 20 - total * 10) / total * 10;
        return penalty;
    }
}
