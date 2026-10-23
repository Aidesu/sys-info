using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.Mcp;

/// <summary>
/// One MCP tool backed by one PowerShell function of a module: get_&lt;id&gt; (Get-ModuleData, the tab's overview)
/// or &lt;id&gt;_&lt;name&gt; (a function declared in module.json, with parameters). The input schema is built from
/// module.json, arguments are checked here, then passed as named parameters to the module's runspaces
/// (<see cref="ModuleRunner"/>). The result is the standard envelope (see <see cref="Envelope"/>).
/// <para>
/// An action (level A) takes an extra dryRun argument: true returns the preview only. Otherwise the action is
/// previewed, refused at once if the preview says it cannot run (Blocked), then confirmed by the user in a SysInfo
/// window (<see cref="ConfirmationProcess"/>) before it runs. A long function runs as a job (<see cref="JobManager"/>).
/// Every call is written to the audit log.
/// </para>
/// </summary>
public sealed class ModuleTool : McpServerTool
{
    private readonly ModuleRunner _runner;
    private readonly ModuleFunction? _function;
    private readonly JobManager _jobs;

    private ModuleTool(ModuleRunner runner, ModuleFunction? function, JobManager jobs, bool actions = true)
    {
        _runner = runner;
        _function = function;
        _jobs = jobs;
        var module = runner.Module;
        var action = function?.IsAction == true;

        ProtocolTool = new Tool
        {
            Name = function is null ? OverviewName(module.Manifest) : FunctionName(module.Manifest, function),
            Title = function is null ? module.Manifest.Title : $"{module.Manifest.Title} · {function.Title ?? function.Name}",
            Description = function is null ? McpDescriptions.Overview(module, actions) : McpDescriptions.Function(module.Manifest, function),
            InputSchema = BuildInputSchema(function?.Parameters ?? [], action),
            Annotations = new ToolAnnotations
            {
                Title = module.Manifest.Title,
                ReadOnlyHint = !action,
                DestructiveHint = function?.Level == AccessLevel.C,
                IdempotentHint = !action,
                OpenWorldHint = false,
            },
        };
    }

    public static ModuleTool Overview(ModuleRunner runner, JobManager jobs, bool actions) => new(runner, null, jobs, actions);

    public static ModuleTool ForFunction(ModuleRunner runner, ModuleFunction function, JobManager jobs) => new(runner, function, jobs);

    public static string OverviewName(ModuleManifest manifest) => $"get_{ToolId(manifest)}";

    public static string FunctionName(ModuleManifest manifest, ModuleFunction function) => $"{ToolId(manifest)}_{function.Name}";

    private static string ToolId(ModuleManifest manifest) => manifest.Id.Replace('-', '_');

    public override Tool ProtocolTool { get; }

    public override IReadOnlyList<object> Metadata { get; } = [];

    private ModuleManifest Manifest => _runner.Module.Manifest;

    private string FunctionLabel => _function?.Name ?? "get_module_data";

    private bool IsAction => _function?.IsAction == true;

    public override async ValueTask<CallToolResult> InvokeAsync(
        RequestContext<CallToolRequestParams> request, CancellationToken cancellationToken = default)
    {
        var client = request.Server.ClientInfo is { } info ? $"{info.Name} {info.Version}".Trim() : null;
        Dictionary<string, object?> parameters;
        var dryRun = false;
        try
        {
            var arguments = request.Params?.Arguments;
            parameters = FunctionArguments.Bind(_function?.Parameters ?? [], arguments, IsAction ? [FunctionArguments.DryRun] : []);
            if (IsAction && arguments?.TryGetValue(FunctionArguments.DryRun, out var flag) == true && flag.ValueKind != JsonValueKind.Null)
            {
                dryRun = flag.ValueKind switch
                {
                    JsonValueKind.True => true,
                    JsonValueKind.False => false,
                    _ => throw new ArgumentException($"'{FunctionArguments.DryRun}' must be of type boolean"),
                };
            }
        }
        catch (ArgumentException ex)
        {
            return Error($"Invalid arguments for '{ProtocolTool.Name}': {ex.Message}");
        }

        // Same rule as the window: an admin module or function never runs without admin rights; a critical action
        // can still be previewed.
        if (_runner.RightsProblem(_function, dryRun) is not null)
        {
            return Error($"'{ProtocolTool.Name}' requires administrator rights (root on Linux). Restart SysInfo --mcp " +
                         "elevated to use this tool" + (_function?.Level == AccessLevel.C ? " (dryRun=true works without them)." : "."));
        }

        var audit = new AuditEntry
        {
            Origin = "mcp",
            Client = client,
            Tool = ProtocolTool.Name,
            Module = Manifest.Id,
            Function = FunctionLabel,
            Level = _function?.Level ?? AccessLevel.L,
            Parameters = parameters,
            DryRun = dryRun,
            Status = "error",
        };

        try
        {
            if (!IsAction || dryRun)
                return await RunAsync(parameters, dryRun, audit, cancellationToken);

            // Action: preview first. When it cannot run (rights, unknown target, protected), the user is not asked.
            var (preview, previewDuration) = await _runner.InvokeAsync(_function, parameters, dryRun: true, cancellationToken);
            if (SectionParser.ParseBlocked(preview) is { } blocked)
            {
                AuditLog.Write(audit with { DryRun = true, Status = "blocked", DurationMs = (long)previewDuration.TotalMilliseconds, Error = blocked });
                return Error($"'{ProtocolTool.Name}' cannot run: {blocked} (the user was not asked).");
            }

            var (decision, detail) = await ConfirmationProcess.RequestAsync(_runner.Module, _function!, parameters, client, cancellationToken);
            if (decision != ConfirmationResult.Confirmed)
            {
                var (confirmation, message) = decision switch
                {
                    ConfirmationResult.Declined => ("declined", "The user declined the action in SysInfo. Do not retry it unless they ask."),
                    ConfirmationResult.TimedOut => ("timeout", $"The user did not answer the SysInfo confirmation window within {ConfirmationProcess.TimeoutSeconds} s; nothing was changed."),
                    _ => ("unavailable", $"The action could not be confirmed: {detail}. Nothing was changed; the user can run it from the Outils card of the SysInfo window."),
                };
                AuditLog.Write(audit with { Confirmation = confirmation, Status = "declined", Error = detail });
                return Error($"'{ProtocolTool.Name}': {message}");
            }

            // Critical action: restore point first; if it cannot be created, the action does not run.
            string? restorePoint;
            try
            {
                restorePoint = await RestorePoints.CreateBeforeAsync(_runner.Module, _function!, cancellationToken);
            }
            catch (InvalidOperationException ex)
            {
                AuditLog.Write(audit with { Confirmation = "confirmed", Error = ex.Message });
                return Error($"'{ProtocolTool.Name}': {ex.Message}");
            }

            return await RunAsync(parameters, false, audit with { Confirmation = "confirmed", RestorePoint = restorePoint }, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            AuditLog.Write(audit with { Status = "cancelled" });
            throw;
        }
        catch (Exception ex)
        {
            // A failing module is a tool error, never a server crash.
            Console.Error.WriteLine($"[mcp] {ProtocolTool.Name} : {ex.Message}");
            AuditLog.Write(audit with { Error = ex.Message });
            return Error($"'{ProtocolTool.Name}' failed: {ex.Message}");
        }
    }

    // Runs the function (or its preview) and writes the audit line. A long function runs as a job: its result comes
    // back here if it ends within the first wait, else the agent gets the job id.
    private async Task<CallToolResult> RunAsync(
        Dictionary<string, object?> parameters, bool dryRun, AuditEntry audit, CancellationToken cancellationToken)
    {
        if (_function?.Long != true || dryRun)
        {
            var (data, duration) = await _runner.InvokeAsync(_function, parameters, dryRun, cancellationToken);
            var undo = Audit(audit, data, duration);
            return Success(Envelope.Build(Manifest.Id, FunctionLabel, data, duration, IsAction, dryRun, undo: undo, restorePoint: audit.RestorePoint));
        }

        var job = _jobs.Start(ProtocolTool.Name, async (id, token) =>
        {
            try
            {
                var (data, duration) = await _runner.InvokeAsync(_function, parameters, false, token);
                var undo = Audit(audit with { JobId = id }, data, duration);
                return Envelope.Build(Manifest.Id, FunctionLabel, data, duration, IsAction, false, id, undo, audit.RestorePoint);
            }
            catch (Exception ex)
            {
                AuditLog.Write(audit with { JobId = id, Status = ex is OperationCanceledException ? "cancelled" : "error", Error = ex.Message });
                throw;
            }
        });
        // Start line: the window's Activité page shows the task as running until its end line (same jobId).
        AuditLog.Write(audit with { JobId = job.Id, Status = "running" });

        await job.WaitAsync(JobManager.FirstWait, cancellationToken);
        return JobResult(job);
    }

    // Writes the audit line of a finished call; returns the action's undo, if any.
    private JsonObject? Audit(AuditEntry audit, PSObject data, TimeSpan duration)
    {
        var findings = SectionParser.ParseFindings(data);
        var undo = audit.DryRun ? null : SectionParser.ParseUndo(data, Manifest);
        AuditLog.Write(audit with
        {
            Status = SectionParser.ParseBlocked(data) is null ? AuditLog.StatusOf(findings) : "blocked",
            DurationMs = (long)duration.TotalMilliseconds,
            Findings = [.. findings.Select(f => f.Code)],
            Changes = SectionParser.ParseChanges(data),
            Undo = undo,
        });
        return undo;
    }

    /// <summary>A job as a tool result: its envelope once completed, its state while running, an error if it failed.</summary>
    internal static CallToolResult JobResult(Job job) => job.State switch
    {
        JobState.Completed => Success(job.Result!),
        JobState.Failed => Error($"'{job.Tool}' failed (job {job.Id}): {job.Error}"),
        _ => Success(job.Describe()),
    };

    internal static CallToolResult Success(JsonObject json) => new()
    {
        Content = [new TextContentBlock { Text = json.ToJsonString(JsonOptions) }],
        StructuredContent = JsonSerializer.SerializeToElement(json),
    };

    // JSON Schema of the arguments, from module.json. No unknown argument is accepted.
    private static JsonElement BuildInputSchema(IReadOnlyList<FunctionParameter> parameters, bool action)
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
        if (action)
        {
            properties[FunctionArguments.DryRun] = new JsonObject
            {
                ["type"] = "boolean",
                ["description"] = "Preview only: returns what would change (changes, findings, blocked), changes nothing and asks nobody.",
                ["default"] = false,
            };
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

    internal static CallToolResult Error(string message) => new()
    {
        IsError = true,
        Content = [new TextContentBlock { Text = message }],
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}
