using System.Collections.Generic;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// What a page (or a tool result) shows, in order: each section, except that consecutive single-series Metric sections
/// form a <see cref="MetricGroupViewModel"/> (compact cards in a row, charts under them) and consecutive two-series
/// Metric or Metric with a History form a <see cref="ChartGroupViewModel"/> (wide charts, two per row).
/// A tool result runs once (<paramref name="live"/> false): its Metric sections stay single cards, only those with a
/// History get a chart.
/// </summary>
public static class SectionBlocks
{
    public static IReadOnlyList<ViewModelBase> Build(IReadOnlyList<SectionViewModel> sections, bool live = true)
    {
        var blocks = new List<ViewModelBase>();
        var metrics = new List<MetricSectionViewModel>();
        var charts = new List<MetricSectionViewModel>();

        void Flush()
        {
            if (metrics.Count > 0)
                blocks.Add(new MetricGroupViewModel([.. metrics]));
            if (charts.Count > 0)
                blocks.Add(new ChartGroupViewModel([.. charts]));
            metrics.Clear();
            charts.Clear();
        }

        foreach (var section in sections)
        {
            if (section is MetricSectionViewModel metric && (live || metric.HasHistory))
            {
                var wide = metric.IsDual || metric.HasHistory;
                if ((wide ? metrics : charts).Count > 0)
                    Flush();
                (wide ? charts : metrics).Add(metric);
                continue;
            }
            Flush();
            blocks.Add(section);
        }
        Flush();
        return blocks;
    }
}
