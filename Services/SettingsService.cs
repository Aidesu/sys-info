using System;
using System.IO;
using System.Text.Json;
using SysInfo.Models;

namespace SysInfo.Services;

/// <summary>
/// Loads and saves <see cref="AppSettings"/> in the user's config folder:
/// %APPDATA%\SysInfo\settings.json on Windows, ~/.config/SysInfo/settings.json on Linux.
/// A missing or unreadable file gives the defaults; it never prevents the app from starting.
/// </summary>
public static class SettingsService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    public static string FilePath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SysInfo", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), JsonOptions) ?? new AppSettings();
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"[settings] {FilePath} illisible, valeurs par défaut : {ex.Message}");
        }
        return new AppSettings();
    }

    public static void Save(AppSettings settings)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(settings, JsonOptions));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"[settings] impossible d'enregistrer {FilePath} : {ex.Message}");
        }
    }
}
