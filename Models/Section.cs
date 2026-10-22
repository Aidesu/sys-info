using System.Collections.Generic;

namespace SysInfo.Models;

/// <summary>
/// A displayable block returned by a module's Get-ModuleData (see PROJECT_CONTEXT.md §4.3).
/// </summary>
public abstract record Section(string Title);

/// <summary>
/// Fixed information shown as a key → value list.
/// </summary>
public sealed record KeyValueSection(string Title, IReadOnlyList<KeyValueItem> Items) : Section(Title);

public sealed record KeyValueItem(string Key, string Value);

/// <summary>
/// A numeric value that changes over time. Warning and Critical are optional thresholds, in the unit of Value.
/// </summary>
public sealed record MetricSection(
    string Title, double? Value, string Unit, double? Max, double? Warning, double? Critical) : Section(Title)
{
    public SectionStatus Status =>
        Value is not { } v ? SectionStatus.None
        : Critical is { } c && v >= c ? SectionStatus.Critical
        : Warning is { } w && v >= w ? SectionStatus.Warning
        : SectionStatus.None;
}

/// <summary>
/// A list shown as a sortable table. Each row holds one value per column (number, text or null).
/// </summary>
public sealed record TableSection(
    string Title, IReadOnlyList<string> Columns, IReadOnlyList<IReadOnlyList<object?>> Rows) : Section(Title);

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
