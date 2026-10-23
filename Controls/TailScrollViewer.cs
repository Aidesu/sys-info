using System;
using Avalonia;
using Avalonia.Controls;

namespace SysInfo.Controls;

/// <summary>
/// Scroll viewer of a live log: it follows the new lines (stays at the bottom) as long as the user has not scrolled
/// up; scrolling back to the bottom resumes following.
/// </summary>
public sealed class TailScrollViewer : ScrollViewer
{
    private bool _follow = true;

    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == ExtentProperty && _follow)
            ScrollToEnd();
        else if (change.Property == OffsetProperty)
            _follow = Offset.Y >= Extent.Height - Viewport.Height - 4;
    }
}
