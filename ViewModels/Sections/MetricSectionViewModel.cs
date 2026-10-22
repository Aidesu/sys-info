using System;
using System.Collections.Generic;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Value + unit, a gauge when Max is known, an optional detail line, and a timed history
/// (last 60 samples) with its statistics for the chart. A two-series metric (Secondary) keeps a
/// second history aligned on the same times; a missing value is kept as NaN (a gap in the line).
/// </summary>
public partial class MetricSectionViewModel : SectionViewModel
{
    public const int HistoryLength = 60;

    private readonly Queue<(DateTime At, double Value, double Secondary)> _history = new();

    public MetricSectionViewModel(MetricSection section) : base(section)
    {
        Update(section);
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ValueText), nameof(HasGauge), nameof(Percent), nameof(Status),
        nameof(IsWarning), nameof(IsCritical), nameof(StatusText), nameof(Unit), nameof(ChartMaximum),
        nameof(Detail), nameof(HasDetail), nameof(IsDual), nameof(PrimaryLabel), nameof(SecondaryLabel),
        nameof(SecondaryValueText), nameof(ValueWithUnit), nameof(SecondaryValueWithUnit))]
    public partial MetricSection Data { get; private set; } = null!;

    /// <summary>Values, oldest first; a new array on each refresh so that bindings see the change.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(AverageText), nameof(MinimumText), nameof(MaximumText), nameof(WindowText), nameof(HasStatistics))]
    public partial IReadOnlyList<double> History { get; private set; } = [];

    /// <summary>Second series (two-series metrics only), aligned on <see cref="HistoryTimes"/>.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SecondaryAverageText), nameof(SecondaryMaximumText))]
    public partial IReadOnlyList<double>? SecondaryHistory { get; private set; }

    /// <summary>Time of each value in <see cref="History"/>.</summary>
    [ObservableProperty]
    public partial IReadOnlyList<DateTime> HistoryTimes { get; private set; } = [];

    public string ValueText => Data.Value is { } v ? Formatting.Number(v) : "—";

    public string Unit => Data.Unit;

    public string? Detail => Data.Detail;

    public bool HasDetail => !string.IsNullOrWhiteSpace(Data.Detail);

    public bool HasGauge => Data is { Max: > 0, Value: not null };

    public double Percent => HasGauge ? Math.Clamp(Data.Value!.Value / Data.Max!.Value * 100, 0, 100) : 0;

    /// <summary>Top of the chart: Max when the module gives one, else NaN (the chart picks a round value).</summary>
    public double ChartMaximum => Data.Max is > 0 ? Data.Max.Value : double.NaN;

    // Two-series metrics

    public bool IsDual => Data.IsDual;

    public string PrimaryLabel => Data.Label ?? Title;

    public string SecondaryLabel => Data.Secondary?.Label ?? string.Empty;

    public string SecondaryValueText => Data.Secondary?.Value is { } v ? Formatting.Number(v) : "—";

    /// <summary>Current values with their unit, for the legend of a two-series chart.</summary>
    public string ValueWithUnit => Data.Value is { } v ? $"{Formatting.Number(v)}\u00a0{Unit}" : "—";

    public string SecondaryValueWithUnit => Data.Secondary?.Value is { } v ? $"{Formatting.Number(v)}\u00a0{Unit}" : "—";

    public override SectionStatus Status => Data.Status;

    public bool IsWarning => Status == SectionStatus.Warning;

    public bool IsCritical => Status == SectionStatus.Critical;

    public string StatusText => Status switch
    {
        SectionStatus.Warning => "Attention",
        SectionStatus.Critical => "Critique",
        _ => string.Empty,
    };

    // Statistics over the samples on screen (gaps ignored)

    public bool HasStatistics => History.Any(double.IsFinite);

    public string AverageText => Stat(History, s => s.Average());

    public string MinimumText => Stat(History, s => s.Min());

    public string MaximumText => Stat(History, s => s.Max());

    public string SecondaryAverageText => Stat(SecondaryHistory, s => s.Average());

    public string SecondaryMaximumText => Stat(SecondaryHistory, s => s.Max());

    /// <summary>Card subtitle: how much time the chart covers.</summary>
    public string WindowText
    {
        get
        {
            if (HistoryTimes.Count < 2)
                return "En attente de mesures";
            var span = HistoryTimes[^1] - HistoryTimes[0];
            return span.TotalSeconds < 90
                ? $"{Math.Round(span.TotalSeconds)} dernières secondes"
                : $"{Math.Round(span.TotalMinutes)} dernières minutes";
        }
    }

    private string Stat(IReadOnlyList<double>? values, Func<IEnumerable<double>, double> aggregate)
    {
        var finite = values?.Where(double.IsFinite).ToList();
        return finite is { Count: > 0 } ? $"{Formatting.Number(aggregate(finite))} {Unit}" : "—";
    }

    public override void Update(Section section)
    {
        var metric = (MetricSection)section;

        // Single series: only real values. Two series: one sample per refresh, NaN where a value is missing.
        if (metric.IsDual || metric.Value is not null)
        {
            _history.Enqueue((DateTime.Now, metric.Value ?? double.NaN, metric.Secondary?.Value ?? double.NaN));
            while (_history.Count > HistoryLength)
                _history.Dequeue();
            HistoryTimes = _history.Select(h => h.At).ToArray();
            SecondaryHistory = metric.IsDual ? _history.Select(h => h.Secondary).ToArray() : null;
            History = _history.Select(h => h.Value).ToArray();
        }
        Data = metric;
    }
}
