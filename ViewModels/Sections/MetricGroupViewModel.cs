using System.Collections.Generic;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Consecutive Metric sections shown together: one row of equal-width metric cards,
/// and under each card the chart of its history, aligned column by column.
/// </summary>
public sealed class MetricGroupViewModel(IReadOnlyList<MetricSectionViewModel> metrics) : ViewModelBase
{
    public IReadOnlyList<MetricSectionViewModel> Metrics { get; } = metrics;

    /// <summary>Columns of the grid: up to 3 metrics side by side, then a new line.</summary>
    public int Columns => Metrics.Count switch
    {
        <= 3 => Metrics.Count,
        4 => 2,
        _ => 3,
    };
}
