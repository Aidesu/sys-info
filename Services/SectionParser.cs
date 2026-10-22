using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using SysInfo.Models;

namespace SysInfo.Services;

/// <summary>
/// Converts the object returned by Get-ModuleData into <see cref="Section"/> records.
/// </summary>
public static class SectionParser
{
    public static IReadOnlyList<Section> Parse(PSObject data)
    {
        if (data.Properties["Sections"]?.Value is not IEnumerable sections)
            return [];

        return sections
            .Cast<object?>()
            .Where(s => s is not null)
            .Select(s => ParseSection(PSObject.AsPSObject(s!)))
            .ToList();
    }

    /// <summary>Optional Subtitle of the result, shown in the page header ("wlp4s0 · 192.168.1.42").</summary>
    public static string? ParseSubtitle(PSObject data) =>
        data.Properties["Subtitle"]?.Value?.ToString() is { Length: > 0 } subtitle ? subtitle : null;

    private static Section ParseSection(PSObject section)
    {
        var title = section.Properties["Title"]?.Value?.ToString() ?? string.Empty;
        var type = section.Properties["Type"]?.Value?.ToString() ?? string.Empty;
        var icon = section.Properties["Icon"]?.Value?.ToString();

        Section parsed = type switch
        {
            "KeyValue" => new KeyValueSection(title, ParseItems(section.Properties["Items"]?.Value)),
            "Metric" => new MetricSection(
                title,
                Number(section, "Value"),
                section.Properties["Unit"]?.Value?.ToString() ?? string.Empty,
                Number(section, "Max"),
                Number(section, "Warning"),
                Number(section, "Critical"),
                section.Properties["Detail"]?.Value?.ToString(),
                section.Properties["Label"]?.Value?.ToString(),
                ParseSeries(section.Properties["Secondary"]?.Value)),
            "Table" => ParseTable(title, section),
            "Usage" => new UsageSection(title, List(section.Properties["Items"]?.Value).Select(ParseUsageItem).ToList()),
            _ => new UnsupportedSection(title, type),
        };
        return string.IsNullOrWhiteSpace(icon) ? parsed : parsed with { Icon = icon };
    }

    // Secondary = @{ Label = 'Émission'; Value = 1.2 } (hashtable or PSCustomObject).
    private static MetricSeries? ParseSeries(object? value)
    {
        if (value is null)
            return null;
        var ps = PSObject.AsPSObject(value);
        if (ps.BaseObject is IDictionary dictionary)
        {
            return new MetricSeries(
                dictionary["Label"]?.ToString() ?? string.Empty,
                Formatting.ToDouble(Unwrap(dictionary["Value"])));
        }
        return new MetricSeries(
            ps.Properties["Label"]?.Value?.ToString() ?? string.Empty,
            Formatting.ToDouble(Unwrap(ps.Properties["Value"]?.Value)));
    }

    // Usage item: hashtable or PSCustomObject with Label, Detail, Value, Max, Unit, Warning, Critical, Text.
    private static UsageItem ParseUsageItem(object? item)
    {
        var ps = PSObject.AsPSObject(item ?? new object());
        object? Get(string name) => ps.BaseObject is IDictionary d ? Unwrap(d[name]) : Unwrap(ps.Properties[name]?.Value);
        return new UsageItem(
            Get("Label")?.ToString() ?? string.Empty,
            Get("Detail")?.ToString(),
            Formatting.ToDouble(Get("Value")),
            Formatting.ToDouble(Get("Max")),
            Get("Unit")?.ToString() ?? string.Empty,
            Formatting.ToDouble(Get("Warning")),
            Formatting.ToDouble(Get("Critical")),
            Get("Text")?.ToString());
    }

    private static TableSection ParseTable(string title, PSObject section)
    {
        var columns = List(section.Properties["Columns"]?.Value).Select(c => c?.ToString() ?? string.Empty).ToList();
        var rows = List(section.Properties["Rows"]?.Value);

        // PowerShell unrolls a one-row table: @( @(0, 35) ) arrives as @(0, 35). Only scalars → that single row.
        if (columns.Count > 1 && rows.Count > 0 && rows.All(r => r is string || r is not IEnumerable))
            return new TableSection(title, columns, [rows]);

        return new TableSection(title, columns, rows.Select(r => (IReadOnlyList<object?>)List(r)).ToList());
    }

    private static double? Number(PSObject section, string name) =>
        Formatting.ToDouble(Unwrap(section.Properties[name]?.Value));

    // A PSCustomObject only exists through its PSObject wrapper (its properties live there): keep it wrapped.
    private static object? Unwrap(object? value) => value is PSObject { BaseObject: not PSCustomObject } ps ? ps.BaseObject : value;

    // A single value is also accepted where an array is expected (PowerShell unrolls one-element arrays).
    private static List<object?> List(object? value) => Unwrap(value) switch
    {
        null => [],
        string s => [s],
        IEnumerable items => items.Cast<object?>().Select(Unwrap).ToList(),
        var single => [single],
    };

    // Items is an [ordered] hashtable, or a PSCustomObject when the module builds one.
    private static IReadOnlyList<KeyValueItem> ParseItems(object? items)
    {
        if (Unwrap(items) is IDictionary dictionary)
        {
            return dictionary
                .Cast<DictionaryEntry>()
                .Select(e => new KeyValueItem(e.Key.ToString() ?? string.Empty, Format(e.Value)))
                .ToList();
        }

        if (items is PSObject obj)
        {
            return obj.Properties
                .Select(p => new KeyValueItem(p.Name, Format(p.Value)))
                .ToList();
        }

        return [];
    }

    public static string Format(object? value) => Unwrap(value) switch
    {
        null => "—",
        string s => s,
        var v when Formatting.ToDouble(v) is { } d => Formatting.Number(d),
        IEnumerable list => string.Join(", ", list.Cast<object?>().Select(Format)),
        var v => v.ToString() ?? string.Empty,
    };
}
