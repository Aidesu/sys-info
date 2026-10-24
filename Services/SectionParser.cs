using System;
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

    /// <summary>
    /// Optional Findings beside Sections: @{ Severity = 'warning'; Code = 'STO-VOLUME-FULL'; Message; Recommendation }.
    /// A finding without Code or Message, or with an unknown Severity, is ignored and reported on stderr.
    /// </summary>
    public static IReadOnlyList<Finding> ParseFindings(PSObject data)
    {
        var findings = new List<Finding>();
        foreach (var item in List(data.Properties["Findings"]?.Value))
        {
            if (item is null)
                continue;
            var ps = PSObject.AsPSObject(item);
            string? Get(string name) =>
                (ps.BaseObject is IDictionary d ? Unwrap(d[name]) : Unwrap(ps.Properties[name]?.Value))?.ToString();

            var code = Get("Code");
            var message = Get("Message");
            if (string.IsNullOrWhiteSpace(code) || string.IsNullOrWhiteSpace(message)
                || !Enum.TryParse<FindingSeverity>(Get("Severity"), ignoreCase: true, out var severity)
                || !Enum.IsDefined(severity))
            {
                Console.Error.WriteLine($"[modules] finding ignoré (Severity, Code et Message requis) : {code ?? message}");
                continue;
            }

            findings.Add(new Finding(severity, code, message, Get("Recommendation")));
        }

        // Worst first: the AI and the page read the most serious ones first.
        return findings.OrderByDescending(f => f.Severity).ToList();
    }

    /// <summary>
    /// Optional Changes of an action: @( @{ Target = 'cups.service'; Property = 'État'; Before = 'actif'; After = 'arrêté' } ).
    /// An entry without Target or Property is ignored.
    /// </summary>
    public static IReadOnlyList<Change> ParseChanges(PSObject data)
    {
        var changes = new List<Change>();
        foreach (var item in List(data.Properties["Changes"]?.Value))
        {
            if (item is null)
                continue;
            var ps = PSObject.AsPSObject(item);
            string? Get(string name)
            {
                var value = ps.BaseObject is IDictionary d ? Unwrap(d[name]) : Unwrap(ps.Properties[name]?.Value);
                return value is null ? null : Format(value);
            }

            var target = Get("Target");
            var property = Get("Property");
            if (!string.IsNullOrWhiteSpace(target) && !string.IsNullOrWhiteSpace(property))
                changes.Add(new Change(target, property, Get("Before"), Get("After")));
        }
        return changes;
    }

    /// <summary>
    /// Optional Blocked of a dry run: why the action cannot run (rights, target not found, protected). The action is
    /// then never offered for confirmation.
    /// </summary>
    public static string? ParseBlocked(PSObject data) =>
        data.Properties["Blocked"]?.Value?.ToString() is { Length: > 0 } reason ? reason : null;

    /// <summary>
    /// Optional Undo of an action: @{ Function = 'control'; Parameters = @{ name = 'cups'; action = 'start' } }, a function
    /// of the same module that reverses it. Returned as { tool, function, parameters } for the audit log and the AI.
    /// </summary>
    public static System.Text.Json.Nodes.JsonObject? ParseUndo(PSObject data, ModuleManifest manifest)
    {
        if (data.Properties["Undo"]?.Value is not { } value)
            return null;
        var ps = PSObject.AsPSObject(value);
        object? Get(string name) => ps.BaseObject is IDictionary d ? d[name] : ps.Properties[name]?.Value;
        if (Unwrap(Get("Function"))?.ToString() is not { Length: > 0 } function)
            return null;
        return new System.Text.Json.Nodes.JsonObject
        {
            ["tool"] = $"{manifest.Id.Replace('-', '_')}_{function}",
            ["function"] = function,
            ["parameters"] = Mcp.PsJson.ToJson(Get("Parameters")) ?? new System.Text.Json.Nodes.JsonObject(),
        };
    }

    /// <summary>The changes as a table section, shown first in the result of an action.</summary>
    public static TableSection? ChangesSection(IReadOnlyList<Change> changes, bool dryRun) =>
        changes.Count == 0 ? null
        : new TableSection(dryRun ? "Modifications prévues" : "Modifications",
            ["Objet", "Propriété", "Avant", "Après"],
            [.. changes.Select(c => (IReadOnlyList<object?>)[c.Target, c.Property, c.Before ?? "—", c.After ?? "—"])])
        { Icon = "arrow_swap" };

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
                ParseSeries(section.Properties["Secondary"]?.Value),
                ParseHistory(section.Properties["History"]?.Value)),
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

    // History = @{ Window = 86400; Points = @( @(1761300000, 12.5, 3.1), … ) }: time (Unix seconds, or a date / ISO
    // text), value, optional second value; $null = gap. Points outside the window are kept (the chart clips them).
    private static MetricHistory? ParseHistory(object? value)
    {
        if (value is null)
            return null;
        var ps = PSObject.AsPSObject(value);
        object? Get(string name) => ps.BaseObject is IDictionary d ? Unwrap(d[name]) : Unwrap(ps.Properties[name]?.Value);
        if (Formatting.ToDouble(Get("Window")) is not { } window || window <= 0)
            return null;
        var points = new List<HistoryPoint>();
        foreach (var item in List(Get("Points")))
        {
            var fields = List(item);
            if (fields.Count < 2 || ParseTime(fields[0]) is not { } at)
                continue;
            points.Add(new HistoryPoint(at,
                Formatting.ToDouble(fields[1]) ?? double.NaN,
                fields.Count > 2 ? Formatting.ToDouble(fields[2]) ?? double.NaN : double.NaN));
        }
        points.Sort((a, b) => a.At.CompareTo(b.At));
        return new MetricHistory(TimeSpan.FromSeconds(window), points);
    }

    private static DateTime? ParseTime(object? value) => value switch
    {
        DateTime d => d.ToLocalTime(),
        DateTimeOffset o => o.LocalDateTime,
        string s when DateTimeOffset.TryParse(s, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var o) => o.LocalDateTime,
        var v when Formatting.ToDouble(v) is { } seconds => DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)).LocalDateTime,
        _ => null,
    };

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
