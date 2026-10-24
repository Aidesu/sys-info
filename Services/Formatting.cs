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

    /// <summary>Axis ticks: up to two decimals, so that 0.25 stays "0,25".</summary>
    public static string Tick(double value) => value.ToString("#,##0.##", French);

    /// <summary>Span covered by a chart: "60 dernières minutes", "24 dernières heures", "7 derniers jours".</summary>
    public static string Window(TimeSpan span) =>
        span.TotalHours < 2 ? $"{Math.Round(span.TotalMinutes)} dernières minutes"
        : span.TotalDays < 2 ? $"{Math.Round(span.TotalHours)} dernières heures"
        : $"{Math.Round(span.TotalDays)} derniers jours";

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
