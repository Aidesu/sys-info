using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;

namespace SysInfo.ViewModels;

/// <summary>
/// The findings of a page, kept from one refresh to the next so that they can be animated: a finding that appears
/// unfolds, one that disappears folds before it leaves, one whose message changes is updated in place. Beyond
/// <see cref="Limit"/> (with some margin), only the most serious are shown, the others behind « Voir plus ».
/// </summary>
public partial class FindingListViewModel : ViewModelBase
{
    /// <summary>Findings shown before « Voir plus ».</summary>
    public const int Limit = 3;

    // Shown in full up to Limit + Margin: no « Voir plus » for a single hidden finding.
    private const int Margin = 1;

    private static readonly TimeSpan Fold = TimeSpan.FromMilliseconds(260);

    public ObservableCollection<FindingItemViewModel> Items { get; } = [];

    /// <summary>True while the page is on screen: changes are animated only then.</summary>
    public bool Animate { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(MoreText))]
    public partial bool IsExpanded { get; set; }

    partial void OnIsExpandedChanged(bool value) => ApplyLimit();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasFindings), nameof(CanExpand), nameof(MoreText), nameof(Summary))]
    public partial int Count { get; private set; }

    public bool HasFindings => Count > 0;

    public bool CanExpand => Count > Limit + Margin;

    public string MoreText => IsExpanded ? "Voir moins" : $"Voir les {Count - Limit} autres constats";

    /// <summary>« 1 critique · 2 attention · 3 info », next to the card title.</summary>
    [ObservableProperty]
    public partial string Summary { get; private set; } = string.Empty;

    [RelayCommand]
    private void ToggleExpanded() => IsExpanded = !IsExpanded;

    /// <summary>Applies the findings of a refresh (worst first).</summary>
    public void Update(IReadOnlyList<Finding> findings)
    {
        // Key: code + rank among the same code (one finding per volume…), so that a message with a new value
        // (« rempli à 94 % » → « 95 % ») is an update, not a remove and an add.
        var keyed = findings.Select((f, _) => f)
            .GroupBy(f => f.Code)
            .SelectMany(g => g.Select((f, i) => (Key: $"{g.Key}#{i}", Finding: f)))
            .ToList();
        var order = findings.ToList();
        keyed.Sort((a, b) => order.IndexOf(a.Finding).CompareTo(order.IndexOf(b.Finding)));

        var wanted = keyed.Select(k => k.Key).ToHashSet();
        foreach (var gone in Items.Where(i => !i.IsClosing && !wanted.Contains(i.Key)).ToList())
            Remove(gone);

        for (var index = 0; index < keyed.Count; index++)
        {
            var (key, finding) = keyed[index];
            var item = Items.FirstOrDefault(i => i.Key == key && !i.IsClosing);
            if (item is null)
            {
                item = new FindingItemViewModel(key, finding) { AnimateIn = Animate };
                Items.Insert(PositionFor(index), item);
                if (Animate)
                    After(Fold + Fold, () => item.AnimateIn = false);
            }
            else
            {
                item.Finding = finding;
                var at = Items.IndexOf(item);
                var to = PositionFor(index);
                if (at != to && to < Items.Count)
                    Items.Move(at, to);
            }
        }

        Count = keyed.Count;
        Summary = string.Join(" · ", new[]
        {
            (FindingSeverity.Critical, "critique"), (FindingSeverity.Warning, "attention"), (FindingSeverity.Info, "info"),
        }.Select(s => (Count: findings.Count(f => f.Severity == s.Item1), Label: s.Item2))
         .Where(s => s.Count > 0)
         .Select(s => $"{s.Count} {s.Label}"));
        ApplyLimit();
    }

    // Position of the index-th live finding in Items, closing ones (still folding) being skipped.
    private int PositionFor(int index)
    {
        var live = 0;
        for (var i = 0; i < Items.Count; i++)
        {
            if (Items[i].IsClosing)
                continue;
            if (live == index)
                return i;
            live++;
        }
        return Items.Count;
    }

    private void Remove(FindingItemViewModel item)
    {
        if (!Animate)
        {
            Items.Remove(item);
            return;
        }
        item.IsClosing = true;
        After(Fold, () => Items.Remove(item));
    }

    private void ApplyLimit()
    {
        var live = 0;
        foreach (var item in Items)
        {
            if (item.IsClosing)
                continue;
            item.IsOverflow = CanExpand && !IsExpanded && live >= Limit;
            live++;
        }
    }

    private static void After(TimeSpan delay, Action action) =>
        DispatcherTimer.RunOnce(action, delay);
}

/// <summary>One finding on screen, with its animation state.</summary>
public partial class FindingItemViewModel(string key, Finding finding) : ViewModelBase
{
    public string Key { get; } = key;

    [ObservableProperty]
    public partial Finding Finding { get; set; } = finding;

    /// <summary>Unfold when first shown (it appeared while the page was on screen).</summary>
    [ObservableProperty]
    public partial bool AnimateIn { get; set; }

    /// <summary>Folding before it leaves the list.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsCollapsed))]
    public partial bool IsClosing { get; set; }

    /// <summary>Beyond the limit, behind « Voir plus ».</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsCollapsed))]
    public partial bool IsOverflow { get; set; }

    public bool IsCollapsed => IsClosing || IsOverflow;
}
