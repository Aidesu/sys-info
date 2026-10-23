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

    public PowerShellService(string modulePath)
    {
        var state = InitialSessionState.CreateDefault2();
        // ExecutionPolicy only exists on Windows; setting it on Linux throws PlatformNotSupportedException.
        if (OperatingSystem.IsWindows())
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
        state.ImportPSModule(modulePath);

        _runspace = RunspaceFactory.CreateRunspace(state);
        _runspace.Open();
    }

    public Task<PSObject> GetModuleDataAsync() => InvokeAsync("Get-ModuleData");

    /// <summary>
    /// Runs one public function of the module (Get-ModuleData or a function declared in module.json),
    /// with named parameters (-Top 20…). Calls are serialized: the runspace runs one command at a time.
    /// </summary>
    public async Task<PSObject> InvokeAsync(string command, IReadOnlyDictionary<string, object?>? parameters = null)
    {
        await _lock.WaitAsync();
        try
        {
            return await Task.Run(() =>
            {
                using var ps = PowerShell.Create(_runspace);
                ps.AddCommand(command);
                foreach (var (name, value) in parameters ?? new Dictionary<string, object?>())
                    ps.AddParameter(name, value);
                var result = ps.Invoke().FirstOrDefault();

                if (result is null)
                {
                    var error = ps.Streams.Error.FirstOrDefault()?.ToString() ?? "Aucune donnée renvoyée";
                    throw new InvalidOperationException(error);
                }

                return result;
            });
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
