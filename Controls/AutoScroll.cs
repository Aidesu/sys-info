using System;
using System.Diagnostics;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.VisualTree;

namespace SysInfo.Controls;

/// <summary>
/// Middle-click auto-scroll, as in web browsers. A middle click over a scrollable area drops a marker; moving the
/// pointer away from it scrolls in that direction, faster the farther it is. Click and release without moving: the
/// mode stays until the next click (or Échap, or the wheel); press, drag and release: it stops on release.
/// Works vertically (the page) and horizontally (wide tables) at once.
/// </summary>
public sealed class AutoScroll
{
    private const double DeadZone = 12;      // pixels around the marker where nothing scrolls
    private const double Speed = 7;          // pixels per second, per pixel beyond the dead zone
    private const double MaxSpeed = 6000;

    private readonly Window _window;
    private readonly Stopwatch _clock = new();
    private ScrollViewer? _vertical;
    private ScrollViewer? _horizontal;
    private Point _anchor;
    private Point _pointer;
    private bool _active;
    private bool _dragged;                   // the pointer left the dead zone while the middle button was down
    private bool _middleDown;
    private Control? _marker;
    private Cursor? _previousCursor;

    private AutoScroll(Window window)
    {
        _window = window;
        window.AddHandler(InputElement.PointerPressedEvent, OnPressed, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        window.AddHandler(InputElement.PointerReleasedEvent, OnReleased, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        window.AddHandler(InputElement.PointerMovedEvent, OnMoved, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        window.AddHandler(InputElement.PointerWheelChangedEvent, (_, _) => Stop(), Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        window.AddHandler(InputElement.KeyDownEvent, (_, e) => { if (_active && e.Key == Key.Escape) { Stop(); e.Handled = true; } }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        window.Deactivated += (_, _) => Stop();
    }

    public static void Attach(Window window) => _ = new AutoScroll(window);

    private void OnPressed(object? sender, PointerPressedEventArgs e)
    {
        var point = e.GetCurrentPoint(_window);
        if (_active)
        {
            // Any click ends the mode, and does nothing else (as in a browser).
            Stop();
            e.Handled = true;
            return;
        }
        if (point.Properties.PointerUpdateKind != PointerUpdateKind.MiddleButtonPressed || e.Source is not Visual source)
            return;

        _vertical = source.GetSelfAndVisualAncestors().OfType<ScrollViewer>().FirstOrDefault(s => s.Extent.Height > s.Viewport.Height + 1);
        _horizontal = source.GetSelfAndVisualAncestors().OfType<ScrollViewer>().FirstOrDefault(s => s.Extent.Width > s.Viewport.Width + 1);
        if (_vertical is null && _horizontal is null)
            return;

        _anchor = _pointer = point.Position;
        _active = true;
        _dragged = false;
        _middleDown = true;
        ShowMarker();
        _previousCursor = _window.Cursor;
        _window.Cursor = new Cursor(StandardCursorType.SizeAll);
        _clock.Restart();
        RequestFrame();
        e.Handled = true;
    }

    private void OnMoved(object? sender, PointerEventArgs e)
    {
        if (!_active)
            return;
        _pointer = e.GetPosition(_window);
        if (_middleDown && Distance(_pointer - _anchor) > DeadZone)
            _dragged = true;
    }

    private void OnReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (!_active || e.InitialPressMouseButton != MouseButton.Middle)
            return;
        _middleDown = false;
        // Press, drag, release: stop. Simple click: keep scrolling until the next click.
        if (_dragged)
            Stop();
        e.Handled = true;
    }

    private void RequestFrame() => _window.RequestAnimationFrame(_ => OnFrame());

    private void OnFrame()
    {
        if (!_active)
            return;
        var seconds = _clock.Elapsed.TotalSeconds;
        _clock.Restart();

        var delta = _pointer - _anchor;
        if (_vertical is { } v)
        {
            var y = Math.Clamp(v.Offset.Y + Velocity(delta.Y) * seconds, 0, Math.Max(0, v.Extent.Height - v.Viewport.Height));
            v.Offset = new Vector(v.Offset.X, y);
        }
        if (_horizontal is { } h)
        {
            var x = Math.Clamp(h.Offset.X + Velocity(delta.X) * seconds, 0, Math.Max(0, h.Extent.Width - h.Viewport.Width));
            h.Offset = new Vector(x, h.Offset.Y);
        }
        RequestFrame();
    }

    private static double Velocity(double distance)
    {
        var beyond = Math.Abs(distance) - DeadZone;
        return beyond <= 0 ? 0 : Math.Sign(distance) * Math.Min(MaxSpeed, beyond * Speed);
    }

    private static double Distance(Vector v) => Math.Sqrt(v.X * v.X + v.Y * v.Y);

    private void Stop()
    {
        if (!_active)
            return;
        _active = false;
        _middleDown = false;
        _clock.Reset();
        _window.Cursor = _previousCursor;
        if (_marker is not null && OverlayLayer.GetOverlayLayer(_window) is { } layer)
            layer.Children.Remove(_marker);
        _marker = null;
    }

    // Marker at the click point: a disc with an arrow toward each direction that can scroll.
    private void ShowMarker()
    {
        if (OverlayLayer.GetOverlayLayer(_window) is not { } layer)
            return;
        var stroke = Application.Current?.FindResource("TextSecondary") as IBrush ?? Brushes.Gray;
        var fill = Application.Current?.FindResource("SurfaceElevated") as IBrush ?? Brushes.White;
        var border = Application.Current?.FindResource("BorderStrong") as IBrush ?? Brushes.Gray;
        var arrows = new Canvas { Width = 30, Height = 30 };
        void Arrow(string data) => arrows.Children.Add(new Avalonia.Controls.Shapes.Path { Data = Geometry.Parse(data), Fill = stroke });
        if (_vertical is not null)
        {
            Arrow("M15,4 L19,9 L11,9 Z");
            Arrow("M15,26 L19,21 L11,21 Z");
        }
        if (_horizontal is not null)
        {
            Arrow("M4,15 L9,11 L9,19 Z");
            Arrow("M26,15 L21,11 L21,19 Z");
        }
        arrows.Children.Add(new Avalonia.Controls.Shapes.Ellipse { Width = 4, Height = 4, Fill = stroke, [Canvas.LeftProperty] = 13.0, [Canvas.TopProperty] = 13.0 });
        _marker = new Border
        {
            Width = 32,
            Height = 32,
            CornerRadius = new CornerRadius(16),
            Background = fill,
            BorderBrush = border,
            BorderThickness = new Thickness(1),
            Child = arrows,
            IsHitTestVisible = false,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
        };
        Canvas.SetLeft(_marker, _anchor.X - 16);
        Canvas.SetTop(_marker, _anchor.Y - 16);
        layer.Children.Add(_marker);
    }
}
