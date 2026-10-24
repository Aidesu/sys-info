using Avalonia;
using Avalonia.Controls;
using SysInfo.ViewModels;

namespace SysInfo.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        if (Services.MotionPreference.ReduceMotion)
            PageHost.PageTransition = null;
        // Middle click: auto-scroll, as in a browser.
        Controls.AutoScroll.Attach(this);

        // Sidebar edge: drag to resize (or unfold / fold), double-click for the default width.
        SidebarResizer.DragStarted += (_, _) => (DataContext as MainWindowViewModel)?.BeginSidebarResize();
        SidebarResizer.DragDelta += (_, e) => (DataContext as MainWindowViewModel)?.ResizeSidebar(e.Vector.X);
        SidebarResizer.DragCompleted += (_, _) => (DataContext as MainWindowViewModel)?.EndSidebarResize();
        SidebarResizer.DoubleTapped += (_, _) => (DataContext as MainWindowViewModel)?.ResetSidebarWidth();
    }

    // Tells the view model when the window is minimized (Settings › Pause when minimized).
    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);

        if (change.Property == WindowStateProperty && DataContext is MainWindowViewModel vm)
            vm.IsWindowMinimized = WindowState == WindowState.Minimized;
    }
}
