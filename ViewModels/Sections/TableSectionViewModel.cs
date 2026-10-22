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
/// and sort descending on the first click. The sort survives refreshes.
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

    public int? SortColumn { get; private set; }

    public bool SortDescending { get; private set; }

    public string CountText => _data.Rows.Count switch
    {
        0 => "Aucune ligne",
        1 => "1 ligne",
        var n => $"{Formatting.Number(n)} lignes",
    };

    /// <summary>Raised when columns, rows or sort change: the view rebuilds its grid.</summary>
    public event EventHandler? Changed;

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

    private void Rebuild()
    {
        var count = _data.Columns.Count;
        if (SortColumn >= count)
            SortColumn = null;

        Columns = Enumerable.Range(0, count)
            .Select(i => new TableColumn(
                i,
                _data.Columns[i],
                IsNumeric: _data.Rows.Select(r => Cell(r, i)).Where(v => v is not null).All(v => Formatting.ToDouble(v) is not null)
                           && _data.Rows.Any(r => Cell(r, i) is not null),
                SortState: SortColumn == i ? (SortDescending ? -1 : 1) : 0))
            .ToList();

        IEnumerable<IReadOnlyList<object?>> rows = _data.Rows;
        if (SortColumn is { } c)
        {
            var comparer = Comparer<object?>.Create((a, b) => CompareCells(a, b, Columns[c].IsNumeric));
            rows = SortDescending ? rows.OrderByDescending(r => Cell(r, c), comparer) : rows.OrderBy(r => Cell(r, c), comparer);
        }

        Rows = rows
            .Select(r => (IReadOnlyList<string>)Enumerable.Range(0, count).Select(i => FormatCell(Cell(r, i))).ToList())
            .ToList();

        OnPropertyChanged(nameof(CountText));
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
public sealed record TableColumn(int Index, string Label, bool IsNumeric, int SortState);
