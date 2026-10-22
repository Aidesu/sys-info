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

    private static Section ParseSection(PSObject section)
    {
        var title = section.Properties["Title"]?.Value?.ToString() ?? string.Empty;
        var type = section.Properties["Type"]?.Value?.ToString() ?? string.Empty;

        return type switch
        {
            "KeyValue" => new KeyValueSection(title, ParseItems(section.Properties["Items"]?.Value)),
            "Metric" => new MetricSection(
                title,
                Number(section, "Value"),
                section.Properties["Unit"]?.Value?.ToString() ?? string.Empty,
                Number(section, "Max"),
                Number(section, "Warning"),
                Number(section, "Critical")),
            "Table" => ParseTable(title, section),
            _ => new UnsupportedSection(title, type),
        };
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

    private static object? Unwrap(object? value) => value is PSObject ps ? ps.BaseObject : value;

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
