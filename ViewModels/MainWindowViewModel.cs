using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.ViewModels;

public partial class MainWindowViewModel : ViewModelBase, IDisposable
{
    public MainWindowViewModel() : this(new AppSettings()) { }

    public MainWindowViewModel(AppSettings settings)
    {
        var result = ModuleLoader.Load(ModuleLoader.DefaultModulesDirectory);

        // Invalid modules never block the others; they are listed in Settings › About and on stderr.
        foreach (var error in result.Errors)
            Console.Error.WriteLine($"[modules] {error}");

        Tabs = result.Modules.Select(m => new ModuleTabViewModel(m)).ToList();
        Settings = new SettingsViewModel(settings, Tabs.Count, result.Errors, result.Modules);
        Settings.PropertyChanged += OnSettingsChanged;
        // Activité, above Paramètres: what runs now, and the history (audit log).
        Activity = new Activity.ActivityViewModel(result.Modules);
        SysInfo.ViewModels.Activity.ActivityViewModel.Current = Activity;
        FooterPages = [Activity, Settings];

        SelectedTab = Tabs.FirstOrDefault();

        // Every module starts collecting now, not when its page is first opened.
        foreach (var tab in Tabs)
        {
            tab.EcoMode = settings.EcoRefresh;
            tab.Start();
        }
        if (SelectedTab is null)
            SelectedFooterPage = Settings;
    }

    public IReadOnlyList<ModuleTabViewModel> Tabs { get; }

    /// <summary>Entries at the bottom of the sidebar, under a rule (Settings).</summary>
    public IReadOnlyList<NavPageViewModel> FooterPages { get; }

    public SettingsViewModel Settings { get; }

    public Activity.ActivityViewModel Activity { get; }

    public bool HasTabs => Tabs.Count > 0;

    // The two sidebar lists share one selection: picking in one clears the other.
    [ObservableProperty]
    public partial ModuleTabViewModel? SelectedTab { get; set; }

    partial void OnSelectedTabChanged(ModuleTabViewModel? value)
    {
        if (value is not null)
        {
            SelectedFooterPage = null;
            CurrentPage = value;
        }
    }

    [ObservableProperty]
    public partial NavPageViewModel? SelectedFooterPage { get; set; }

    partial void OnSelectedFooterPageChanged(NavPageViewModel? value)
    {
        if (value is not null)
        {
            SelectedTab = null;
            CurrentPage = value;
        }
    }

    /// <summary>The page shown on the right (a module or Settings), rendered through ViewLocator.</summary>
    [ObservableProperty]
    public partial NavPageViewModel? CurrentPage { get; private set; }

    partial void OnCurrentPageChanged(NavPageViewModel? oldValue, NavPageViewModel? newValue)
    {
        if (oldValue is not null)
            oldValue.IsActive = false;
        if (newValue is not null)
            newValue.IsActive = true;
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SidebarToggleLabel))]
    public partial bool IsSidebarCollapsed { get; set; }

    public string SidebarToggleLabel => IsSidebarCollapsed ? "Déplier la barre latérale" : "Replier la barre latérale";

    [RelayCommand]
    private void ToggleSidebar() => IsSidebarCollapsed = !IsSidebarCollapsed;

    /// <summary>False when the OS asks for fewer animations: sidebar and skeletons stay still.</summary>
    public bool AnimationsEnabled { get; } = !MotionPreference.ReduceMotion;

    /// <summary>Set by the window. With the matching setting, modules stop refreshing while minimized.</summary>
    [ObservableProperty]
    public partial bool IsWindowMinimized { get; set; }

    partial void OnIsWindowMinimizedChanged(bool value) => UpdatePause();

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SettingsViewModel.EcoRefresh))
        {
            foreach (var tab in Tabs)
                tab.EcoMode = Settings.EcoRefresh;
        }
        if (e.PropertyName == nameof(SettingsViewModel.PauseWhenMinimized))
            UpdatePause();
    }

    private void UpdatePause()
    {
        var paused = IsWindowMinimized && Settings.PauseWhenMinimized;
        foreach (var tab in Tabs)
            tab.IsPaused = paused;
    }

    /// <summary>Host name · OS, shown under the app name in the sidebar.</summary>
    public string Machine { get; } = $"{Environment.MachineName} · {OsName()}";

    private static string OsName()
    {
        if (OperatingSystem.IsLinux())
        {
            // /etc/os-release: PRETTY_NAME="Fedora Linux 44 (Workstation Edition)"
            try
            {
                var line = File.ReadLines("/etc/os-release").FirstOrDefault(l => l.StartsWith("PRETTY_NAME="));
                if (line is not null)
                    return line["PRETTY_NAME=".Length..].Trim('"');
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return "Linux";
        }

        if (OperatingSystem.IsWindows())
            return Environment.OSVersion.Version.Build >= 22000 ? "Windows 11" : "Windows 10";

        return RuntimeInformation.OSDescription;
    }

    public void Dispose()
    {
        foreach (var tab in Tabs)
            tab.Dispose();
        Activity.Dispose();
    }
}
