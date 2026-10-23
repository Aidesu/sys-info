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
                    modules.Add(module with { Functions = LoadFunctions(module, platform, folder, errors) });
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

    // An invalid function is skipped and reported; the module and its other functions still load.
    private static List<ModuleFunction> LoadFunctions(LoadedModule module, string platform, string folder, List<string> errors)
    {
        var functions = new List<ModuleFunction>();
        var script = File.ReadAllText(module.ScriptPath);

        foreach (var function in module.Manifest.Functions)
        {
            var problem = ValidateFunction(function, script, functions);
            if (problem is not null)
            {
                errors.Add($"{folder} › {function.Name} : {problem}");
                continue;
            }

            var platforms = function.Platforms.Count > 0 ? function.Platforms : module.Manifest.Platforms;
            if (platforms.Contains(platform, StringComparer.OrdinalIgnoreCase))
                functions.Add(function);
        }

        return functions;
    }

    private static string? ValidateFunction(ModuleFunction function, string script, List<ModuleFunction> previous)
    {
        if (!FunctionNamePattern().IsMatch(function.Name))
            return "nom invalide (snake_case : minuscules, chiffres, _)";
        if (previous.Any(f => f.Name == function.Name))
            return "nom déjà utilisé dans ce module";
        if (string.IsNullOrWhiteSpace(function.Description))
            return "description manquante";
        if (!Regex.IsMatch(script, $@"(?im)^\s*function\s+{Regex.Escape(function.Command)}\b"))
            return $"fonction {function.Command} absente du .psm1";

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var parameter in function.Parameters)
        {
            if (!ParameterNamePattern().IsMatch(parameter.Name))
                return $"paramètre « {parameter.Name} » invalide (camelCase)";
            if (!names.Add(parameter.Name))
                return $"paramètre « {parameter.Name} » en double";
            if (parameter.Enum.Count > 0 && parameter.Type != ParameterType.String)
                return $"paramètre « {parameter.Name} » : enum réservé au type string";
        }

        return null;
    }

    [GeneratedRegex("^[a-z][a-z0-9_]*$")]
    private static partial Regex FunctionNamePattern();

    [GeneratedRegex("^[a-z][A-Za-z0-9]*$")]
    private static partial Regex ParameterNamePattern();

    private static string? CurrentPlatform() =>
        OperatingSystem.IsWindows() ? "windows"
        : OperatingSystem.IsLinux() ? "linux"
        : null;
}
