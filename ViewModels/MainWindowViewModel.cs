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
        _settings = settings;
        SidebarWidth = Math.Clamp(settings.SidebarWidth, SidebarMinWidth, SidebarMaxWidth);
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

    private readonly AppSettings _settings;

    /// <summary>Folded (icons only) at startup; unfolded by its button or by dragging its edge.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SidebarToggleLabel), nameof(SidebarCurrentWidth))]
    public partial bool IsSidebarCollapsed { get; set; } = true;

    public string SidebarToggleLabel => IsSidebarCollapsed ? "Déplier la barre latérale" : "Replier la barre latérale";

    [RelayCommand]
    private void ToggleSidebar() => IsSidebarCollapsed = !IsSidebarCollapsed;

    public const double SidebarCollapsedWidth = 56;   // = SidebarWidthCollapsed (Tokens.axaml)
    public const double SidebarDefaultWidth = 216;    // = SidebarWidth
    private const double SidebarMinWidth = 168;
    private const double SidebarMaxWidth = 420;

    /// <summary>Width of the unfolded sidebar, chosen by dragging its right edge; kept in settings.json.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SidebarCurrentWidth))]
    public partial double SidebarWidth { get; private set; } = SidebarDefaultWidth;

    public double SidebarCurrentWidth => IsSidebarCollapsed ? SidebarCollapsedWidth : SidebarWidth;

    /// <summary>While the edge is dragged, the width follows the pointer without animation.</summary>
    [ObservableProperty]
    public partial bool IsSidebarResizing { get; private set; }

    private double _dragWidth;

    /// <summary>Only the unfolded sidebar can be resized (the folded one keeps its icon width).</summary>
    public void BeginSidebarResize()
    {
        if (IsSidebarCollapsed)
            return;
        IsSidebarResizing = true;
        _dragWidth = SidebarWidth;
    }

    /// <summary>Follows the pointer, between the minimum and maximum widths; never folds or unfolds the sidebar.</summary>
    public void ResizeSidebar(double delta)
    {
        if (!IsSidebarResizing)
            return;
        _dragWidth += delta;
        SidebarWidth = Math.Clamp(_dragWidth, SidebarMinWidth, SidebarMaxWidth);
    }

    public void EndSidebarResize()
    {
        if (!IsSidebarResizing)
            return;
        IsSidebarResizing = false;
        SaveSidebarWidth();
    }

    /// <summary>Double-click on the edge of the unfolded sidebar: back to the default width.</summary>
    public void ResetSidebarWidth()
    {
        if (IsSidebarCollapsed)
            return;
        SidebarWidth = SidebarDefaultWidth;
        SaveSidebarWidth();
    }

    private void SaveSidebarWidth()
    {
        if (Math.Abs(_settings.SidebarWidth - SidebarWidth) < 0.5)
            return;
        _settings.SidebarWidth = Math.Round(SidebarWidth);
        SettingsService.Save(_settings);
    }

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
