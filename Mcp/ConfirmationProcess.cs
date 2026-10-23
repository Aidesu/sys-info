using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.Mcp;

public enum ConfirmationResult
{
    Confirmed,
    Declined,
    TimedOut,
    Unavailable,
}

/// <summary>
/// Asks the user to confirm an action requested over MCP. The server has no window: it starts
/// `SysInfo --confirm &lt;request.json&gt;`, a small SysInfo window that computes the preview (-DryRun) itself, shows it
/// with the parameters and who asks, and answers on its stdout (confirmed, declined or timeout) before exiting.
/// Works whether the main window is open or not; needs a graphical session.
/// </summary>
public static class ConfirmationProcess
{
    /// <summary>Without an answer, the window declines by itself after this delay.</summary>
    public const int TimeoutSeconds = 120;

    public static string RequestsDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SysInfo", "requests");

    public static async Task<(ConfirmationResult Result, string? Detail)> RequestAsync(
        LoadedModule module, ModuleFunction function, IReadOnlyDictionary<string, object?> arguments, string? client,
        CancellationToken cancellationToken)
    {
        if (OperatingSystem.IsLinux()
            && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DISPLAY"))
            && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WAYLAND_DISPLAY")))
        {
            return (ConfirmationResult.Unavailable, "no graphical session (DISPLAY / WAYLAND_DISPLAY not set): " +
                "actions are confirmed in a SysInfo window, so the MCP server must run in the user's desktop session" +
                (Environment.IsPrivilegedProcess
                    ? "; under sudo, keep the display with sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XAUTHORITY,XDG_RUNTIME_DIR"
                    : string.Empty));
        }

        var path = Path.Combine(RequestsDirectory, $"{Guid.NewGuid():N}.json");
        try
        {
            Directory.CreateDirectory(RequestsDirectory);
            var request = new JsonObject
            {
                ["module"] = module.Manifest.Id,
                ["function"] = function.Name,
                ["parameters"] = FunctionArguments.ToJson(arguments),
                ["client"] = client,
                ["timeoutSeconds"] = TimeoutSeconds,
            };
            await File.WriteAllTextAsync(path, request.ToJsonString(), cancellationToken);
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);

            var start = new ProcessStartInfo(Environment.ProcessPath ?? "SysInfo")
            {
                UseShellExecute = false,
                // stdout and stdin of this process are the MCP channel: the window must never touch them.
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            // `dotnet SysInfo.dll --mcp`: the process is dotnet, the app is the entry assembly.
            if (Path.GetFileNameWithoutExtension(start.FileName).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                start.ArgumentList.Add(Assembly.GetEntryAssembly()!.Location);
            start.ArgumentList.Add("--confirm");
            start.ArgumentList.Add(path);

            using var process = Process.Start(start)
                ?? throw new InvalidOperationException("the confirmation window could not be started");
            process.StandardInput.Close();
            process.ErrorDataReceived += (_, e) => { if (e.Data is not null) Console.Error.WriteLine($"[confirm] {e.Data}"); };
            process.BeginErrorReadLine();
            var output = process.StandardOutput.ReadToEndAsync(CancellationToken.None);

            // The window declines by itself at TimeoutSeconds; past a margin, it is considered stuck.
            using var stuck = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            stuck.CancelAfter(TimeSpan.FromSeconds(TimeoutSeconds + 30));
            try
            {
                await process.WaitForExitAsync(stuck.Token);
            }
            catch (OperationCanceledException)
            {
                process.Kill(entireProcessTree: true);
                cancellationToken.ThrowIfCancellationRequested();
                return (ConfirmationResult.TimedOut, null);
            }

            var answer = (await output).Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).LastOrDefault();
            return answer switch
            {
                "confirmed" when process.ExitCode == 0 => (ConfirmationResult.Confirmed, null),
                "declined" => (ConfirmationResult.Declined, null),
                "timeout" => (ConfirmationResult.TimedOut, null),
                _ => (ConfirmationResult.Unavailable, $"the confirmation window failed (exit code {process.ExitCode})"),
            };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException
                                       or System.ComponentModel.Win32Exception)
        {
            return (ConfirmationResult.Unavailable, ex.Message);
        }
        finally
        {
            try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
