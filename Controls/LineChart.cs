using System;
using System.Collections.Generic;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using SysInfo.Services;

namespace SysInfo.Controls;

/// <summary>
/// Real-time line chart on a sliding window (design system, LineChart guide): main series as Accent line + area,
/// optional second series as a line only (ChartSecondary), horizontal grid only, round tick values on the left,
/// time axis from "−2 min" to "maintenant", and on hover a cursor, dots and a tooltip with the time and the values.
/// The newest sample is on the right; the chart fills up from the right until Capacity samples.
/// NaN values are gaps: the line is interrupted there (ex. a lost ping).
/// </summary>
public sealed class LineChart : Control
{
    public static readonly StyledProperty<IReadOnlyList<double>?> ValuesProperty =
        AvaloniaProperty.Register<LineChart, IReadOnlyList<double>?>(nameof(Values));

    /// <summary>Optional second series, aligned on <see cref="Values"/>.</summary>
    public static readonly StyledProperty<IReadOnlyList<double>?> Values2Property =
        AvaloniaProperty.Register<LineChart, IReadOnlyList<double>?>(nameof(Values2));

    /// <summary>Series names, shown in the tooltip when there are two series.</summary>
    public static readonly StyledProperty<string?> Label1Property =
        AvaloniaProperty.Register<LineChart, string?>(nameof(Label1));

    public static readonly StyledProperty<string?> Label2Property =
        AvaloniaProperty.Register<LineChart, string?>(nameof(Label2));

    public static readonly StyledProperty<IBrush?> Stroke2Property =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(Stroke2));

    public static readonly StyledProperty<IReadOnlyList<DateTime>?> TimesProperty =
        AvaloniaProperty.Register<LineChart, IReadOnlyList<DateTime>?>(nameof(Times));

    /// <summary>Top of the Y axis; NaN = rounded up above the highest value.</summary>
    public static readonly StyledProperty<double> MaximumProperty =
        AvaloniaProperty.Register<LineChart, double>(nameof(Maximum), double.NaN);

    /// <summary>
    /// Time covered by the chart (refresh interval × (Capacity − 1)). When set, samples are placed by their time, not
    /// their rank: a page refreshed less often while hidden leaves wider gaps instead of a squeezed time axis.
    /// </summary>
    public static readonly StyledProperty<TimeSpan> WindowProperty =
        AvaloniaProperty.Register<LineChart, TimeSpan>(nameof(Window));

    public static readonly StyledProperty<int> CapacityProperty =
        AvaloniaProperty.Register<LineChart, int>(nameof(Capacity), 60);

    public static readonly StyledProperty<string?> UnitProperty =
        AvaloniaProperty.Register<LineChart, string?>(nameof(Unit));

    public static readonly StyledProperty<IBrush?> StrokeProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(Stroke));

    public static readonly StyledProperty<IBrush?> FillProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(Fill));

    public static readonly StyledProperty<IBrush?> GridBrushProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(GridBrush));

    public static readonly StyledProperty<IBrush?> LabelBrushProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(LabelBrush));

    public static readonly StyledProperty<IBrush?> TextBrushProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(TextBrush));

    public static readonly StyledProperty<IBrush?> CursorBrushProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(CursorBrush));

    public static readonly StyledProperty<IBrush?> SurfaceBrushProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(SurfaceBrush));

    public static readonly StyledProperty<IBrush?> TipBackgroundProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(TipBackground));

    public static readonly StyledProperty<IBrush?> TipBorderProperty =
        AvaloniaProperty.Register<LineChart, IBrush?>(nameof(TipBorder));

    public static readonly StyledProperty<FontFamily> LabelFontProperty =
        AvaloniaProperty.Register<LineChart, FontFamily>(nameof(LabelFont), FontFamily.Default);

    static LineChart()
    {
        AffectsRender<LineChart>(ValuesProperty, Values2Property, Label1Property, Label2Property, Stroke2Property, TimesProperty, WindowProperty, MaximumProperty, CapacityProperty, UnitProperty,
            StrokeProperty, FillProperty, GridBrushProperty, LabelBrushProperty, TextBrushProperty, CursorBrushProperty,
            SurfaceBrushProperty, TipBackgroundProperty, TipBorderProperty, LabelFontProperty);
    }

    public IReadOnlyList<double>? Values { get => GetValue(ValuesProperty); set => SetValue(ValuesProperty, value); }
    public IReadOnlyList<double>? Values2 { get => GetValue(Values2Property); set => SetValue(Values2Property, value); }
    public string? Label1 { get => GetValue(Label1Property); set => SetValue(Label1Property, value); }
    public string? Label2 { get => GetValue(Label2Property); set => SetValue(Label2Property, value); }
    public IBrush? Stroke2 { get => GetValue(Stroke2Property); set => SetValue(Stroke2Property, value); }
    public IReadOnlyList<DateTime>? Times { get => GetValue(TimesProperty); set => SetValue(TimesProperty, value); }
    public TimeSpan Window { get => GetValue(WindowProperty); set => SetValue(WindowProperty, value); }
    public double Maximum { get => GetValue(MaximumProperty); set => SetValue(MaximumProperty, value); }
    public int Capacity { get => GetValue(CapacityProperty); set => SetValue(CapacityProperty, value); }
    public string? Unit { get => GetValue(UnitProperty); set => SetValue(UnitProperty, value); }
    public IBrush? Stroke { get => GetValue(StrokeProperty); set => SetValue(StrokeProperty, value); }
    public IBrush? Fill { get => GetValue(FillProperty); set => SetValue(FillProperty, value); }
    public IBrush? GridBrush { get => GetValue(GridBrushProperty); set => SetValue(GridBrushProperty, value); }
    public IBrush? LabelBrush { get => GetValue(LabelBrushProperty); set => SetValue(LabelBrushProperty, value); }
    public IBrush? TextBrush { get => GetValue(TextBrushProperty); set => SetValue(TextBrushProperty, value); }
    public IBrush? CursorBrush { get => GetValue(CursorBrushProperty); set => SetValue(CursorBrushProperty, value); }
    public IBrush? SurfaceBrush { get => GetValue(SurfaceBrushProperty); set => SetValue(SurfaceBrushProperty, value); }
    public IBrush? TipBackground { get => GetValue(TipBackgroundProperty); set => SetValue(TipBackgroundProperty, value); }
    public IBrush? TipBorder { get => GetValue(TipBorderProperty); set => SetValue(TipBorderProperty, value); }
    public FontFamily LabelFont { get => GetValue(LabelFontProperty); set => SetValue(LabelFontProperty, value); }

    private const double AxisWidth = 36;    // Y labels, right-aligned, 8 px before the plot
    private const double AxisHeight = 20;   // time labels under the plot
    private const double TopPadding = 8;    // room for the top label
    private const double LabelSize = 11;    // ValueSmall
    private const double StrokeThickness = 1.5;

    private Point? _pointer;

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        _pointer = e.GetPosition(this);
        InvalidateVisual();
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _pointer = null;
        InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        var width = Bounds.Width;
        var height = Bounds.Height;
        if (width <= AxisWidth + 10 || height <= AxisHeight + TopPadding + 10)
            return;

        // Transparent background so the whole area receives the pointer.
        context.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));

        var plot = new Rect(AxisWidth, TopPadding, width - AxisWidth, height - AxisHeight - TopPadding);
        var values = Values ?? [];
        var values2 = Values2 is { } second && second.Count == values.Count ? second : null;
        var count = Math.Min(values.Count, Capacity);

        // Y axis: round ticks (1, 2, 2.5, 5 × 10ⁿ), 4 intervals or so; both series count for the top.
        var dataMax = 0.0;
        for (var i = values.Count - count; i < values.Count; i++)
        {
            if (double.IsFinite(values[i]))
                dataMax = Math.Max(dataMax, values[i]);
            if (values2 is not null && double.IsFinite(values2[i]))
                dataMax = Math.Max(dataMax, values2[i]);
        }
        double top, step;
        if (!double.IsNaN(Maximum) && Maximum > 0)
        {
            top = Maximum;
            step = NiceStep(top / 4);
        }
        else
        {
            var target = Math.Max(dataMax * 1.1, 1);
            step = NiceStep(target / 4);
            top = Math.Ceiling(target / step) * step;
        }

        double YOf(double v) => plot.Bottom - plot.Height * Math.Clamp(v / top, 0, 1);

        var gridPen = GridBrush is { } gb ? new Pen(gb, 1) : null;
        for (var tick = 0.0; tick <= top + step * 1e-6; tick += step)
        {
            var y = Math.Round(YOf(tick)) + 0.5;
            if (gridPen is not null)
                context.DrawLine(gridPen, new Point(plot.Left, y), new Point(plot.Right, y));
            DrawText(context, Formatting.Tick(tick), LabelBrush, new Point(plot.Left - 8, y), alignRight: true, centerY: true);
        }

        // Time axis: covered span on the left, "maintenant" on the right.
        var times = Times;
        var labelsY = plot.Bottom + 4;
        DrawText(context, "maintenant", LabelBrush, new Point(plot.Right, labelsY), alignRight: true);
        var timed = Window > TimeSpan.Zero && times is { } tt && tt.Count >= count;
        if (timed)
        {
            DrawText(context, FormatAgo(Window), LabelBrush, new Point(plot.Left, labelsY));
        }
        else if (times is { Count: > 1 } && count > 1)
        {
            var span = times[^1] - times[Math.Max(0, times.Count - count)];
            // The axis is laid out for Capacity samples: extrapolate the left edge from the mean interval.
            var full = TimeSpan.FromTicks(span.Ticks / (count - 1) * (Capacity - 1));
            DrawText(context, FormatAgo(full), LabelBrush, new Point(plot.Left, labelsY));
        }

        if (count < 2)
            return;

        var dx = plot.Width / Math.Max(1, Capacity - 1);
        var lastTime = timed ? times![^1] : default;
        var offset = timed ? times!.Count - count : 0;
        // By time when the window is known (samples may be uneven), else one step per sample.
        double XOf(int i) => timed
            ? plot.Right - (lastTime - times![offset + i]).TotalSeconds / Window.TotalSeconds * plot.Width
            : plot.Right - (count - 1 - i) * dx;
        double ValueAt(IReadOnlyList<double> series, int i) => series[series.Count - count + i];

        // Samples older than the window fall left of the plot: clipped.
        using (context.PushClip(new Rect(plot.Left, 0, plot.Width + StrokeThickness, Bounds.Height)))
        {
            DrawSeries(context, values, count, XOf, YOf, plot.Bottom, Stroke, Fill);
            if (values2 is not null)
                DrawSeries(context, values2, count, XOf, YOf, plot.Bottom, Stroke2, null);
        }

        // Hover: nearest sample under the pointer.
        if (_pointer is not { } pointer || pointer.X < plot.Left - dx / 2)
            return;
        var index = -1;
        var nearest = double.MaxValue;
        for (var i = 0; i < count; i++)
        {
            var distance = Math.Abs(XOf(i) - pointer.X);
            if (XOf(i) >= plot.Left - 1 && distance < nearest)
            {
                nearest = distance;
                index = i;
            }
        }
        if (index < 0)
            return;

        var x = Math.Round(XOf(index)) + 0.5;
        if (CursorBrush is { } cursor)
            context.DrawLine(new Pen(cursor, 1), new Point(x, plot.Top), new Point(x, plot.Bottom));

        var dotPen = SurfaceBrush is { } surface ? new Pen(surface, 2) : null;
        var v1 = ValueAt(values, index);
        var v2 = values2 is not null ? ValueAt(values2, index) : double.NaN;
        if (double.IsFinite(v1))
            context.DrawEllipse(Stroke, dotPen, new Point(XOf(index), YOf(v1)), 4, 4);
        if (double.IsFinite(v2))
            context.DrawEllipse(Stroke2, dotPen, new Point(XOf(index), YOf(v2)), 4, 4);

        var timeText = times is { } t && t.Count >= count ? t[t.Count - count + index].ToString("HH:mm:ss", CultureInfo.InvariantCulture) : string.Empty;
        var rows = new List<(string Label, string Value, IBrush? Swatch)>
        {
            (values2 is not null ? Label1 ?? string.Empty : string.Empty, FormatValue(v1), Stroke),
        };
        if (values2 is not null)
            rows.Add((Label2 ?? string.Empty, FormatValue(v2), Stroke2));
        var anchorY = double.IsFinite(v1) ? YOf(v1) : plot.Top + plot.Height / 2;
        DrawTooltip(context, new Point(XOf(index), anchorY), timeText, rows);
    }

    private string FormatValue(double value) =>
        !double.IsFinite(value) ? "—" : Formatting.Number(value) + (string.IsNullOrEmpty(Unit) ? "" : "\u00a0" + Unit);

    // A series as one figure per run of finite values: NaN interrupts the line (and the area).
    private static void DrawSeries(DrawingContext context, IReadOnlyList<double> series, int count,
        Func<int, double> xOf, Func<double, double> yOf, double bottom, IBrush? stroke, IBrush? fill)
    {
        var line = new StreamGeometry();
        var area = new StreamGeometry();
        using (var l = line.Open())
        using (var a = area.Open())
        {
            var open = false;
            var lastX = 0.0;
            for (var i = 0; i < count; i++)
            {
                var v = series[series.Count - count + i];
                if (!double.IsFinite(v))
                {
                    if (open)
                    {
                        l.EndFigure(false);
                        a.LineTo(new Point(lastX, bottom));
                        a.EndFigure(true);
                        open = false;
                    }
                    continue;
                }
                var p = new Point(xOf(i), yOf(v));
                if (!open)
                {
                    l.BeginFigure(p, false);
                    a.BeginFigure(new Point(p.X, bottom), true);
                    a.LineTo(p);
                    open = true;
                }
                else
                {
                    l.LineTo(p);
                    a.LineTo(p);
                }
                lastX = p.X;
            }
            if (open)
            {
                l.EndFigure(false);
                a.LineTo(new Point(lastX, bottom));
                a.EndFigure(true);
            }
        }
        if (fill is not null)
            context.DrawGeometry(fill, null, area);
        if (stroke is not null)
            context.DrawGeometry(null, new Pen(stroke, StrokeThickness, lineJoin: PenLineJoin.Round, lineCap: PenLineCap.Round), line);
    }

    // Tooltip: the time, then one line per series (a colored dash + name when there are two series, then the value).
    private void DrawTooltip(DrawingContext context, Point at, string time, IReadOnlyList<(string Label, string Value, IBrush? Swatch)> rows)
    {
        var timeText = Format(time, LabelBrush, LabelSize);
        var lines = new List<(FormattedText? Label, FormattedText Value, IBrush? Swatch)>();
        foreach (var row in rows)
            lines.Add((string.IsNullOrEmpty(row.Label) ? null : Format(row.Label, LabelBrush, LabelSize), Format(row.Value, TextBrush, 13), row.Swatch));

        const double swatchWidth = 10, gap = 8;
        var labelWidth = 0.0;
        foreach (var line in lines)
            labelWidth = Math.Max(labelWidth, line.Label?.Width ?? 0);
        var hasLabels = labelWidth > 0;
        var contentWidth = timeText.Width;
        var contentHeight = timeText.Height;
        foreach (var line in lines)
        {
            var w = (hasLabels ? swatchWidth + gap + labelWidth + gap * 2 : 0) + line.Value.Width;
            contentWidth = Math.Max(contentWidth, w);
            contentHeight += line.Value.Height + 2;
        }
        var tipWidth = contentWidth + 24;     // padding Space12
        var tipHeight = contentHeight + 16;   // padding Space8

        // To the right of the cursor, or to the left when it would overflow.
        var x = at.X + 12;
        if (x + tipWidth > Bounds.Width)
            x = at.X - 12 - tipWidth;
        var y = Math.Clamp(at.Y - tipHeight / 2, 0, Math.Max(0, Bounds.Height - tipHeight));
        var box = new Rect(x, y, tipWidth, tipHeight);

        context.DrawRectangle(TipBackground, TipBorder is { } border ? new Pen(border, 1) : null, box, 6, 6); // RadiusMd
        context.DrawText(timeText, new Point(box.X + 12, box.Y + 8));
        var lineY = box.Y + 8 + timeText.Height + 2;
        foreach (var line in lines)
        {
            var lineX = box.X + 12;
            if (hasLabels)
            {
                var midY = lineY + line.Value.Height / 2;
                if (line.Swatch is { } swatch)
                    context.DrawLine(new Pen(swatch, 2, lineCap: PenLineCap.Round), new Point(lineX, midY), new Point(lineX + swatchWidth, midY));
                if (line.Label is { } label)
                    context.DrawText(label, new Point(lineX + swatchWidth + gap, midY - label.Height / 2));
                lineX = box.Right - 12 - line.Value.Width;
            }
            context.DrawText(line.Value, new Point(lineX, lineY));
            lineY += line.Value.Height + 2;
        }
    }

    private void DrawText(DrawingContext context, string text, IBrush? brush, Point anchor, bool alignRight = false, bool centerY = false)
    {
        var formatted = Format(text, brush, LabelSize);
        var x = alignRight ? anchor.X - formatted.Width : anchor.X;
        var y = centerY ? anchor.Y - formatted.Height / 2 : anchor.Y;
        context.DrawText(formatted, new Point(x, y));
    }

    private FormattedText Format(string text, IBrush? brush, double size) =>
        new(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface(LabelFont), size, brush ?? Brushes.Gray);

    /// <summary>Round step for about 4 intervals: 1, 2, 2.5 or 5 × 10ⁿ.</summary>
    private static double NiceStep(double raw)
    {
        if (raw <= 0)
            return 1;
        var magnitude = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        var n = raw / magnitude;
        var nice = n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10;
        return nice * magnitude;
    }

    private static string FormatAgo(TimeSpan span) =>
        span.TotalSeconds < 90 ? $"−{Math.Round(span.TotalSeconds)}\u00a0s" : $"−{Math.Round(span.TotalMinutes)}\u00a0min";
}
