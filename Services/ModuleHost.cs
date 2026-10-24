using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Threading;
using System.Threading.Tasks;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.Host;

/// <summary>
/// Lets an aggregating module (Inventaire, Rapports, Diagnostic guidé) read the other modules from PowerShell
/// (helper of the host, §4.6): [SysInfo.Host.ModuleHost]::Invoke('storage', $null, $null, 60) returns what get_storage
/// returns, through the same <see cref="ModuleRunner"/> as the window or the MCP server (same runspaces, same cache).
/// Reads only: a level A, C or X function is refused. A recent overview of the page is reused instead of collected
/// again. Without SysInfo (module tested alone in pwsh) the type is absent and the module imports the others itself.
/// </summary>
public static class ModuleHost
{
    private static readonly ConcurrentDictionary<string, ModuleRunner> Runners = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Called for each module by the window and the MCP server.</summary>
    public static void Register(ModuleRunner runner) => Runners[runner.Module.Manifest.Id] = runner;

    public static bool IsAvailable => !Runners.IsEmpty;

    /// <summary>Loaded modules (compatible with this OS), in sidebar order, with their read functions.</summary>
    public static ModuleSummary[] List() =>
        [.. Runners.Values
            .OrderBy(r => r.Module.Manifest.Order)
            .Select(r => new ModuleSummary(
                r.Module.Manifest.Id, r.Module.Manifest.Title, r.Module.Manifest.RefreshSeconds,
                [.. r.Module.Functions.Where(f => f.Level == AccessLevel.L).Select(f => f.Name)]))];

    /// <summary>
    /// Overview (<paramref name="function"/> null or empty) or read function of a module. An overview younger than
    /// <paramref name="maxAgeSeconds"/> (0 = six times the refresh interval, at least 60 s) is reused.
    /// Throws with a French message: unknown module or function, not a read, rights, timeout, module error.
    /// </summary>
    public static PSObject Invoke(string caller, string module, string? function, IDictionary? parameters, int timeoutSeconds = 60, int maxAgeSeconds = 0) =>
        InvokeAsync(caller, module, function, parameters, timeoutSeconds, maxAgeSeconds).GetAwaiter().GetResult();

    /// <summary>
    /// Several calls at once (in parallel, one per module at most at a time on each runspace): each request is a hashtable
    /// @{ Module = 'storage'; Function = 'analyze_space'; Parameters = @{ … } }. The results are in the same order:
    /// @{ Module; Function; Data; Error; DurationMs }, Data null when Error is set.
    /// </summary>
    public static PSObject[] InvokeMany(string caller, object[] requests, int timeoutSeconds = 60, int maxAgeSeconds = 0)
    {
        var tasks = requests.Select(async raw =>
        {
            var request = (raw is PSObject ps ? ps.BaseObject : raw) as IDictionary ?? new Hashtable();
            var module = request["Module"]?.ToString() ?? string.Empty;
            var function = request["Function"]?.ToString();
            var started = DateTime.UtcNow;
            var result = new Hashtable { ["Module"] = module, ["Function"] = function };
            try
            {
                result["Data"] = await InvokeAsync(caller, module, function, Unwrap(request["Parameters"]) as IDictionary, timeoutSeconds, maxAgeSeconds);
            }
            catch (Exception ex)
            {
                result["Error"] = (ex as AggregateException)?.InnerException?.Message ?? ex.Message;
            }
            result["DurationMs"] = Math.Round((DateTime.UtcNow - started).TotalMilliseconds);
            return PSObject.AsPSObject(result);
        });
        return Task.WhenAll(tasks).GetAwaiter().GetResult();
    }

    private static async Task<PSObject> InvokeAsync(string caller, string moduleId, string? functionName, IDictionary? parameters, int timeoutSeconds, int maxAgeSeconds)
    {
        if (string.Equals(caller, moduleId, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Le module {caller} ne peut pas s'appeler lui-même.");
        if (!Runners.TryGetValue(moduleId, out var runner))
            throw new InvalidOperationException($"Module inconnu ou indisponible sur ce système : {moduleId}.");

        ModuleFunction? function = null;
        if (!string.IsNullOrEmpty(functionName))
        {
            function = runner.Module.Functions.FirstOrDefault(f => string.Equals(f.Name, functionName, StringComparison.OrdinalIgnoreCase))
                ?? throw new InvalidOperationException($"Fonction inconnue : {moduleId}_{functionName}.");
            if (function.Level != AccessLevel.L)
                throw new InvalidOperationException($"{moduleId}_{functionName} n'est pas une lecture : le module {caller} ne peut pas la lancer.");
        }
        if (runner.RightsProblem(function) is { } rights)
            throw new InvalidOperationException($"{moduleId} : {rights}");

        if (function is null)
        {
            // A hidden page refreshes up to 5 times less often (eco mode): its last overview still counts.
            var maxAge = maxAgeSeconds > 0 ? maxAgeSeconds : Math.Max(60, 6 * runner.Module.Manifest.RefreshSeconds);
            if (runner.LastOverview is { } last && DateTime.UtcNow - last.At < TimeSpan.FromSeconds(maxAge))
                return last.Data;
        }

        var arguments = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        if (parameters is not null)
        {
            foreach (DictionaryEntry entry in parameters)
                arguments[entry.Key.ToString()!] = Unwrap(entry.Value);
        }
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 1, 3600)));
        try
        {
            var (data, _) = await runner.InvokeAsync(function, arguments, cancellationToken: timeout.Token);
            return data;
        }
        catch (OperationCanceledException)
        {
            throw new TimeoutException($"{moduleId}{(function is null ? string.Empty : "_" + function.Name)} n'a pas répondu en {timeoutSeconds} s.");
        }
    }

    private static object? Unwrap(object? value) => value is PSObject { BaseObject: not PSCustomObject } ps ? ps.BaseObject : value;
}

/// <summary>A module as seen by <see cref="ModuleHost.List"/>.</summary>
public sealed record ModuleSummary(string Id, string Title, int RefreshSeconds, string[] Functions);
