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
    }

    // Tells the view model when the window is minimized (Settings › Pause when minimized).
    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);

        if (change.Property == WindowStateProperty && DataContext is MainWindowViewModel vm)
            vm.IsWindowMinimized = WindowState == WindowState.Minimized;
    }
}
