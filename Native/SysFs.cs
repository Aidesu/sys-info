using System;
using System.Globalization;
using System.IO;

namespace SysInfo.Native;

/// <summary>
/// Batch read of numeric sysfs files (Linux) for the Sensors module (helper of the host, §4.6): ~30 hwmon probes and
/// the thermal_throttle counters of every CPU at each refresh cost ~30 ms in PowerShell, well under 1 ms here.
/// </summary>
public static class SysFs
{
    /// <summary>One value per path, in order; NaN when the file is missing, unreadable or not a number.</summary>
    public static double[] ReadNumbers(string[] paths)
    {
        var values = new double[paths.Length];
        for (var i = 0; i < paths.Length; i++)
        {
            values[i] = double.NaN;
            try
            {
                if (double.TryParse(File.ReadAllText(paths[i]).AsSpan().Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v))
                    values[i] = v;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
        return values;
    }
}
