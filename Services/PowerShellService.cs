using System;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Threading.Tasks;

namespace SysInfo.Services;

/// <summary>
/// Runs a module's public functions (Get-ModuleData and declared functions) in a dedicated runspace,
/// reused across refreshes.
/// </summary>
public sealed class PowerShellService : IDisposable
{
    private readonly Runspace _runspace;
    private readonly SemaphoreSlim _lock = new(1, 1);

    static PowerShellService()
    {
        // No PowerShell telemetry from SysInfo (it is on by default in a hosted PowerShell too).
        Environment.SetEnvironmentVariable("POWERSHELL_TELEMETRY_OPTOUT", "1");

        // PowerShell's own modules (Microsoft.PowerShell.Utility: Select-Object…) live in $PSHOME/Modules, $PSHOME being the
        // folder of System.Management.Automation.dll. In a build they ship under runtimes/<os>/lib/net10.0, next to that dll;
        // in a published app the dll sits next to the executable, so $PSHOME/Modules is SysInfo's own Modules folder and the
        // built-in modules are not found. Their folder goes first in PSModulePath (also before Windows PowerShell 5.1's).
        var builtIn = System.IO.Path.Combine(AppContext.BaseDirectory, "runtimes", OperatingSystem.IsWindows() ? "win" : "unix", "lib", "net10.0", "Modules");
        if (!System.IO.Directory.Exists(builtIn))
            return;
        var current = Environment.GetEnvironmentVariable("PSModulePath");
        Environment.SetEnvironmentVariable("PSModulePath",
            string.IsNullOrEmpty(current) ? builtIn : builtIn + System.IO.Path.PathSeparator + current);
    }

    public PowerShellService(string modulePath)
    {
        var state = InitialSessionState.CreateDefault2();
        // ExecutionPolicy only exists on Windows; setting it on Linux throws PlatformNotSupportedException.
        if (OperatingSystem.IsWindows())
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
        state.ImportPSModule(modulePath);
        // Write-Information reaches the Activité page (its default preference would drop it).
        state.Variables.Add(new SessionStateVariableEntry("InformationPreference", ActionPreference.Continue, string.Empty));

        _runspace = RunspaceFactory.CreateRunspace(state);
        _runspace.Open();
    }

    /// <summary>
    /// Runs one public function of the module (Get-ModuleData or a function declared in module.json),
    /// with named parameters (-Top 20…). Calls are serialized: the runspace runs one command at a time.
    /// </summary>
    public async Task<PSObject> InvokeAsync(string command, IReadOnlyDictionary<string, object?>? parameters = null,
        CancellationToken cancellationToken = default, TimeSpan? timeout = null) =>
        (await InvokeTimedAsync(command, parameters, cancellationToken, timeout)).Data;

    /// <summary>The command as it is run, for the live log: « Get-SIProcesses -Top 20 -SortBy cpu ».</summary>
    public static string CommandLine(string command, IReadOnlyDictionary<string, object?>? parameters) =>
        string.Join(' ', new[] { command }.Concat((parameters ?? new Dictionary<string, object?>()).Select(p => p.Value switch
        {
            true => $"-{p.Key}",
            false => $"-{p.Key}:$false",
            string text => $"-{p.Key} '{text.Replace("'", "''")}'",
            var value => $"-{p.Key} {value}",
        })));

    /// <summary>
    /// Same as <see cref="InvokeAsync"/>, with the execution time only (waiting for an earlier call is not counted).
    /// Cancelling, or exceeding <paramref name="timeout"/>, stops the pipeline (native commands included); the runspace
    /// stays usable. Throws <see cref="OperationCanceledException"/> or <see cref="TimeoutException"/>.
    /// </summary>
    public async Task<(PSObject Data, TimeSpan Duration)> InvokeTimedAsync(string command, IReadOnlyDictionary<string, object?>? parameters = null,
        CancellationToken cancellationToken = default, TimeSpan? timeout = null, IActivitySink? sink = null)
    {
        await _lock.WaitAsync(cancellationToken);
        try
        {
            using var timeoutSource = new CancellationTokenSource();
            if (timeout is { } limit)
                timeoutSource.CancelAfter(limit);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);

            using var ps = PowerShell.Create(_runspace);
            ps.AddCommand(command);
            foreach (var (name, value) in parameters ?? new Dictionary<string, object?>())
                ps.AddParameter(name, value);

            if (sink is not null)
            {
                // Live report of the function: its messages and its progress, as they come.
                sink.Log(CommandLine(command, parameters), ActivityLineKind.Command);
                ps.Streams.Information.DataAdded += (_, e) => sink.Log(ps.Streams.Information[e.Index].MessageData?.ToString() ?? string.Empty);
                ps.Streams.Warning.DataAdded += (_, e) => sink.Log(ps.Streams.Warning[e.Index].Message, ActivityLineKind.Warning);
                ps.Streams.Verbose.DataAdded += (_, e) => sink.Log(ps.Streams.Verbose[e.Index].Message);
                ps.Streams.Error.DataAdded += (_, e) => sink.Log(ps.Streams.Error[e.Index].ToString(), ActivityLineKind.Error);
                ps.Streams.Progress.DataAdded += (_, e) =>
                {
                    var record = ps.Streams.Progress[e.Index];
                    if (record.RecordType == ProgressRecordType.Completed)
                        return;
                    var status = string.IsNullOrWhiteSpace(record.StatusDescription) || record.StatusDescription == "Processing"
                        ? record.Activity
                        : $"{record.Activity} · {record.StatusDescription}";
                    sink.Progress(status, record.PercentComplete);
                };
            }

            var watch = System.Diagnostics.Stopwatch.StartNew();
            using var stop = linked.Token.Register(() => ps.BeginStop(null, null));
            try
            {
                var data = await Task.Run(() =>
                {
                    var result = ps.Invoke().FirstOrDefault();
                    if (result is null)
                    {
                        var error = ps.Streams.Error.FirstOrDefault()?.ToString() ?? "Aucune donnée renvoyée";
                        throw new InvalidOperationException(error);
                    }
                    return result;
                });
                return (data, watch.Elapsed);
            }
            catch (Exception) when (linked.IsCancellationRequested)
            {
                cancellationToken.ThrowIfCancellationRequested();
                throw new TimeoutException($"Arrêté après {timeout!.Value.TotalSeconds:0} s (délai dépassé).");
            }
        }
        finally
        {
            _lock.Release();
        }
    }

    public void Dispose()
    {
        _runspace.Dispose();
        _lock.Dispose();
    }
}
