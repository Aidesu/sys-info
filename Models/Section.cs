using System.Collections.Generic;

namespace SysInfo.Models;

/// <summary>
/// A displayable block returned by a module's Get-ModuleData (see PROJECT_CONTEXT.md §4.3).
/// Icon is optional: a name from the icon set (Styles/Icons.axaml), shown before the card title.
/// </summary>
public abstract record Section(string Title)
{
    public string? Icon { get; init; }
}

/// <summary>
/// Fixed information shown as a key → value list.
/// </summary>
public sealed record KeyValueSection(string Title, IReadOnlyList<KeyValueItem> Items) : Section(Title);

public sealed record KeyValueItem(string Key, string Value);

/// <summary>
/// A numeric value that changes over time. Warning and Critical are optional thresholds, in the unit of Value;
/// Detail is an optional short line shown under the value ("4,70 GHz · 16 threads").
/// With a Secondary value, the metric becomes a two-series chart (ex. download / upload):
/// Label names the main series, Secondary.Label the second one; thresholds apply to the main series.
/// </summary>
public sealed record MetricSection(
    string Title, double? Value, string Unit, double? Max, double? Warning, double? Critical, string? Detail = null,
    string? Label = null, MetricSeries? Secondary = null) : Section(Title)
{
    public bool IsDual => Secondary is not null;

    public SectionStatus Status =>
        Value is not { } v ? SectionStatus.None
        : Critical is { } c && v >= c ? SectionStatus.Critical
        : Warning is { } w && v >= w ? SectionStatus.Warning
        : SectionStatus.None;
}

/// <summary>Second series of a two-series Metric.</summary>
public sealed record MetricSeries(string Label, double? Value);

/// <summary>
/// A list shown as a sortable table. Each row holds one value per column (number, text or null).
/// </summary>
public sealed record TableSection(
    string Title, IReadOnlyList<string> Columns, IReadOnlyList<IReadOnlyList<object?>> Rows) : Section(Title);

/// <summary>
/// Fill levels (design system "Remplissage"): one gauge row per item, ex. one per volume.
/// </summary>
public sealed record UsageSection(string Title, IReadOnlyList<UsageItem> Items) : Section(Title);

/// <summary>
/// One gauge row: Value out of Max in Unit, optional Warning / Critical thresholds (same unit),
/// a Detail line under the label and a free Text under the value ("100 GiB libres sur 1,8 TiB").
/// </summary>
public sealed record UsageItem(
    string Label, string? Detail, double? Value, double? Max, string Unit, double? Warning, double? Critical, string? Text)
{
    public SectionStatus Status =>
        Value is not { } v ? SectionStatus.None
        : Critical is { } c && v >= c ? SectionStatus.Critical
        : Warning is { } w && v >= w ? SectionStatus.Warning
        : SectionStatus.None;
}

/// <summary>
/// A section whose type has no renderer (unknown type).
/// </summary>
public sealed record UnsupportedSection(string Title, string Type) : Section(Title);

/// <summary>
/// State carried by a value: no OK state is ever displayed, only Warning and Critical.
/// </summary>
public enum SectionStatus
{
    None,
    Warning,
    Critical,
}
