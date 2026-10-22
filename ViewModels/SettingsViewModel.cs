using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Avalonia;
using Avalonia.Media;
using Avalonia.Styling;
using CommunityToolkit.Mvvm.ComponentModel;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.ViewModels;

/// <summary>
/// Settings page: Appearance (theme, accent), Refresh (pause when minimized), About.
/// Every change is applied at once and saved.
/// </summary>
public partial class SettingsViewModel : NavPageViewModel
{
    private readonly AppSettings _settings;
    private readonly bool _initialized;

    public SettingsViewModel(AppSettings settings, int moduleCount, IReadOnlyList<string> moduleErrors)
    {
        _settings = settings;
        Theme = settings.Theme;
        PauseWhenMinimized = settings.PauseWhenMinimized;
        Accents = AccentPalette.Options.Select(o => new AccentChoice(o)).ToList();
        SelectedAccent = Accents.First(a => a.Option.Id == AccentPalette.Find(settings.Accent).Id);
        ModuleCount = moduleCount;
        ModuleErrors = moduleErrors;
        _initialized = true; // from here on, a change is the user's: apply and save it

        if (Application.Current is { } app)
        {
            app.ActualThemeVariantChanged += (_, _) => UpdateSwatches();
            UpdateSwatches();
        }
    }

    public override string Title => "Paramètres";
    public override string Icon => "settings";

    // Appearance

    /// <summary>"dark", "light" or "system".</summary>
    [ObservableProperty]
    public partial string Theme { get; set; }

    partial void OnThemeChanged(string value)
    {
        if (!_initialized)
            return;
        _settings.Theme = value;
        AppearanceService.ApplyTheme(value);
        SettingsService.Save(_settings);
    }

    public IReadOnlyList<AccentChoice> Accents { get; }

    [ObservableProperty]
    public partial AccentChoice SelectedAccent { get; set; }

    partial void OnSelectedAccentChanged(AccentChoice value)
    {
        if (!_initialized || value is null)
            return;
        _settings.Accent = value.Option.Id;
        AppearanceService.ApplyAccent(value.Option.Id);
        SettingsService.Save(_settings);
    }

    // Refresh

    [ObservableProperty]
    public partial bool PauseWhenMinimized { get; set; }

    partial void OnPauseWhenMinimizedChanged(bool value)
    {
        if (!_initialized)
            return;
        _settings.PauseWhenMinimized = value;
        SettingsService.Save(_settings);
    }

    // About

    public string Version { get; } =
        Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? "inconnue";

    public string Runtime { get; } = $".NET {Environment.Version}";

    public string ModulesDirectory { get; } = ModuleLoader.DefaultModulesDirectory;

    public string SettingsFile { get; } = SettingsService.FilePath;

    public int ModuleCount { get; }

    public string ModuleCountText => ModuleCount switch
    {
        0 => "Aucun module chargé",
        1 => "1 module chargé",
        var n => $"{n} modules chargés",
    };

    /// <summary>Modules skipped at startup (invalid module.json, missing .psm1…).</summary>
    public IReadOnlyList<string> ModuleErrors { get; }

    public bool HasModuleErrors => ModuleErrors.Count > 0;

    // Swatches show the hue of the theme actually displayed.
    private void UpdateSwatches()
    {
        var light = Application.Current?.ActualThemeVariant == ThemeVariant.Light;
        foreach (var accent in Accents)
            accent.Swatch = new SolidColorBrush(light ? accent.Option.Light : accent.Option.Dark);
    }
}

public partial class AccentChoice(AccentOption option) : ObservableObject
{
    public AccentOption Option { get; } = option;

    public string Name => Option.Name;

    [ObservableProperty]
    public partial IBrush? Swatch { get; set; }
}
