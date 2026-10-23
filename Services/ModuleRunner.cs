using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Management.Automation;
using System.Threading;
using System.Threading.Tasks;
using SysInfo.Models;

namespace SysInfo.Services;

/// <summary>
/// Runs the functions of one module, in the window as in the MCP server, on three runspaces created on first use:
///   overview   Get-ModuleData (the page's refresh, get_&lt;id&gt;);
///   functions  targeted functions, actions and their previews (Outils card, &lt;id&gt;_&lt;name&gt;);
///   jobs       long tasks (space analysis, antivirus scan…), so that they never delay the other two.
/// Calls on one runspace are serialized; each runspace keeps its own $script: cache.
/// </summary>
public sealed class ModuleRunner(LoadedModule module) : IDisposable
{
    private readonly ConcurrentDictionary<string, Lazy<PowerShellService>> _spaces = new();
    private bool _disposed;

    public LoadedModule Module { get; } = module;

    /// <summary>
    /// Runs Get-ModuleData (<paramref name="function"/> null) or a declared function with bound arguments.
    /// With <paramref name="dryRun"/>, the action gets -DryRun: it returns its preview and changes nothing.
    /// </summary>
    public async Task<(PSObject Data, TimeSpan Duration)> InvokeAsync(
        ModuleFunction? function, IReadOnlyDictionary<string, object?>? arguments = null, bool dryRun = false,
        CancellationToken cancellationToken = default, IActivitySink? sink = null)
    {
        var name = function is null ? "overview" : function.Long && !dryRun ? "jobs" : "functions";
        // Opening a runspace imports the module (~0.5 s): never on the caller's thread.
        var space = await Task.Run(() => Space(name), cancellationToken);

        var parameters = new Dictionary<string, object?>(arguments ?? new Dictionary<string, object?>(), StringComparer.OrdinalIgnoreCase);
        if (dryRun)
            parameters["DryRun"] = true;

        return await space.InvokeTimedAsync(function?.Command ?? "Get-ModuleData", parameters, cancellationToken, function?.Timeout, sink);
    }

    /// <summary>
    /// Null when the function (or the module) may run with the current rights, else why not, in French.
    /// A critical action (level C) always needs administrator rights, except for its preview (dry run).
    /// </summary>
    public string? RightsProblem(ModuleFunction? function, bool dryRun = false) =>
        (Module.Manifest.RequiresAdmin || function?.RequiresAdmin == true || (function?.Level == AccessLevel.C && !dryRun))
        && !Environment.IsPrivilegedProcess
            ? function?.Level == AccessLevel.C
                ? "Action critique : relancez SysInfo en administrateur (sudo -E sous Linux) pour l'utiliser."
                : "Relancez SysInfo en administrateur (root sous Linux) pour utiliser cet outil."
            : null;

    private PowerShellService Space(string name)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _spaces.GetOrAdd(name, _ => new Lazy<PowerShellService>(() => new PowerShellService(Module.ScriptPath))).Value;
    }

    public void Dispose()
    {
        _disposed = true;
        foreach (var space in _spaces.Values)
        {
            if (space.IsValueCreated)
                space.Value.Dispose();
        }
    }
}
