using System;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace SysInfo.Controls;

/// <summary>
/// Short history line, no axes: it shows a trend, not values (design system, Metric guide).
/// The newest point is on the right; the chart fills up from the right until Capacity points are reached,
/// then scrolls without animation between samples.
/// </summary>
public sealed class Sparkline : Control
{
    public static readonly StyledProperty<IReadOnlyList<double>?> ValuesProperty =
        AvaloniaProperty.Register<Sparkline, IReadOnlyList<double>?>(nameof(Values));

    public static readonly StyledProperty<double> MaximumProperty =
        AvaloniaProperty.Register<Sparkline, double>(nameof(Maximum), 100);

    public static readonly StyledProperty<int> CapacityProperty =
        AvaloniaProperty.Register<Sparkline, int>(nameof(Capacity), 60);

    public static readonly StyledProperty<IBrush?> StrokeProperty =
        AvaloniaProperty.Register<Sparkline, IBrush?>(nameof(Stroke));

    public static readonly StyledProperty<IBrush?> FillProperty =
        AvaloniaProperty.Register<Sparkline, IBrush?>(nameof(Fill));

    static Sparkline()
    {
        AffectsRender<Sparkline>(ValuesProperty, MaximumProperty, CapacityProperty, StrokeProperty, FillProperty);
    }

    public IReadOnlyList<double>? Values { get => GetValue(ValuesProperty); set => SetValue(ValuesProperty, value); }
    public double Maximum { get => GetValue(MaximumProperty); set => SetValue(MaximumProperty, value); }
    public int Capacity { get => GetValue(CapacityProperty); set => SetValue(CapacityProperty, value); }
    public IBrush? Stroke { get => GetValue(StrokeProperty); set => SetValue(StrokeProperty, value); }
    public IBrush? Fill { get => GetValue(FillProperty); set => SetValue(FillProperty, value); }

    private const double StrokeThickness = 1.5;

    public override void Render(DrawingContext context)
    {
        var values = Values;
        var width = Bounds.Width;
        var height = Bounds.Height;
        if (values is null || values.Count < 2 || width <= 0 || height <= 0 || Maximum <= 0)
            return;

        var count = Math.Min(values.Count, Capacity);
        var step = width / Math.Max(1, Capacity - 1);
        var top = StrokeThickness;
        var usable = height - 2 * StrokeThickness;

        Point PointAt(int i)
        {
            var value = values[values.Count - count + i];
            var x = width - (count - 1 - i) * step;
            var y = top + usable * (1 - Math.Clamp(value / Maximum, 0, 1));
            return new Point(x, y);
        }

        var line = new StreamGeometry();
        var area = new StreamGeometry();
        using (var l = line.Open())
        using (var a = area.Open())
        {
            var first = PointAt(0);
            l.BeginFigure(first, false);
            a.BeginFigure(new Point(first.X, height), true);
            a.LineTo(first);
            for (var i = 1; i < count; i++)
            {
                var p = PointAt(i);
                l.LineTo(p);
                a.LineTo(p);
            }
            a.LineTo(new Point(width, height));
            l.EndFigure(false);
            a.EndFigure(true);
        }

        if (Fill is { } fill)
            context.DrawGeometry(fill, null, area);
        if (Stroke is { } stroke)
            context.DrawGeometry(null, new Pen(stroke, StrokeThickness, lineJoin: PenLineJoin.Round), line);
    }
}
