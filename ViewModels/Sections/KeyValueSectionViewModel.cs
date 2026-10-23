using System.Collections.Generic;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Key → value list. A long list shows its first <see cref="Limit"/> items, the others unfold under « Voir plus ».
/// </summary>
public partial class KeyValueSectionViewModel : SectionViewModel
{
    /// <summary>Items shown before « Voir plus ».</summary>
    public const int Limit = 10;

    // Shown in full up to Limit + Margin.
    private const int Margin = 2;

    public KeyValueSectionViewModel(KeyValueSection section) : base(section)
    {
        Update(section);
    }

    /// <summary>Items always shown.</summary>
    [ObservableProperty]
    public partial IReadOnlyList<KeyValueItem> Items { get; private set; } = [];

    /// <summary>Items behind « Voir plus ».</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanExpand), nameof(MoreText))]
    public partial IReadOnlyList<KeyValueItem> MoreItems { get; private set; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(MoreText))]
    public partial bool IsExpanded { get; set; }

    public bool CanExpand => MoreItems.Count > 0;

    public string MoreText => IsExpanded ? "Voir moins" : $"Voir les {MoreItems.Count} autres";

    [RelayCommand]
    private void ToggleExpanded() => IsExpanded = !IsExpanded;

    public override void Update(Section section)
    {
        var all = ((KeyValueSection)section).Items;
        var split = all.Count > Limit + Margin;
        var items = split ? all.Take(Limit).ToList() : all;
        var more = split ? all.Skip(Limit).ToList() : (IReadOnlyList<KeyValueItem>)[];
        // Same lists as before: keep them, so the view is not rebuilt on each refresh.
        if (!items.SequenceEqual(Items))
            Items = items;
        if (!more.SequenceEqual(MoreItems))
            MoreItems = more;
    }
}
