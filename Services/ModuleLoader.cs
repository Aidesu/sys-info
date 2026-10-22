using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using SysInfo.Models;

namespace SysInfo.Services;

public sealed record ModuleLoadResult(IReadOnlyList<LoadedModule> Modules, IReadOnlyList<string> Errors);

/// <summary>
/// Discovers modules in Modules/: one folder per module, containing module.json and &lt;Folder&gt;.psm1.
/// An invalid module is skipped and reported in Errors; it never prevents the others from loading.
/// </summary>
public static partial class ModuleLoader
{
    public static string DefaultModulesDirectory { get; } = Path.Combine(AppContext.BaseDirectory, "Modules");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    [GeneratedRegex("^[a-z0-9_-]+$")]
    private static partial Regex IdPattern();

    public static ModuleLoadResult Load(string modulesDirectory)
    {
        var modules = new List<LoadedModule>();
        var errors = new List<string>();

        if (!Directory.Exists(modulesDirectory))
        {
            errors.Add($"Dossier des modules introuvable : {modulesDirectory}");
            return new ModuleLoadResult(modules, errors);
        }

        var platform = CurrentPlatform();

        foreach (var directory in Directory.EnumerateDirectories(modulesDirectory).Order())
        {
            var folder = Path.GetFileName(directory);
            try
            {
                var module = LoadModule(directory, folder);

                if (modules.Any(m => m.Manifest.Id == module.Manifest.Id))
                    throw new InvalidDataException($"id « {module.Manifest.Id} » déjà utilisé par un autre module");

                if (platform is not null && module.Manifest.Platforms.Contains(platform, StringComparer.OrdinalIgnoreCase))
                    modules.Add(module);
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException or JsonException or UnauthorizedAccessException)
            {
                errors.Add($"{folder} : {ex.Message}");
            }
        }

        return new ModuleLoadResult(
            modules.OrderBy(m => m.Manifest.Order).ThenBy(m => m.Manifest.Id).ToList(),
            errors);
    }

    private static LoadedModule LoadModule(string directory, string folder)
    {
        var manifestPath = Path.Combine(directory, "module.json");
        if (!File.Exists(manifestPath))
            throw new FileNotFoundException("module.json manquant");

        var manifest = JsonSerializer.Deserialize<ModuleManifest>(File.ReadAllText(manifestPath), JsonOptions)
            ?? throw new InvalidDataException("module.json vide");

        if (!IdPattern().IsMatch(manifest.Id))
            throw new InvalidDataException($"id « {manifest.Id} » invalide (minuscules, sans espace)");

        var scriptPath = Path.Combine(directory, $"{folder}.psm1");
        if (!File.Exists(scriptPath))
            throw new FileNotFoundException($"{folder}.psm1 manquant");

        return new LoadedModule(manifest, directory, scriptPath);
    }

    private static string? CurrentPlatform() =>
        OperatingSystem.IsWindows() ? "windows"
        : OperatingSystem.IsLinux() ? "linux"
        : null;
}
