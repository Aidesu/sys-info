using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.Mcp;

/// <summary>
/// `SysInfo --mcp`: exposes the modules to AI agents over MCP (stdio), without opening a window.
/// One read-only tool per module, get_&lt;id&gt;, generated from ModuleLoader: adding a module adds a tool.
/// The tool calls the same Get-ModuleData as the window and returns its Sections as JSON.
/// stdout carries the protocol only; every log goes to stderr.
/// </summary>
public static class McpServerHost
{
    public static async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        // Same filters as the window: ModuleLoader only returns modules compatible with this OS.
        var result = ModuleLoader.Load(ModuleLoader.DefaultModulesDirectory);
        foreach (var error in result.Errors)
            Console.Error.WriteLine($"[mcp] module ignoré : {error}");

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
                ServerInstructions =
                    "Each get_<module> tool returns live, read-only data about this computer as JSON. " +
                    "Call the tool whose description matches the question; tools take no arguments.",
                ToolCollection = [],
            };

            foreach (var module in result.Modules)
                options.ToolCollection.Add(CreateTool(module, services));

            Console.Error.WriteLine($"[mcp] {options.ToolCollection.Count} outil(s) : " +
                string.Join(", ", result.Modules.Select(m => ToolName(m.Manifest))));

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

    public static string ToolName(ModuleManifest manifest) => $"get_{manifest.Id.Replace('-', '_')}";

    private static McpServerTool CreateTool(LoadedModule module, ConcurrentDictionary<string, PowerShellService> services)
    {
        var manifest = module.Manifest;

        return McpServerTool.Create(
            async (CancellationToken cancellationToken) =>
            {
                // Same rule as the window: an admin module never runs without admin rights.
                if (manifest.RequiresAdmin && !Environment.IsPrivilegedProcess)
                {
                    return Error($"Module '{manifest.Id}' requires administrator rights (root on Linux). " +
                                 "Restart SysInfo --mcp elevated to use this tool.");
                }

                try
                {
                    // One runspace per module, created on first call and reused (PowerShellService serializes calls).
                    var service = services.GetOrAdd(manifest.Id, _ => new PowerShellService(module.ScriptPath));
                    var data = await service.GetModuleDataAsync();
                    var json = PsJson.ToJson(data) as JsonObject ?? new JsonObject();
                    PsJson.NormalizeTables(json);

                    return new CallToolResult
                    {
                        Content = [new TextContentBlock { Text = json.ToJsonString(JsonOptions) }],
                        StructuredContent = JsonSerializer.SerializeToElement(json),
                    };
                }
                catch (Exception ex)
                {
                    // A failing module is a tool error, never a server crash.
                    Console.Error.WriteLine($"[mcp] {ToolName(manifest)} : {ex.Message}");
                    return Error($"Module '{manifest.Id}' failed: {ex.Message}");
                }
            },
            new McpServerToolCreateOptions
            {
                Name = ToolName(manifest),
                Title = manifest.Title,
                Description = Describe(manifest),
                ReadOnly = true,
                Destructive = false,
                Idempotent = true,
                OpenWorld = false,
            });
    }

    // English description from module.json: the module's own description (or its title), then the output format.
    private static string Describe(ModuleManifest manifest)
    {
        var what = string.IsNullOrWhiteSpace(manifest.Description)
            ? $"Returns the '{manifest.Title}' information of this computer (SysInfo module '{manifest.Id}')."
            : manifest.Description.Trim();

        var admin = manifest.RequiresAdmin ? " Requires SysInfo to run with administrator rights." : string.Empty;

        return what + admin +
               " Output: JSON { \"Subtitle\": optional summary, \"Sections\": [...] }. Each section has Title, optional Icon, and Type: " +
               "KeyValue (Items: name → value), Metric (Value, Unit, optional Max, Warning and Critical thresholds, Detail, " +
               "and for two-series metrics Label plus Secondary { Label, Value }) " +
               "Table (Columns, Rows as arrays of values in column order) " +
               "or Usage (Items: Label, Detail, Value out of Max in Unit, optional Warning and Critical, Text). Values are live, read at call time.";
    }

    private static CallToolResult Error(string message) => new()
    {
        IsError = true,
        Content = [new TextContentBlock { Text = message }],
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}
