using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace SysInfo.Services;

/// <summary>
/// Whether the OS asks for fewer animations. Read once at startup.
/// Windows: SystemParametersInfo(SPI_GETCLIENTAREAANIMATION).
/// Linux: GNOME enable-animations (gsettings), then KDE AnimationDurationFactor (~/.config/kdeglobals).
/// </summary>
public static class MotionPreference
{
    public static bool ReduceMotion { get; } = Detect();

    private static bool Detect()
    {
        try
        {
            if (OperatingSystem.IsWindows())
                return SystemParametersInfo(SpiGetClientAreaAnimation, 0, out var enabled, 0) && !enabled;

            if (OperatingSystem.IsLinux())
                return GnomeAnimationsDisabled() ?? KdeAnimationsDisabled() ?? false;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[motion] préférence d'animation illisible : {ex.Message}");
        }
        return false;
    }

    private static bool? GnomeAnimationsDisabled()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo("gsettings", "get org.gnome.desktop.interface enable-animations")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            });
            if (process is null || !process.WaitForExit(1000) || process.ExitCode != 0)
                return null;
            return process.StandardOutput.ReadToEnd().Trim() == "false";
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null; // gsettings not installed (non-GNOME desktop)
        }
    }

    private static bool? KdeAnimationsDisabled()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "kdeglobals");
        if (!File.Exists(path))
            return null;

        foreach (var line in File.ReadLines(path))
        {
            if (line.StartsWith("AnimationDurationFactor=", StringComparison.Ordinal))
                return line["AnimationDurationFactor=".Length..].Trim() is "0" or "0.0";
        }
        return null;
    }

    private const uint SpiGetClientAreaAnimation = 0x1042;

    // DllImport (not LibraryImport) so that the project does not need AllowUnsafeBlocks.
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
    private static extern bool SystemParametersInfo(uint action, uint param, out bool value, uint winIni);
}
