using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace SysInfo.Controls;

/// <summary>
/// Horizontal fill bar (design system, Meter guide): a Border-colored track and a fill proportional to Percent.
/// Always shown with the value in clear text next to it.
/// </summary>
public sealed class Meter : Control
{
    public static readonly StyledProperty<double> PercentProperty =
        AvaloniaProperty.Register<Meter, double>(nameof(Percent));

    public static readonly StyledProperty<IBrush?> FillProperty =
        AvaloniaProperty.Register<Meter, IBrush?>(nameof(Fill));

    public static readonly StyledProperty<IBrush?> TrackProperty =
        AvaloniaProperty.Register<Meter, IBrush?>(nameof(Track));

    public static readonly StyledProperty<double> RadiusProperty =
        AvaloniaProperty.Register<Meter, double>(nameof(Radius), 4);

    static Meter()
    {
        AffectsRender<Meter>(PercentProperty, FillProperty, TrackProperty, RadiusProperty);
        HeightProperty.OverrideDefaultValue<Meter>(6);
    }

    /// <summary>0 to 100.</summary>
    public double Percent { get => GetValue(PercentProperty); set => SetValue(PercentProperty, value); }
    public IBrush? Fill { get => GetValue(FillProperty); set => SetValue(FillProperty, value); }
    public IBrush? Track { get => GetValue(TrackProperty); set => SetValue(TrackProperty, value); }
    public double Radius { get => GetValue(RadiusProperty); set => SetValue(RadiusProperty, value); }

    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        var radius = Math.Min(Radius, bounds.Height / 2);

        if (Track is { } track)
            context.DrawRectangle(track, null, bounds, radius, radius);

        var fillWidth = bounds.Width * Math.Clamp(Percent, 0, 100) / 100;
        if (Fill is { } fill && fillWidth > 0)
            context.DrawRectangle(fill, null, new Rect(0, 0, Math.Max(fillWidth, radius * 2), bounds.Height), radius, radius);
    }
}
