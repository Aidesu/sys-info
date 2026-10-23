using System.Collections.Generic;

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

    /// <summary>Hidden pages refresh less often (5 × their rhythm, at most a minute).</summary>
    public bool EcoRefresh { get; set; } = true;

    /// <summary>
    /// Expose the actions (level A) to AI agents over MCP. Each one is still confirmed in a SysInfo window and logged.
    /// Read when `SysInfo --mcp` starts.
    /// </summary>
    public bool McpActions { get; set; } = true;

    /// <summary>
    /// Expose the critical actions (level C) to AI agents over MCP. Off by default: each one also needs SysInfo --mcp to
    /// run elevated, a restore point and a confirmation.
    /// </summary>
    public bool McpCriticalActions { get; set; }

    /// <summary>MCP whitelist: action tools (&lt;id&gt;_&lt;name&gt;) never exposed, whatever their level.</summary>
    public List<string> McpDisabledTools { get; set; } = [];

    /// <summary>Column layout of the tables, by table (see TableLayouts).</summary>
    public Dictionary<string, TableLayout> TableLayouts { get; set; } = [];

    /// <summary>Audit log files older than this many days are deleted (0 = keep everything).</summary>
    public int AuditRetentionDays { get; set; } = 365;
}

/// <summary>Column widths (pixels, by column label) and hidden columns of one table.</summary>
public sealed class TableLayout
{
    public Dictionary<string, double> Widths { get; set; } = [];
    public List<string> Hidden { get; set; } = [];
}
