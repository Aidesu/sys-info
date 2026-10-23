using System;
using System.Linq;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using SysInfo.ViewModels.Sections;

namespace SysInfo.Views.Sections;

/// <summary>
/// Sortable table. The number of columns comes from the module, so the grid is built in code:
/// one header row of sort buttons, then one row per line (a Border carrying the rule and the hover,
/// with the cells on top). Numeric columns: right-aligned, mono; text columns: Body.
/// The edge of each header can be dragged to resize its column (double-click: back to the automatic width); the
/// header's context menu and the « Colonnes » button show or hide columns. The layout is saved by the view model.
/// </summary>
public partial class TableSectionView : UserControl
{
    private const double CellPadding = 12; // = Space12
    private TableSectionViewModel? _viewModel;
    private bool _resizing;     // a column edge is being dragged: refreshes wait, so the drag is not reset
    private bool _pendingBuild;
    private readonly System.Collections.Generic.List<TextBlock[]> _cells = [];   // cells by row, visible columns

    public TableSectionView()
    {
        InitializeComponent();
    }

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);

        if (_viewModel is not null)
        {
            _viewModel.Changed -= OnChanged;
            _viewModel.CellsChanged -= OnCellsChanged;
        }
        _viewModel = DataContext as TableSectionViewModel;
        if (_viewModel is not null)
        {
            _viewModel.Changed += OnChanged;
            _viewModel.CellsChanged += OnCellsChanged;
        }

        Build();
    }

    private void OnChanged(object? sender, EventArgs e)
    {
        if (_resizing)
            _pendingBuild = true;
        else
            Build();
    }

    // Same grid, new values: only the texts change (no new controls, no new layout of the grid).
    private void OnCellsChanged(object? sender, EventArgs e)
    {
        if (_resizing || _viewModel is not { } vm || _cells.Count != vm.Rows.Count)
        {
            OnChanged(sender, e);
            return;
        }
        var columns = vm.VisibleColumns;
        for (var r = 0; r < _cells.Count; r++)
        {
            var row = vm.Rows[r];
            var cells = _cells[r];
            for (var p = 0; p < cells.Length && p < columns.Count; p++)
            {
                var text = columns[p].Index < row.Count ? row[columns[p].Index] : string.Empty;
                if (cells[p].Text != text)
                    cells[p].Text = text;
            }
        }
    }

    // « Colonnes » button of the card header: same menu as the header's context menu.
    private void OnColumnsClick(object? sender, RoutedEventArgs e)
    {
        if (sender is Control button && ColumnsMenu() is { } menu)
        {
            menu.PlacementTarget = button;
            menu.Open(button);
        }
    }

    // One check item per column (visible or hidden), then « Réinitialiser les colonnes ».
    private ContextMenu? ColumnsMenu()
    {
        if (_viewModel is not { } vm)
            return null;
        var menu = new ContextMenu();
        foreach (var column in vm.Columns)
        {
            var item = new MenuItem
            {
                Header = column.Label,
                ToggleType = MenuItemToggleType.CheckBox,
                IsChecked = !column.IsHidden,
                IsEnabled = column.IsHidden || vm.VisibleColumns.Count > 1,
            };
            var index = column.Index;
            item.Click += (_, _) => vm.ToggleColumn(index);
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Header = "Réinitialiser les colonnes", Command = vm.ResetLayoutCommand, IsEnabled = vm.HasCustomLayout });
        return menu;
    }

    private void Build()
    {
        _pendingBuild = false;
        _cells.Clear();
        var grid = TableGrid;
        grid.Children.Clear();
        grid.ColumnDefinitions.Clear();
        grid.RowDefinitions.Clear();

        if (_viewModel is not { } vm || vm.Columns.Count == 0)
            return;
        var columns = vm.VisibleColumns;

        // Width chosen by the user, else: the first text column takes the remaining width, the others fit their
        // content. Without such a column, an empty one at the end takes it, so the numbers stay next to each other.
        var stretch = columns.FirstOrDefault(c => !c.IsNumeric && c.Width is null)?.Index ?? -1;
        foreach (var column in columns)
        {
            grid.ColumnDefinitions.Add(
                column.Width is { } width ? new ColumnDefinition(width, GridUnitType.Pixel)
                : column.Index == stretch ? new ColumnDefinition(1, GridUnitType.Star) { MinWidth = 140 }
                : new ColumnDefinition(GridLength.Auto) { MinWidth = 88 });
        }
        if (stretch < 0)
            grid.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));

        var rowHeight = (double)(this.FindResource("RowHeight") ?? 32.0);

        // Header: sort button, and the edge that resizes the column; right-click: the columns menu.
        grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        for (var position = 0; position < columns.Count; position++)
        {
            var column = columns[position];
            var header = new Panel { Children = { HeaderButton(vm, column), Resizer(vm, column, position) } };
            header.ContextRequested += (_, e) =>
            {
                if (ColumnsMenu() is { } menu)
                {
                    menu.Open(header);
                    e.Handled = true;
                }
            };
            Grid.SetColumn(header, position);
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
            var rowCells = new TextBlock[columns.Count];
            _cells.Add(rowCells);
            for (var position = 0; position < columns.Count; position++)
            {
                var column = columns[position];
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
                rowCells[position] = cell;
                Grid.SetRow(cell, gridRow);
                Grid.SetColumn(cell, position);
                grid.Children.Add(cell);
            }
        }
    }

    // Right edge of a header: drag to resize the column, double-click to fit it to its content again.
    private Control Resizer(TableSectionViewModel vm, TableColumn column, int position)
    {
        var thumb = new Thumb { Classes = { "ColumnResizer" }, HorizontalAlignment = HorizontalAlignment.Right };
        ToolTip.SetTip(thumb, "Glisser pour redimensionner · double-clic : largeur automatique");
        AutomationProperties.SetName(thumb, $"Largeur de la colonne {column.Label}");
        var width = 0.0;
        thumb.DragStarted += (_, _) =>
        {
            _resizing = true;
            width = TableGrid.ColumnDefinitions[position].ActualWidth;
        };
        thumb.DragDelta += (_, e) =>
        {
            width = Math.Max(48, width + e.Vector.X);
            TableGrid.ColumnDefinitions[position].Width = new GridLength(width, GridUnitType.Pixel);
        };
        thumb.DragCompleted += (_, _) =>
        {
            _resizing = false;
            vm.SetWidth(column.Index, width);
            if (_pendingBuild)
                Build();
        };
        thumb.DoubleTapped += (_, e) =>
        {
            vm.ResetWidth(column.Index);
            e.Handled = true;
        };
        return thumb;
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
