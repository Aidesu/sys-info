using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.Mcp;

/// <summary>
/// `SysInfo --mcp`: exposes the modules to AI agents over MCP (stdio), without opening a window.
/// Tools are generated from ModuleLoader, so adding a module or a function never touches the C#:
///   get_&lt;id&gt;          the module's overview, same Get-ModuleData as its page in the window;
///   &lt;id&gt;_&lt;function&gt;  each function declared in module.json with level L (read only), A or C (actions confirmed
///                    by the user in a SysInfo window; C also needs elevation and a restore point), as allowed in Settings;
///   job_status, job_cancel  long tasks.
/// Functions of level X are never exposed. Every call is written to the audit log.
/// stdout carries the protocol only; every log goes to stderr.
/// </summary>
public static class McpServerHost
{
    public static async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        // Same filters as the window: ModuleLoader only returns modules and functions compatible with this OS.
        var result = ModuleLoader.Load(ModuleLoader.DefaultModulesDirectory);
        foreach (var error in result.Errors)
            Console.Error.WriteLine($"[mcp] ignoré : {error}");

        var settings = SettingsService.Load();
        AuditLog.Purge(settings.AuditRetentionDays);

        var runners = result.Modules.Select(m => new ModuleRunner(m)).ToList();
        var jobs = new JobManager();
        try
        {
            var options = new McpServerOptions
            {
                ServerInfo = new Implementation
                {
                    Name = "sysinfo",
                    Title = "SysInfo",
                    Version = Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "1.0.0",
                    Description = "System information (CPU, memory, disks, network, processes, security, software…) from the " +
                                  "SysInfo modules, and simple actions confirmed by the user in SysInfo.",
                },
                ServerInstructions = McpDescriptions.ServerInstructions,
                ToolCollection = [],
            };

            foreach (var tool in CreateTools(runners, jobs, settings))
                options.ToolCollection.Add(tool);
            options.ToolCollection.Add(JobTool.Status(jobs));
            options.ToolCollection.Add(JobTool.Cancel(jobs));

            Console.Error.WriteLine($"[mcp] {options.ToolCollection.Count} outil(s) : " +
                string.Join(", ", options.ToolCollection.Select(t => t.ProtocolTool.Name)));

            await using var transport = new StdioServerTransport("sysinfo");
            await using var server = McpServer.Create(transport, options);
            await server.RunAsync(cancellationToken);
            return 0;
        }
        catch (OperationCanceledException)
        {
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[mcp] arrêt sur erreur : {ex}");
            return 1;
        }
        finally
        {
            foreach (var job in jobs.All)
                job.Cancel();
            foreach (var runner in runners)
                runner.Dispose();
        }
    }

    private static IEnumerable<ModuleTool> CreateTools(IReadOnlyList<ModuleRunner> runners, JobManager jobs, AppSettings settings)
    {
        var actions = settings.McpActions;
        var names = new HashSet<string>(["job_status", "job_cancel"]);
        foreach (var runner in runners)
        {
            var manifest = runner.Module.Manifest;
            var tools = runner.Module.Functions
                .Where(f =>
                {
                    var name = ModuleTool.FunctionName(manifest, f);
                    var reason = f.Level switch
                    {
                        AccessLevel.X => "niveau X",
                        AccessLevel.A when !settings.McpActions => "actions désactivées dans les Paramètres",
                        AccessLevel.C when !settings.McpCriticalActions => "actions critiques désactivées dans les Paramètres",
                        _ when f.IsAction && settings.McpDisabledTools.Contains(name) => "désactivé dans la liste blanche",
                        _ => null,
                    };
                    if (reason is null)
                        return true;
                    Console.Error.WriteLine($"[mcp] {name} non exposé ({reason})");
                    return false;
                })
                .Select(f => ModuleTool.ForFunction(runner, f, jobs))
                .Prepend(ModuleTool.Overview(runner, jobs, actions));

            foreach (var tool in tools)
            {
                // Two modules can produce the same name (ex. id "a" + function "b_c" vs id "a_b" + "c").
                if (names.Add(tool.ProtocolTool.Name))
                    yield return tool;
                else
                    Console.Error.WriteLine($"[mcp] {tool.ProtocolTool.Name} ignoré : nom déjà utilisé");
            }
        }
    }
}
