using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace SysInfo.Mcp;

/// <summary>
/// job_status and job_cancel: follow or stop the long tasks started by the module tools (see <see cref="JobManager"/>).
/// </summary>
public sealed class JobTool : McpServerTool
{
    private readonly JobManager _jobs;
    private readonly bool _cancel;

    private JobTool(JobManager jobs, bool cancel)
    {
        _jobs = jobs;
        _cancel = cancel;

        var properties = new JsonObject
        {
            ["jobId"] = new JsonObject
            {
                ["type"] = "string",
                ["description"] = cancel ? "Id of the job to stop." : "Id returned by the tool that started the job. Omit it to list the jobs of this session.",
            },
        };
        if (!cancel)
        {
            properties["waitSeconds"] = new JsonObject
            {
                ["type"] = "integer",
                ["description"] = "Wait up to this many seconds for the job to end before answering.",
                ["minimum"] = 0,
                ["maximum"] = 55,
                ["default"] = 20,
            };
        }
        var schema = new JsonObject { ["type"] = "object", ["properties"] = properties, ["additionalProperties"] = false };
        if (cancel)
            schema["required"] = new JsonArray("jobId");

        ProtocolTool = new Tool
        {
            Name = cancel ? "job_cancel" : "job_status",
            Title = cancel ? "Arrêter une tâche" : "Suivi des tâches",
            Description = cancel
                ? "Stops a long task started by a SysInfo tool (antivirus scan, space analysis…). Returns its state; changes " +
                  "already made by an action are not undone."
                : "State of a long task started by a SysInfo tool that answered with a jobId (status running, completed, " +
                  "failed or cancelled). When completed, returns the task's result envelope, as the tool would have. " +
                  "Without jobId, lists the jobs of this session.",
            InputSchema = JsonSerializer.SerializeToElement(schema),
            Annotations = new ToolAnnotations
            {
                ReadOnlyHint = !cancel,
                DestructiveHint = false,
                IdempotentHint = true,
                OpenWorldHint = false,
            },
        };
    }

    public static JobTool Status(JobManager jobs) => new(jobs, false);

    public static JobTool Cancel(JobManager jobs) => new(jobs, true);

    public override Tool ProtocolTool { get; }

    public override IReadOnlyList<object> Metadata { get; } = [];

    public override async ValueTask<CallToolResult> InvokeAsync(
        RequestContext<CallToolRequestParams> request, CancellationToken cancellationToken = default)
    {
        var arguments = request.Params?.Arguments ?? new Dictionary<string, JsonElement>();
        if (arguments.Keys.FirstOrDefault(k => k is not ("jobId" or "waitSeconds") || (_cancel && k == "waitSeconds")) is { } unknown)
            return ModuleTool.Error($"Invalid arguments for '{ProtocolTool.Name}': unknown argument '{unknown}'");

        string? id = null;
        if (arguments.TryGetValue("jobId", out var value) && value.ValueKind != JsonValueKind.Null)
        {
            if (value.ValueKind != JsonValueKind.String)
                return ModuleTool.Error($"Invalid arguments for '{ProtocolTool.Name}': 'jobId' must be of type string");
            id = value.GetString();
        }

        var wait = 20;
        if (arguments.TryGetValue("waitSeconds", out var seconds) && seconds.ValueKind != JsonValueKind.Null)
        {
            if (seconds.ValueKind != JsonValueKind.Number || !seconds.TryGetInt32(out wait) || wait is < 0 or > 55)
                return ModuleTool.Error($"Invalid arguments for '{ProtocolTool.Name}': 'waitSeconds' must be an integer from 0 to 55");
        }

        if (id is null)
        {
            if (_cancel)
                return ModuleTool.Error("Invalid arguments for 'job_cancel': 'jobId' is required");
            return ModuleTool.Success(new JsonObject { ["jobs"] = new JsonArray([.. _jobs.All.Select(j => (JsonNode)j.Describe())]) });
        }

        if (_jobs.Find(id) is not { } job)
            return ModuleTool.Error($"Unknown job '{id}' (jobs are kept for an hour after they end, and lost when the server restarts).");

        if (_cancel)
        {
            job.Cancel();
            await job.WaitAsync(TimeSpan.FromSeconds(10), cancellationToken);
            return ModuleTool.Success(job.Describe());
        }

        await job.WaitAsync(TimeSpan.FromSeconds(wait), cancellationToken);
        return ModuleTool.JobResult(job);
    }
}
