using System;
using System.Collections.Generic;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Consecutive Metric sections shown together: one row of equal-width metric cards,
/// and under each card the chart of its history, aligned column by column.
/// </summary>
public sealed class MetricGroupViewModel(IReadOnlyList<MetricSectionViewModel> metrics) : ViewModelBase, Controls.IWideBlock
{
    public IReadOnlyList<MetricSectionViewModel> Metrics { get; } = metrics;

    /// <summary>
    /// Most cards per row: all of them when the page is wide enough (<see cref="Controls.AdaptiveGrid"/> reduces it on a
    /// narrow page and balances the rows).
    /// </summary>
    public int MaxColumns => Math.Max(1, Metrics.Count);

    /// <summary>Spans every column of a wide page (the cards then line up across it); a lone metric stays in one column.</summary>
    public bool IsWide => Metrics.Count >= 2;
}
