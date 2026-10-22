using System;
using System.Globalization;

namespace SysInfo.Services;

/// <summary>
/// French number formatting from the design system: decimal comma, narrow no-break space for thousands.
/// </summary>
public static class Formatting
{
    private static readonly CultureInfo French = CultureInfo.GetCultureInfo("fr-FR");

    /// <summary>23.4 → "23,4" ; 8 → "8" ; 21482 → "21 482" ; at most one decimal.</summary>
    public static string Number(double value) => value.ToString("#,##0.#", French);

    /// <summary>
    /// Table cells: integers stay ungrouped, because a table column often holds identifiers (PID, port)
    /// where "92 040" would read wrong; decimals are formatted as <see cref="Number"/>.
    /// </summary>
    public static string TableNumber(double value) =>
        value == Math.Floor(value) && Math.Abs(value) < 1e15 ? value.ToString("0", French) : Number(value);

    /// <summary>Converts a PowerShell numeric value to double; anything else → null.</summary>
    public static double? ToDouble(object? value) => value switch
    {
        byte or sbyte or short or ushort or int or uint or long or ulong or float or double or decimal
            => Convert.ToDouble(value, CultureInfo.InvariantCulture),
        _ => null,
    };
}
