using System;
using System.Collections.Generic;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// Sortable table. Numeric columns (every non-empty value is a number) are right-aligned, in mono,
/// and sort descending on the first click. A long table shows its first <see cref="Limit"/> rows (after sorting)
/// and « Voir les N autres lignes ». Sort and expansion survive refreshes. Columns can be resized (drag the edge of a
/// header, double-click to fit) and hidden (header context menu); this layout is saved (<see cref="TableLayouts"/>).
/// </summary>
public partial class TableSectionViewModel : SectionViewModel
{
    private TableSection _data;

    public TableSectionViewModel(TableSection section) : base(section)
    {
        _data = section;
        Rebuild();
    }

    public IReadOnlyList<TableColumn> Columns { get; private set; } = [];

    /// <summary>Rows in display order, already formatted.</summary>
    public IReadOnlyList<IReadOnlyList<string>> Rows { get; private set; } = [];

    /// <summary>Rows shown before « Voir plus ».</summary>
    public const int Limit = 10;

    // Shown in full up to Limit + Margin: no « Voir plus » for one or two hidden rows.
    private const int Margin = 2;

    /// <summary>All the rows are shown.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(MoreText))]
    public partial bool IsExpanded { get; set; }

    partial void OnIsExpandedChanged(bool value) => Rebuild();

    public bool CanExpand => _data.Rows.Count > Limit + Margin;

    public string MoreText => IsExpanded ? "Voir moins" : $"Voir les {Formatting.Number(_data.Rows.Count - Limit)} autres lignes";

    [RelayCommand]
    private void ToggleExpanded() => IsExpanded = !IsExpanded;

    public int? SortColumn { get; private set; }

    /// <summary>Key of the saved layout: title and column labels.</summary>
    public string LayoutKey => TableLayouts.KeyOf(Title, _data.Columns);

    private TableLayout Layout => TableLayouts.Get(LayoutKey) ?? new TableLayout();

    /// <summary>Visible columns (hidden ones left out), in their order.</summary>
    public IReadOnlyList<TableColumn> VisibleColumns => [.. Columns.Where(c => !c.IsHidden)];

    public bool HasCustomLayout => TableLayouts.Get(LayoutKey) is not null;

    /// <summary>Keeps a column width chosen by dragging (pixels). No rebuild: the view already shows it.</summary>
    public void SetWidth(int column, double width)
    {
        var layout = Layout;
        layout.Widths[Columns[column].Label] = Math.Round(Math.Max(48, width));
        TableLayouts.Set(LayoutKey, layout);
        Columns = [.. Columns.Select(c => c.Index == column ? c with { Width = layout.Widths[c.Label] } : c)];
    }

    /// <summary>Back to the automatic width (fit to content).</summary>
    public void ResetWidth(int column)
    {
        var layout = Layout;
        if (layout.Widths.Remove(Columns[column].Label))
        {
            TableLayouts.Set(LayoutKey, layout);
            Rebuild();
        }
    }

    /// <summary>Hides or shows a column; the last visible column cannot be hidden.</summary>
    public void ToggleColumn(int column)
    {
        var layout = Layout;
        var label = Columns[column].Label;
        if (!layout.Hidden.Remove(label))
        {
            if (VisibleColumns.Count <= 1)
                return;
            layout.Hidden.Add(label);
        }
        TableLayouts.Set(LayoutKey, layout);
        Rebuild();
    }

    /// <summary>Widths and visibility back to the defaults.</summary>
    [RelayCommand]
    private void ResetLayout()
    {
        TableLayouts.Set(LayoutKey, null);
        Rebuild();
    }

    public bool SortDescending { get; private set; }

    public string CountText => _data.Rows.Count switch
    {
        0 => "Aucune ligne",
        1 => "1 ligne",
        var n when CanExpand && !IsExpanded => $"{Limit} sur {Formatting.Number(n)} lignes",
        var n => $"{Formatting.Number(n)} lignes",
    };

    /// <summary>Raised when columns, the number of rows or the layout change: the view rebuilds its grid.</summary>
    public event EventHandler? Changed;

    /// <summary>Raised when only cell texts changed (same columns, same number of rows): the view updates them in place.</summary>
    public event EventHandler? CellsChanged;

    public override void Update(Section section)
    {
        _data = (TableSection)section;
        Rebuild();
    }

    [RelayCommand]
    private void Sort(int column)
    {
        if (SortColumn == column)
        {
            SortDescending = !SortDescending;
        }
        else
        {
            SortColumn = column;
            SortDescending = Columns[column].IsNumeric;
        }
        Rebuild();
    }

    // Rebuilt on every refresh; the view is told only what changed: nothing (most refreshes of a cached table),
    // cell texts (a process list every 2 s), or the shape (columns, row count, layout).
    private void Rebuild()
    {
        var previousColumns = Columns;
        var previousRows = Rows;
        var count = _data.Columns.Count;
        if (SortColumn >= count)
            SortColumn = null;

        var layout = Layout;
        Columns = Enumerable.Range(0, count)
            .Select(i => new TableColumn(
                i,
                _data.Columns[i],
                IsNumeric: _data.Rows.Select(r => Cell(r, i)).Where(v => v is not null).All(v => Formatting.ToDouble(v) is not null)
                           && _data.Rows.Any(r => Cell(r, i) is not null),
                SortState: SortColumn == i ? (SortDescending ? -1 : 1) : 0)
            {
                Width = layout.Widths.TryGetValue(_data.Columns[i], out var w) ? w : null,
                IsHidden = layout.Hidden.Contains(_data.Columns[i]),
            })
            .ToList();
        // A layout that would hide every column is ignored.
        if (Columns.All(c => c.IsHidden))
            Columns = [.. Columns.Select(c => c with { IsHidden = false })];

        IEnumerable<IReadOnlyList<object?>> rows = _data.Rows;
        if (SortColumn is { } c)
        {
            var comparer = Comparer<object?>.Create((a, b) => CompareCells(a, b, Columns[c].IsNumeric));
            rows = SortDescending ? rows.OrderByDescending(r => Cell(r, c), comparer) : rows.OrderBy(r => Cell(r, c), comparer);
        }

        if (CanExpand && !IsExpanded)
            rows = rows.Take(Limit);

        Rows = rows
            .Select(r => (IReadOnlyList<string>)Enumerable.Range(0, count).Select(i => FormatCell(Cell(r, i))).ToList())
            .ToList();

        var sameShape = previousColumns.SequenceEqual(Columns) && previousRows.Count == Rows.Count;
        if (sameShape && previousRows.Zip(Rows).All(p => p.First.SequenceEqual(p.Second)))
            return;

        OnPropertyChanged(nameof(CountText));
        OnPropertyChanged(nameof(HasCustomLayout));
        OnPropertyChanged(nameof(CanExpand));
        OnPropertyChanged(nameof(MoreText));
        if (sameShape)
            CellsChanged?.Invoke(this, EventArgs.Empty);
        else
            Changed?.Invoke(this, EventArgs.Empty);
    }

    private static string FormatCell(object? value) =>
        Formatting.ToDouble(value) is { } number ? Formatting.TableNumber(number) : SectionParser.Format(value);

    private static object? Cell(IReadOnlyList<object?> row, int index) => index < row.Count ? row[index] : null;

    private static int CompareCells(object? a, object? b, bool numeric)
    {
        if (numeric)
            return Nullable.Compare(Formatting.ToDouble(a), Formatting.ToDouble(b));
        return string.Compare(a?.ToString(), b?.ToString(), StringComparison.CurrentCultureIgnoreCase);
    }
}

/// <param name="SortState">0 = not sorted, 1 = ascending, -1 = descending.</param>
public sealed record TableColumn(int Index, string Label, bool IsNumeric, int SortState)
{
    /// <summary>Width chosen by the user (pixels); null = automatic.</summary>
    public double? Width { get; init; }

    public bool IsHidden { get; init; }
}
