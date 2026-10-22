using System.Collections.Generic;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Styling;

namespace SysInfo.Services;

/// <summary>
/// Applies the theme and the accent chosen in Settings to the whole application.
/// </summary>
public static class AppearanceService
{
    // Colors that change together with the accent (SwatchPicker guide), plus Fluent's own accent colors.
    private static readonly string[] AccentKeys =
    [
        "AccentColor", "AccentHoverColor", "AccentMutedColor", "AccentSoftColor", "ChartAreaColor", "FocusColor",
        "SystemAccentColor", "SystemAccentColorLight1", "SystemAccentColorLight2", "SystemAccentColorLight3",
        "SystemAccentColorDark1", "SystemAccentColorDark2", "SystemAccentColorDark3",
    ];

    /// <param name="theme">"dark", "light" or "system".</param>
    public static void ApplyTheme(string theme)
    {
        if (Application.Current is not { } app)
            return;

        app.RequestedThemeVariant = theme switch
        {
            "light" => ThemeVariant.Light,
            "system" => ThemeVariant.Default,
            _ => ThemeVariant.Dark,
        };
    }

    /// <summary>
    /// Azur is the design system's own accent: its exact values live in Tokens.axaml and Controls.axaml,
    /// so choosing it removes the override. Other hues derive Hover, Muted, Soft and ChartArea from the
    /// accent with the ratios measured on Azur.
    /// </summary>
    public static void ApplyAccent(string accentId)
    {
        if (Application.Current is not { } app)
            return;

        var option = AccentPalette.Find(accentId);
        var themes = app.Resources.ThemeDictionaries;

        if (option.Id == AccentPalette.DefaultId)
        {
            themes.Remove(ThemeVariant.Dark);
            themes.Remove(ThemeVariant.Light);
            return;
        }

        var darkBackground = Find(app, "BackgroundColor", ThemeVariant.Dark, Color.Parse("#111417"));
        themes[ThemeVariant.Dark] = Build(
            accent: option.Dark,
            hover: Mix(option.Dark, Colors.White, 0.2),
            muted: Mix(darkBackground, option.Dark, 0.16),
            soft: Mix(Colors.Black, option.Dark, 0.7),
            chartAreaAlpha: 0x24);

        themes[ThemeVariant.Light] = Build(
            accent: option.Light,
            hover: Mix(Colors.Black, option.Light, 0.85),
            muted: Mix(Colors.White, option.Light, 0.12),
            soft: Mix(option.Light, Colors.White, 0.3),
            chartAreaAlpha: 0x1a);
    }

    private static ResourceDictionary Build(Color accent, Color hover, Color muted, Color soft, byte chartAreaAlpha)
    {
        var values = new Dictionary<string, Color>
        {
            ["AccentColor"] = accent,
            ["AccentHoverColor"] = hover,
            ["AccentMutedColor"] = muted,
            ["AccentSoftColor"] = soft,
            ["ChartAreaColor"] = Color.FromArgb(chartAreaAlpha, accent.R, accent.G, accent.B),
            ["FocusColor"] = accent,
            ["SystemAccentColor"] = accent,
            ["SystemAccentColorLight1"] = hover,
            ["SystemAccentColorLight2"] = accent,
            ["SystemAccentColorLight3"] = accent,
            ["SystemAccentColorDark1"] = hover,
            ["SystemAccentColorDark2"] = accent,
            ["SystemAccentColorDark3"] = accent,
        };

        var dictionary = new ResourceDictionary();
        foreach (var key in AccentKeys)
            dictionary[key] = values[key];
        return dictionary;
    }

    private static Color Find(Application app, string key, ThemeVariant theme, Color fallback) =>
        app.TryGetResource(key, theme, out var value) && value is Color color ? color : fallback;

    private static Color Mix(Color from, Color to, double amount) => Color.FromRgb(
        (byte)(from.R + (to.R - from.R) * amount + 0.5),
        (byte)(from.G + (to.G - from.G) * amount + 0.5),
        (byte)(from.B + (to.B - from.B) * amount + 0.5));
}
