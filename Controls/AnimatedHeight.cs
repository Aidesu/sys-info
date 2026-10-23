using System;
using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using SysInfo.Services;

namespace SysInfo.Controls;

/// <summary>
/// Container whose height follows its content smoothly: when the content grows or shrinks (a finding appears, a
/// table gets more rows, « Voir plus » is clicked), the height glides to the new value and the content below moves
/// with it instead of jumping. <see cref="IsCollapsed"/> folds it to zero with a fade, then hides it (no gap left in
/// a StackPanel); <see cref="AnimateOnLoad"/> makes it unfold from zero the first time it is shown.
/// A width change (window resized) applies at once. With the OS asking for fewer animations, everything is instant.
/// </summary>
public sealed class AnimatedHeight : Decorator
{
    public static readonly StyledProperty<bool> IsCollapsedProperty =
        AvaloniaProperty.Register<AnimatedHeight, bool>(nameof(IsCollapsed));

    public static readonly StyledProperty<bool> AnimateOnLoadProperty =
        AvaloniaProperty.Register<AnimatedHeight, bool>(nameof(AnimateOnLoad));

    public static readonly StyledProperty<TimeSpan> DurationProperty =
        AvaloniaProperty.Register<AnimatedHeight, TimeSpan>(nameof(Duration), TimeSpan.FromMilliseconds(240));

    private readonly Stopwatch _clock = new();
    private double _current;          // height shown now
    private double _from;             // height when the running animation started
    private double _target = double.NaN;
    private double _width = double.NaN;
    private bool _fade;               // the running animation also fades the content (fold / unfold)
    private bool _fadeIn;
    private bool _framePending;

    static AnimatedHeight()
    {
        ClipToBoundsProperty.OverrideDefaultValue<AnimatedHeight>(true);
        AffectsMeasure<AnimatedHeight>(IsCollapsedProperty);
    }

    public AnimatedHeight()
    {
        // Folded from the start: nothing to show, nothing to measure.
        PropertyChanged += (_, e) =>
        {
            if (e.Property == IsCollapsedProperty && !IsCollapsed)
                IsVisible = true;
        };
    }

    public bool IsCollapsed { get => GetValue(IsCollapsedProperty); set => SetValue(IsCollapsedProperty, value); }

    public bool AnimateOnLoad { get => GetValue(AnimateOnLoadProperty); set => SetValue(AnimateOnLoadProperty, value); }

    public TimeSpan Duration { get => GetValue(DurationProperty); set => SetValue(DurationProperty, value); }

    private static bool Animated => !MotionPreference.ReduceMotion;

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        // A container recycled or re-attached starts from its current state, without replaying; one that starts
        // folded unfolds with an animation when it opens.
        _width = double.NaN;
        if (IsCollapsed && !AnimateOnLoad)
        {
            _target = 0;
            _current = 0;
            IsVisible = false;
        }
        else
        {
            _target = double.NaN;
        }
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Child is not { } child)
            return default;

        child.Measure(new Size(availableSize.Width, double.PositiveInfinity));
        var target = IsCollapsed ? 0 : child.DesiredSize.Height;

        if (double.IsNaN(_target))
        {
            // First layout: shown as is, or unfolded from zero for content that just appeared.
            _target = target;
            if (AnimateOnLoad && Animated && target > 0)
                Start(0, target, fade: true, fadeIn: true);
            else
                Snap(target);
        }
        else if (!target.Equals(_target))
        {
            var widthChanged = !availableSize.Width.Equals(_width);
            var folding = target == 0 || _target == 0;
            _target = target;
            if (!Animated || (widthChanged && !folding))
                Snap(target);
            else
                Start(_current, target, fade: folding, fadeIn: target > 0);
        }

        _width = availableSize.Width;
        return new Size(child.DesiredSize.Width, _current);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        // The content keeps its full height and is clipped: it slides instead of being squeezed.
        Child?.Arrange(new Rect(0, 0, finalSize.Width, Math.Max(finalSize.Height, Child.DesiredSize.Height)));
        return finalSize;
    }

    private void Snap(double height)
    {
        _clock.Reset();
        _current = height;
        if (Child is { } child)
            child.Opacity = 1;
        if (IsCollapsed && height == 0)
            IsVisible = false;
    }

    private void Start(double from, double to, bool fade, bool fadeIn)
    {
        _from = from;
        _current = from;
        _fade = fade;
        _fadeIn = fadeIn;
        _clock.Restart();
        if (fade && Child is { } child)
            child.Opacity = fadeIn ? 0 : 1;
        RequestFrame();
    }

    private void RequestFrame()
    {
        if (_framePending || TopLevel.GetTopLevel(this) is not { } top)
            return;
        _framePending = true;
        top.RequestAnimationFrame(_ => OnFrame());
    }

    private void OnFrame()
    {
        _framePending = false;
        if (!_clock.IsRunning)
            return;

        var t = Math.Clamp(_clock.Elapsed.TotalMilliseconds / Math.Max(1, Duration.TotalMilliseconds), 0, 1);
        var eased = 1 - Math.Pow(1 - t, 3); // cubic ease-out: fast start, soft landing
        _current = _from + (_target - _from) * eased;
        if (_fade && Child is { } child)
            child.Opacity = _fadeIn ? eased : 1 - eased;

        InvalidateMeasure();
        if (t < 1)
            RequestFrame();
        else
            Snap(_target);
    }
}
