using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using Avalonia;
using Avalonia.Controls;

namespace SysInfo.Controls;

/// <summary>An item whose data asks for the full width of a <see cref="MasonryPanel"/> (charts, very wide tables).</summary>
public interface IWideBlock
{
    bool IsWide { get; }
}

/// <summary>
/// Cards of a page on wide screens (21:9, 32:9…): as many columns as fit with <see cref="MinColumnWidth"/>, at most
/// <see cref="MaxColumns"/>; each card goes to the shortest column, a wide card (<see cref="IWideBlock"/>) spans them
/// all and starts below the tallest. One column on an ordinary or portrait screen: the page reads as before.
/// A card keeps its column while the page refreshes (only a change of cards or of width redistributes them), so that a
/// card growing by a few pixels never makes the others jump from one column to the other.
/// Vertical spacing is the cards' own bottom margin (a folded card leaves no gap).
/// </summary>
public sealed class MasonryPanel : Panel
{
    public static readonly StyledProperty<double> MinColumnWidthProperty =
        AvaloniaProperty.Register<MasonryPanel, double>(nameof(MinColumnWidth), 760);

    public static readonly StyledProperty<int> MaxColumnsProperty =
        AvaloniaProperty.Register<MasonryPanel, int>(nameof(MaxColumns), 3);

    public static readonly StyledProperty<double> ColumnSpacingProperty =
        AvaloniaProperty.Register<MasonryPanel, double>(nameof(ColumnSpacing), 12);

    static MasonryPanel()
    {
        AffectsMeasure<MasonryPanel>(MinColumnWidthProperty, MaxColumnsProperty, ColumnSpacingProperty);
    }

    public double MinColumnWidth { get => GetValue(MinColumnWidthProperty); set => SetValue(MinColumnWidthProperty, value); }
    public int MaxColumns { get => GetValue(MaxColumnsProperty); set => SetValue(MaxColumnsProperty, value); }
    public double ColumnSpacing { get => GetValue(ColumnSpacingProperty); set => SetValue(ColumnSpacingProperty, value); }

    // Column chosen for each card (-1 = full width), kept between layouts.
    private readonly ConditionalWeakTable<Control, StrongBox<int>> _columns = new();
    private int _layoutColumns;
    private int _layoutSignature;
    private readonly List<Rect> _slots = [];

    private int ColumnCount(double width) =>
        double.IsInfinity(width) ? 1 : Math.Clamp((int)Math.Floor((width + ColumnSpacing) / (MinColumnWidth + ColumnSpacing)), 1, Math.Max(1, MaxColumns));

    private static bool IsWide(Control child) => child.DataContext is IWideBlock { IsWide: true };

    protected override Size MeasureOverride(Size availableSize)
    {
        var columns = ColumnCount(availableSize.Width);
        var full = double.IsInfinity(availableSize.Width) ? 0 : availableSize.Width;
        var columnWidth = columns == 1 ? availableSize.Width : (full - ColumnSpacing * (columns - 1)) / columns;

        // Cards added, removed, reordered, or a new number of columns: the columns are chosen again.
        var signature = Children.Aggregate(17, (h, c) => h * 31 + RuntimeHelpers.GetHashCode(c) + (IsWide(c) ? 1 : 0));
        var reassign = columns != _layoutColumns || signature != _layoutSignature;
        _layoutColumns = columns;
        _layoutSignature = signature;

        var heights = new double[columns];
        _slots.Clear();
        foreach (var child in Children)
        {
            if (columns == 1)
            {
                child.Measure(new Size(availableSize.Width, double.PositiveInfinity));
                _slots.Add(new Rect(0, heights[0], full, child.DesiredSize.Height));
                heights[0] += child.DesiredSize.Height;
                continue;
            }

            var box = _columns.GetValue(child, _ => new StrongBox<int>(-2));
            if (reassign || box.Value == -2)
                box.Value = IsWide(child) ? -1 : Array.IndexOf(heights, heights.Min());

            if (box.Value < 0 || box.Value >= columns)
            {
                // Full width: below the tallest column, then every column continues under it.
                child.Measure(new Size(full, double.PositiveInfinity));
                var top = heights.Max();
                _slots.Add(new Rect(0, top, full, child.DesiredSize.Height));
                Array.Fill(heights, top + child.DesiredSize.Height);
            }
            else
            {
                var c = box.Value;
                child.Measure(new Size(columnWidth, double.PositiveInfinity));
                _slots.Add(new Rect(c * (columnWidth + ColumnSpacing), heights[c], columnWidth, child.DesiredSize.Height));
                heights[c] += child.DesiredSize.Height;
            }
        }
        return new Size(full, heights.Length == 0 ? 0 : heights.Max());
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        // Measured with the same width: the slots computed there apply (else measure again first).
        if (_slots.Count != Children.Count)
            Measure(finalSize);
        for (var i = 0; i < Children.Count && i < _slots.Count; i++)
        {
            var slot = _slots[i];
            Children[i].Arrange(_layoutColumns == 1 ? new Rect(0, slot.Y, finalSize.Width, slot.Height) : slot);
        }
        return finalSize;
    }
}
