using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using SysInfo.Services;
using SysInfo.ViewModels;
using SysInfo.Views;

namespace SysInfo;

public partial class App : Application
{
    /// <summary>Set by `SysInfo --confirm &lt;request.json&gt;`: the app only shows that confirmation window.</summary>
    public static string? ConfirmRequestPath { get; set; }

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // Saved theme and accent, applied before the window opens.
            var settings = SettingsService.Load();
            AppearanceService.ApplyTheme(settings.Theme);
            AppearanceService.ApplyAccent(settings.Accent);

            if (ConfirmRequestPath is not null)
            {
                ConfirmLauncher.Start(desktop, ConfirmRequestPath);
                base.OnFrameworkInitializationCompleted();
                return;
            }

            AuditLog.Purge(settings.AuditRetentionDays);
            TableLayouts.Use(settings);

            var viewModel = new MainWindowViewModel(settings);
            desktop.MainWindow = new MainWindow
            {
                DataContext = viewModel,
            };
            // Closes every module's PowerShell runspace.
            desktop.Exit += (_, _) => viewModel.Dispose();
        }

        base.OnFrameworkInitializationCompleted();
    }
}