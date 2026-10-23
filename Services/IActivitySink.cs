namespace SysInfo.Services;

/// <summary>
/// Receives what a module function reports while it runs (Activité page): its steps (Write-Information, warnings,
/// verbose messages) and its progress (Write-Progress). Called from the PowerShell thread.
/// </summary>
public interface IActivitySink
{
    /// <summary>One line of the live log.</summary>
    void Log(string text, ActivityLineKind kind = ActivityLineKind.Info);

    /// <summary>Current step and, when known, percent done (-1 = unknown).</summary>
    void Progress(string status, int percent);
}

public enum ActivityLineKind
{
    Command,
    Info,
    Warning,
    Error,
}
