using System;
using System.Collections.Generic;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
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

    /// <summary>Rows shown before « Voir plus ».</summary>
    public const int Limit = 6;

    private const int Margin = 2;

    /// <summary>Rows always shown: the first ones, plus any row past a threshold (never hidden).</summary>
    [ObservableProperty]
    public partial IReadOnlyList<UsageRow> Rows { get; private set; } = [];

    /// <summary>Rows behind « Voir plus ».</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanExpand), nameof(MoreText))]
    public partial IReadOnlyList<UsageRow> MoreRows { get; private set; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(MoreText))]
    public partial bool IsExpanded { get; set; }

    public bool CanExpand => MoreRows.Count > 0;

    public string MoreText => IsExpanded ? "Voir moins" : $"Voir les {MoreRows.Count} autres";

    [RelayCommand]
    private void ToggleExpanded() => IsExpanded = !IsExpanded;

    public override SectionStatus Status => Rows.Concat(MoreRows).Select(r => r.Status).DefaultIfEmpty(SectionStatus.None).Max();

    public override void Update(Section section)
    {
        var items = ((UsageSection)section).Items;
        // Same rows as before (same labels, in order): values updated in place, no new controls.
        var current = Rows.Concat(MoreRows).ToList();
        if (current.Count == items.Count && current.Zip(items).All(p => p.First.Label == p.Second.Label))
        {
            var moved = false;
            for (var i = 0; i < items.Count; i++)
                moved |= current[i].Update(items[i]);
            if (!moved)
                return;
        }

        var all = items.Select(i => new UsageRow(i)).ToList();
        if (all.Count <= Limit + Margin)
        {
            Rows = all;
            MoreRows = [];
            return;
        }
        // A row in warning or critical state stays visible even beyond the limit.
        var shown = all.Where((r, i) => i < Limit || r.Status != SectionStatus.None).ToList();
        Rows = shown;
        MoreRows = all.Except(shown).ToList();
    }
}

/// <summary>One gauge row; refreshed in place (<see cref="Update"/>) while its label stays the same.</summary>
public sealed partial class UsageRow(UsageItem item) : ObservableObject
{
    /// <summary>
    /// New values for the same row. Returns true when the row changes state (Normal / Warning / Critical) while
    /// beyond the limit: the visible / « Voir plus » split must then be redone.
    /// </summary>
    public bool Update(UsageItem next)
    {
        if (next == item)
            return false;
        var stateChanged = next.Status != item.Status;
        item = next;
        OnPropertyChanged(string.Empty); // every property derives from the item
        return stateChanged;
    }

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
