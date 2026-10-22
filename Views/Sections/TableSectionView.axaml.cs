using System;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using SysInfo.ViewModels.Sections;

namespace SysInfo.Views.Sections;

/// <summary>
/// Sortable table. The number of columns comes from the module, so the grid is built in code:
/// one header row of sort buttons, then one row per line (a Border carrying the rule and the hover,
/// with the cells on top). Numeric columns: right-aligned, mono; text columns: Body.
/// </summary>
public partial class TableSectionView : UserControl
{
    private const double CellPadding = 12; // = Space12
    private TableSectionViewModel? _viewModel;

    public TableSectionView()
    {
        InitializeComponent();
    }

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);

        if (_viewModel is not null)
            _viewModel.Changed -= OnChanged;
        _viewModel = DataContext as TableSectionViewModel;
        if (_viewModel is not null)
            _viewModel.Changed += OnChanged;

        Build();
    }

    private void OnChanged(object? sender, EventArgs e) => Build();

    private void Build()
    {
        var grid = TableGrid;
        grid.Children.Clear();
        grid.ColumnDefinitions.Clear();
        grid.RowDefinitions.Clear();

        if (_viewModel is not { } vm || vm.Columns.Count == 0)
            return;

        // The first text column takes the remaining width; the others fit their content.
        // Numeric-only table: an empty column at the end takes it, so the numbers stay next to each other.
        var stretch = -1;
        foreach (var column in vm.Columns)
        {
            if (stretch < 0 && !column.IsNumeric)
                stretch = column.Index;
        }

        foreach (var column in vm.Columns)
        {
            grid.ColumnDefinitions.Add(column.Index == stretch
                ? new ColumnDefinition(1, GridUnitType.Star) { MinWidth = 140 }
                : new ColumnDefinition(GridLength.Auto) { MinWidth = 88 });
        }
        if (stretch < 0)
            grid.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));

        var rowHeight = (double)(this.FindResource("RowHeight") ?? 32.0);

        // Header
        grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        foreach (var column in vm.Columns)
        {
            var header = HeaderButton(vm, column);
            Grid.SetColumn(header, column.Index);
            grid.Children.Add(header);
        }

        // Rows
        for (var r = 0; r < vm.Rows.Count; r++)
        {
            var gridRow = r + 1;
            grid.RowDefinitions.Add(new RowDefinition(rowHeight, GridUnitType.Pixel));

            var background = new Border { Classes = { "TableRow" } };
            Grid.SetRow(background, gridRow);
            Grid.SetColumnSpan(background, grid.ColumnDefinitions.Count);
            grid.Children.Add(background);

            var row = vm.Rows[r];
            foreach (var column in vm.Columns)
            {
                var cell = new TextBlock
                {
                    Text = column.Index < row.Count ? row[column.Index] : string.Empty,
                    Classes = { column.IsNumeric ? "Value" : "Body" },
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                    TextAlignment = column.IsNumeric ? TextAlignment.Right : TextAlignment.Left,
                    Padding = new Thickness(CellPadding, 0),
                    IsHitTestVisible = false, // the row Border gets the hover
                };
                Grid.SetRow(cell, gridRow);
                Grid.SetColumn(cell, column.Index);
                grid.Children.Add(cell);
            }
        }
    }

    private static Control HeaderButton(TableSectionViewModel vm, TableColumn column)
    {
        var label = new TextBlock { Classes = { "Label" }, Text = column.Label, VerticalAlignment = VerticalAlignment.Center };
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };

        // Sort chevron: down = descending, up = ascending; numeric columns put it on the left of the label.
        if (column.SortState != 0)
        {
            var key = column.SortState < 0 ? "Icon.chevron_down" : "Icon.chevron_up";
            var chevron = new PathIcon { Width = 12, Height = 12 };
            if (Application.Current?.TryGetResource(key, null, out var geometry) == true && geometry is Geometry g)
                chevron.Data = g;
            if (column.IsNumeric)
                content.Children.Add(chevron);
            content.Children.Add(label);
            if (!column.IsNumeric)
                content.Children.Add(chevron);
        }
        else
        {
            content.Children.Add(label);
        }

        var button = new Button
        {
            Classes = { "ColumnHeader" },
            Content = content,
            Command = vm.SortCommand,
            CommandParameter = column.Index,
            HorizontalAlignment = column.IsNumeric ? HorizontalAlignment.Right : HorizontalAlignment.Left,
        };
        if (column.SortState != 0)
            button.Classes.Add("Sorted");

        var sortName = column.SortState switch
        {
            < 0 => ", trié par ordre décroissant",
            > 0 => ", trié par ordre croissant",
            _ => string.Empty,
        };
        AutomationProperties.SetName(button, $"Trier par {column.Label}{sortName}");

        return new Border
        {
            Padding = new Thickness(CellPadding, 0, CellPadding, 8),
            Child = button,
        };
    }
}
