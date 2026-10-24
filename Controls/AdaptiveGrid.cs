using System;
using Avalonia;
using Avalonia.Controls;

namespace SysInfo.Controls;

/// <summary>
/// Grid of equal-width items whose number of columns follows the available width: as many as fit with
/// <see cref="MinItemWidth"/>, at most <see cref="MaxColumns"/>, then balanced (5 items on 4 columns → 3 + 2, not 4 + 1).
/// Two grids with the same settings and width get the same columns (metric cards and their charts stay aligned).
/// Each row is as tall as its tallest item; items are stretched to it.
/// </summary>
public sealed class AdaptiveGrid : Panel
{
    public static readonly StyledProperty<double> MinItemWidthProperty =
        AvaloniaProperty.Register<AdaptiveGrid, double>(nameof(MinItemWidth), 240);

    public static readonly StyledProperty<int> MaxColumnsProperty =
        AvaloniaProperty.Register<AdaptiveGrid, int>(nameof(MaxColumns), 3);

    public static readonly StyledProperty<double> ColumnSpacingProperty =
        AvaloniaProperty.Register<AdaptiveGrid, double>(nameof(ColumnSpacing), 12);

    public static readonly StyledProperty<double> RowSpacingProperty =
        AvaloniaProperty.Register<AdaptiveGrid, double>(nameof(RowSpacing), 12);

    static AdaptiveGrid()
    {
        AffectsMeasure<AdaptiveGrid>(MinItemWidthProperty, MaxColumnsProperty, ColumnSpacingProperty, RowSpacingProperty);
    }

    public double MinItemWidth { get => GetValue(MinItemWidthProperty); set => SetValue(MinItemWidthProperty, value); }
    public int MaxColumns { get => GetValue(MaxColumnsProperty); set => SetValue(MaxColumnsProperty, value); }
    public double ColumnSpacing { get => GetValue(ColumnSpacingProperty); set => SetValue(ColumnSpacingProperty, value); }
    public double RowSpacing { get => GetValue(RowSpacingProperty); set => SetValue(RowSpacingProperty, value); }

    private int Columns(double width, int count)
    {
        if (count == 0)
            return 1;
        var fit = double.IsInfinity(width) ? MaxColumns : (int)Math.Floor((width + ColumnSpacing) / (MinItemWidth + ColumnSpacing));
        var columns = Math.Clamp(fit, 1, Math.Max(1, Math.Min(MaxColumns, count)));
        // Balanced rows: the same number of rows with as few columns as possible.
        var rows = (int)Math.Ceiling(count / (double)columns);
        return (int)Math.Ceiling(count / (double)rows);
    }

    private double ItemWidth(double width, int columns) =>
        double.IsInfinity(width) ? MinItemWidth : Math.Max(0, (width - ColumnSpacing * (columns - 1)) / columns);

    protected override Size MeasureOverride(Size availableSize)
    {
        var count = Children.Count;
        var columns = Columns(availableSize.Width, count);
        var itemWidth = ItemWidth(availableSize.Width, columns);
        double height = 0, rowHeight = 0;
        for (var i = 0; i < count; i++)
        {
            Children[i].Measure(new Size(itemWidth, double.PositiveInfinity));
            rowHeight = Math.Max(rowHeight, Children[i].DesiredSize.Height);
            if (i % columns == columns - 1 || i == count - 1)
            {
                height += rowHeight + (i == count - 1 ? 0 : RowSpacing);
                rowHeight = 0;
            }
        }
        var width = double.IsInfinity(availableSize.Width) ? columns * itemWidth + (columns - 1) * ColumnSpacing : availableSize.Width;
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var count = Children.Count;
        var columns = Columns(finalSize.Width, count);
        var itemWidth = ItemWidth(finalSize.Width, columns);
        double y = 0;
        for (var start = 0; start < count; start += columns)
        {
            var end = Math.Min(start + columns, count);
            double rowHeight = 0;
            for (var i = start; i < end; i++)
                rowHeight = Math.Max(rowHeight, Children[i].DesiredSize.Height);
            for (var i = start; i < end; i++)
                Children[i].Arrange(new Rect((i - start) * (itemWidth + ColumnSpacing), y, itemWidth, rowHeight));
            y += rowHeight + RowSpacing;
        }
        return finalSize;
    }
}
