using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
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
/// One MCP tool backed by one PowerShell function of a module: get_&lt;id&gt; (Get-ModuleData, the tab's overview)
/// or &lt;id&gt;_&lt;name&gt; (a function declared in module.json, with parameters). The input schema is built from
/// module.json, arguments are checked here, then passed as named parameters to the same runspace as the module's
/// other tools. The result is the standard envelope (see <see cref="Envelope"/>).
/// </summary>
public sealed class ModuleTool : McpServerTool
{
    private readonly LoadedModule _module;
    private readonly ModuleFunction? _function;
    private readonly ConcurrentDictionary<string, PowerShellService> _services;

    private ModuleTool(LoadedModule module, ModuleFunction? function, ConcurrentDictionary<string, PowerShellService> services)
    {
        _module = module;
        _function = function;
        _services = services;

        ProtocolTool = new Tool
        {
            Name = function is null ? OverviewName(module.Manifest) : FunctionName(module.Manifest, function),
            Title = function is null ? module.Manifest.Title : $"{module.Manifest.Title} · {function.Name}",
            Description = function is null ? McpDescriptions.Overview(module) : McpDescriptions.Function(module.Manifest, function),
            InputSchema = BuildInputSchema(function?.Parameters ?? []),
            Annotations = new ToolAnnotations
            {
                Title = module.Manifest.Title,
                ReadOnlyHint = true,
                DestructiveHint = false,
                IdempotentHint = true,
                OpenWorldHint = false,
            },
        };
    }

    public static ModuleTool Overview(LoadedModule module, ConcurrentDictionary<string, PowerShellService> services) =>
        new(module, null, services);

    public static ModuleTool ForFunction(LoadedModule module, ModuleFunction function, ConcurrentDictionary<string, PowerShellService> services) =>
        new(module, function, services);

    public static string OverviewName(ModuleManifest manifest) => $"get_{ToolId(manifest)}";

    public static string FunctionName(ModuleManifest manifest, ModuleFunction function) => $"{ToolId(manifest)}_{function.Name}";

    private static string ToolId(ModuleManifest manifest) => manifest.Id.Replace('-', '_');

    public override Tool ProtocolTool { get; }

    public override IReadOnlyList<object> Metadata { get; } = [];

    private string FunctionLabel => _function?.Name ?? "get_module_data";

    private string Command => _function?.Command ?? "Get-ModuleData";

    public override async ValueTask<CallToolResult> InvokeAsync(
        RequestContext<CallToolRequestParams> request, CancellationToken cancellationToken = default)
    {
        var manifest = _module.Manifest;

        // Same rule as the window: an admin module or function never runs without admin rights.
        if ((manifest.RequiresAdmin || _function?.RequiresAdmin == true) && !Environment.IsPrivilegedProcess)
        {
            return Error($"'{ProtocolTool.Name}' requires administrator rights (root on Linux). " +
                         "Restart SysInfo --mcp elevated to use this tool.");
        }

        Dictionary<string, object?> parameters;
        try
        {
            parameters = BindArguments(_function?.Parameters ?? [], request.Params?.Arguments);
        }
        catch (ArgumentException ex)
        {
            return Error($"Invalid arguments for '{ProtocolTool.Name}': {ex.Message}");
        }

        try
        {
            // One runspace per module, created on first call and shared by its tools (calls are serialized).
            var service = _services.GetOrAdd(manifest.Id, _ => new PowerShellService(_module.ScriptPath));
            var watch = Stopwatch.StartNew();
            var data = await service.InvokeAsync(Command, parameters);
            watch.Stop();

            var envelope = Envelope.Build(manifest.Id, FunctionLabel, data, watch.Elapsed);
            return new CallToolResult
            {
                Content = [new TextContentBlock { Text = envelope.ToJsonString(JsonOptions) }],
                StructuredContent = JsonSerializer.SerializeToElement(envelope),
            };
        }
        catch (Exception ex)
        {
            // A failing module is a tool error, never a server crash.
            Console.Error.WriteLine($"[mcp] {ProtocolTool.Name} : {ex.Message}");
            return Error($"'{ProtocolTool.Name}' failed: {ex.Message}");
        }
    }

    // JSON Schema of the arguments, from module.json. No unknown argument is accepted.
    private static JsonElement BuildInputSchema(IReadOnlyList<FunctionParameter> parameters)
    {
        var properties = new JsonObject();
        foreach (var parameter in parameters)
        {
            var property = new JsonObject
            {
                ["type"] = parameter.Type switch
                {
                    ParameterType.Integer => "integer",
                    ParameterType.Number => "number",
                    ParameterType.Boolean => "boolean",
                    _ => "string",
                },
            };
            if (!string.IsNullOrWhiteSpace(parameter.Description))
                property["description"] = parameter.Description;
            if (parameter.Enum.Count > 0)
                property["enum"] = new JsonArray([.. parameter.Enum.Select(v => (JsonNode)v)]);
            if (parameter.Minimum is { } min)
                property["minimum"] = min;
            if (parameter.Maximum is { } max)
                property["maximum"] = max;
            if (parameter.Default is { } value)
                property["default"] = JsonNode.Parse(value.GetRawText());
            properties[parameter.Name] = property;
        }

        var schema = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = properties,
            ["additionalProperties"] = false,
        };
        var required = parameters.Where(p => p.Required).Select(p => (JsonNode)p.Name).ToArray();
        if (required.Length > 0)
            schema["required"] = new JsonArray(required);

        return JsonSerializer.SerializeToElement(schema);
    }

    // Checks each argument against module.json and converts it to the .NET type PowerShell expects.
    private static Dictionary<string, object?> BindArguments(
        IReadOnlyList<FunctionParameter> parameters, IDictionary<string, JsonElement>? arguments)
    {
        var bound = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        arguments ??= new Dictionary<string, JsonElement>();

        foreach (var name in arguments.Keys)
        {
            if (!parameters.Any(p => p.Name.Equals(name, StringComparison.Ordinal)))
                throw new ArgumentException($"unknown argument '{name}'" +
                    (parameters.Count > 0 ? $" (expected: {string.Join(", ", parameters.Select(p => p.Name))})" : " (this tool takes no arguments)"));
        }

        foreach (var parameter in parameters)
        {
            if (!arguments.TryGetValue(parameter.Name, out var value) || value.ValueKind == JsonValueKind.Null)
            {
                if (parameter.Required)
                    throw new ArgumentException($"'{parameter.Name}' is required");
                continue;
            }

            object converted = parameter.Type switch
            {
                ParameterType.Integer when value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var i) => i,
                ParameterType.Number when value.ValueKind == JsonValueKind.Number => value.GetDouble(),
                ParameterType.Boolean when value.ValueKind is JsonValueKind.True or JsonValueKind.False => value.GetBoolean(),
                ParameterType.String when value.ValueKind == JsonValueKind.String => value.GetString()!,
                _ => throw new ArgumentException($"'{parameter.Name}' must be of type {parameter.Type.ToString().ToLowerInvariant()}"),
            };

            if (parameter.Enum.Count > 0 && !parameter.Enum.Contains((string)converted, StringComparer.Ordinal))
                throw new ArgumentException($"'{parameter.Name}' must be one of: {string.Join(", ", parameter.Enum)}");

            if (converted is long or double)
            {
                var number = Convert.ToDouble(converted, CultureInfo.InvariantCulture);
                if (parameter.Minimum is { } min && number < min)
                    throw new ArgumentException($"'{parameter.Name}' must be ≥ {min.ToString(CultureInfo.InvariantCulture)}");
                if (parameter.Maximum is { } max && number > max)
                    throw new ArgumentException($"'{parameter.Name}' must be ≤ {max.ToString(CultureInfo.InvariantCulture)}");
            }

            bound[parameter.Name] = converted;
        }

        return bound;
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
