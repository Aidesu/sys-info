using System;
using System.Collections.Generic;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Big value + unit, a gauge when Max is known, and a short history (60 points).
/// </summary>
public partial class MetricSectionViewModel : SectionViewModel
{
    public const int HistoryLength = 60;

    private readonly Queue<double> _history = new();

    public MetricSectionViewModel(MetricSection section) : base(section)
    {
        Update(section);
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ValueText), nameof(HasGauge), nameof(Percent), nameof(Status),
        nameof(IsWarning), nameof(IsCritical), nameof(StatusText), nameof(Unit), nameof(HistoryMax))]
    public partial MetricSection Data { get; private set; } = null!;

    /// <summary>Oldest first; a new array on each refresh so that bindings see the change.</summary>
    [ObservableProperty]
    public partial IReadOnlyList<double> History { get; private set; } = [];

    public string ValueText => Data.Value is { } v ? Formatting.Number(v) : "—";

    public string Unit => Data.Unit;

    public bool HasGauge => Data is { Max: > 0, Value: not null };

    public double Percent => HasGauge ? Math.Clamp(Data.Value!.Value / Data.Max!.Value * 100, 0, 100) : 0;

    /// <summary>Top of the history chart: Max when known, else just above the highest point.</summary>
    public double HistoryMax => Data.Max is > 0 ? Data.Max.Value : Math.Max(1, History.DefaultIfEmpty(0).Max() * 1.15);

    public override SectionStatus Status => Data.Status;

    public bool IsWarning => Status == SectionStatus.Warning;

    public bool IsCritical => Status == SectionStatus.Critical;

    public string StatusText => Status switch
    {
        SectionStatus.Warning => "Attention",
        SectionStatus.Critical => "Critique",
        _ => string.Empty,
    };

    public override void Update(Section section)
    {
        var metric = (MetricSection)section;
        if (metric.Value is { } value)
        {
            _history.Enqueue(value);
            while (_history.Count > HistoryLength)
                _history.Dequeue();
            History = _history.ToArray();
        }
        Data = metric;
    }
}
