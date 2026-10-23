using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using SysInfo.Models;

namespace SysInfo.Services;

/// <summary>
/// Restore point taken before a critical action (level C), through the Maintenance module's New-SIRestorePoint
/// (Windows: System Restore; Linux: snapper or Timeshift). Without the Maintenance module, or when no restore point
/// is possible (protection off, no snapshot tool), the confirmation window says so and the user decides.
/// </summary>
public static class RestorePoints
{
    private const string ModuleId = "maintenance";
    private const string Command = "New-SIRestorePoint";

    /// <summary>What will happen, for the confirmation window: (Available, Text in French).</summary>
    public static async Task<(bool Available, string Text)> PreviewAsync(CancellationToken cancellationToken)
    {
        if (Find() is not { } module)
            return (false, "Module Maintenance absent : aucun point de restauration ne sera créé.");
        try
        {
            using var service = await Task.Run(() => new PowerShellService(module.ScriptPath), cancellationToken);
            var data = await service.InvokeAsync(Command, new Dictionary<string, object?> { ["DryRun"] = true }, cancellationToken);
            return SectionParser.ParseBlocked(data) is { } blocked
                ? (false, $"Aucun point de restauration possible : {blocked}")
                : (true, SectionParser.ParseSubtitle(data) ?? "Un point de restauration sera créé avant l'action.");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return (false, $"Point de restauration indisponible : {ex.Message}");
        }
    }

    /// <summary>
    /// Creates the restore point before <paramref name="function"/> runs, when it needs one and one is possible.
    /// Returns what was done (for the audit log), or null when nothing was needed. Throws when creating it failed:
    /// the action must then not run.
    /// </summary>
    public static async Task<string?> CreateBeforeAsync(LoadedModule target, ModuleFunction function, CancellationToken cancellationToken)
    {
        if (!function.NeedsRestorePoint || Find() is not { } module)
            return null;

        using var service = await Task.Run(() => new PowerShellService(module.ScriptPath), cancellationToken);
        var description = $"SysInfo : {function.Title ?? function.Name} ({target.Manifest.Title})";
        var preview = await service.InvokeAsync(Command, new Dictionary<string, object?> { ["DryRun"] = true }, cancellationToken);
        if (SectionParser.ParseBlocked(preview) is { } blocked)
            return $"aucun ({blocked})";

        var data = await service.InvokeAsync(Command, new Dictionary<string, object?> { ["Description"] = description }, cancellationToken);
        if (SectionParser.ParseBlocked(data) is { } failed)
            throw new InvalidOperationException($"Point de restauration impossible, action annulée : {failed}");
        return SectionParser.ParseSubtitle(data) ?? "créé";
    }

    private static LoadedModule? Find() =>
        ModuleLoader.Load(ModuleLoader.DefaultModulesDirectory).Modules.FirstOrDefault(m => m.Manifest.Id == ModuleId);
}
