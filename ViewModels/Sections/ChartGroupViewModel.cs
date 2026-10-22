using System.Collections.Generic;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Consecutive two-series Metric sections (ex. download / upload, Internet / gateway latency):
/// wide chart cards with a legend of current, average and maximum values, two per row.
/// </summary>
public sealed class ChartGroupViewModel(IReadOnlyList<MetricSectionViewModel> metrics) : ViewModelBase
{
    public IReadOnlyList<MetricSectionViewModel> Metrics { get; } = metrics;

    public int Columns => Metrics.Count == 1 ? 1 : 2;
}
