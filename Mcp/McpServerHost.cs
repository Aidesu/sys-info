using System;
using System.Collections.Concurrent;
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
///   &lt;id&gt;_&lt;function&gt;  each function declared in module.json with level L (read only).
/// Functions of level A, C or X are not exposed (actions wait for the confirmation and audit framework, sprint S4).
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

        var services = new ConcurrentDictionary<string, PowerShellService>();
        try
        {
            var options = new McpServerOptions
            {
                ServerInfo = new Implementation
                {
                    Name = "sysinfo",
                    Title = "SysInfo",
                    Version = Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "1.0.0",
                    Description = "Read-only system information (CPU, memory, disks, network, processes…) from the SysInfo modules.",
                },
                ServerInstructions = McpDescriptions.ServerInstructions,
                ToolCollection = [],
            };

            foreach (var tool in CreateTools(result.Modules, services))
                options.ToolCollection.Add(tool);

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
            foreach (var service in services.Values)
                service.Dispose();
        }
    }

    private static IEnumerable<ModuleTool> CreateTools(
        IReadOnlyList<LoadedModule> modules, ConcurrentDictionary<string, PowerShellService> services)
    {
        var names = new HashSet<string>();
        foreach (var module in modules)
        {
            var tools = module.Functions
                .Where(f =>
                {
                    if (f.Level == AccessLevel.L)
                        return true;
                    Console.Error.WriteLine($"[mcp] {ModuleTool.FunctionName(module.Manifest, f)} non exposé (niveau {f.Level})");
                    return false;
                })
                .Select(f => ModuleTool.ForFunction(module, f, services))
                .Prepend(ModuleTool.Overview(module, services));

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
