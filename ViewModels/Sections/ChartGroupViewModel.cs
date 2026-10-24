using System.Collections.Generic;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Consecutive two-series Metric sections (ex. download / upload, Internet / gateway latency):
/// wide chart cards with a legend of current, average and maximum values, two per row.
/// </summary>
public sealed class ChartGroupViewModel(IReadOnlyList<MetricSectionViewModel> metrics) : ViewModelBase, Controls.IWideBlock
{
    public IReadOnlyList<MetricSectionViewModel> Metrics { get; } = metrics;

    /// <summary>At most three wide charts per row; fewer on a narrower page (<see cref="Controls.AdaptiveGrid"/>).</summary>
    public int MaxColumns => System.Math.Clamp(Metrics.Count, 1, 3);

    /// <summary>Spans every column of a wide page; a lone chart stays in one column.</summary>
    public bool IsWide => Metrics.Count >= 2;
}
