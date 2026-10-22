namespace SysInfo.Models;

/// <summary>
/// User settings, saved as JSON (see SettingsService).
/// </summary>
public sealed class AppSettings
{
    /// <summary>"dark", "light" or "system".</summary>
    public string Theme { get; set; } = "dark";

    /// <summary>Accent id from <see cref="SysInfo.Services.AccentPalette"/> ("azur" by default).</summary>
    public string Accent { get; set; } = "azur";

    /// <summary>Stop calling the modules while the window is minimized.</summary>
    public bool PauseWhenMinimized { get; set; } = true;
}
