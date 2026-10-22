using System;
using System.Collections.Generic;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Fill levels: one row per item (label, detail, gauge, used / max, percentage or state badge).
/// The section's state is its worst row, so a nearly full volume lights the tab.
/// </summary>
public partial class UsageSectionViewModel : SectionViewModel
{
    public UsageSectionViewModel(UsageSection section) : base(section)
    {
        Update(section);
    }

    [ObservableProperty]
    public partial IReadOnlyList<UsageRow> Rows { get; private set; } = [];

    public override SectionStatus Status => Rows.Select(r => r.Status).DefaultIfEmpty(SectionStatus.None).Max();

    public override void Update(Section section) =>
        Rows = ((UsageSection)section).Items.Select(i => new UsageRow(i)).ToList();
}

public sealed class UsageRow(UsageItem item)
{
    public string Label => item.Label;

    public string? Detail => item.Detail;

    public bool HasDetail => !string.IsNullOrWhiteSpace(item.Detail);

    public string? Text => item.Text;

    public bool HasText => !string.IsNullOrWhiteSpace(item.Text);

    public double Percent => item is { Value: { } v, Max: > 0 } ? Math.Clamp(v / item.Max!.Value * 100, 0, 100) : 0;

    /// <summary>"1 757,2 / 1 860,4 GiB".</summary>
    public string ValueText => item.Value is { } v
        ? item.Max is { } max ? $"{Formatting.Number(v)} / {Formatting.Number(max)} {item.Unit}" : $"{Formatting.Number(v)} {item.Unit}"
        : "—";

    public string PercentText => item.Max is > 0 ? $"{Formatting.Number(Math.Round(Percent))} %" : string.Empty;

    public SectionStatus Status => item.Status;

    public bool IsWarning => Status == SectionStatus.Warning;

    public bool IsCritical => Status == SectionStatus.Critical;

    public bool IsNormal => Status == SectionStatus.None;
}
