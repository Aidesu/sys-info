using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace SysInfo.Mcp;

/// <summary>
/// Long tasks of the MCP server (functions declared "long": space analysis, antivirus scan…). The tool call waits
/// <see cref="FirstWait"/>; if the task is not over, it returns a job id and the agent follows it with job_status
/// (optionally waiting up to 55 s per call) or stops it with job_cancel. Jobs live as long as the server; finished
/// ones are forgotten after an hour.
/// </summary>
public sealed class JobManager
{
    public static readonly TimeSpan FirstWait = TimeSpan.FromSeconds(25);

    private readonly ConcurrentDictionary<string, Job> _jobs = new();

    /// <summary>Starts <paramref name="work"/> (which returns the tool's envelope) in the background.</summary>
    public Job Start(string tool, Func<string, CancellationToken, Task<JsonObject>> work)
    {
        foreach (var old in _jobs.Values.Where(j => j.EndedAt is { } end && DateTime.UtcNow - end > TimeSpan.FromHours(1)))
            _jobs.TryRemove(old.Id, out _);

        var job = new Job(Guid.NewGuid().ToString("N")[..12], tool);
        _jobs[job.Id] = job;
        job.Run(work);
        return job;
    }

    public Job? Find(string id) => _jobs.TryGetValue(id, out var job) ? job : null;

    public IReadOnlyList<Job> All => [.. _jobs.Values.OrderByDescending(j => j.StartedAt)];
}

public enum JobState
{
    Running,
    Completed,
    Failed,
    Cancelled,
}

public sealed class Job(string id, string tool)
{
    private readonly CancellationTokenSource _cancel = new();

    public string Id { get; } = id;
    public string Tool { get; } = tool;
    public DateTime StartedAt { get; } = DateTime.UtcNow;
    public DateTime? EndedAt { get; private set; }
    public JobState State { get; private set; } = JobState.Running;
    public JsonObject? Result { get; private set; }
    public string? Error { get; private set; }

    /// <summary>Completes when the job ends, whatever the outcome; never faults.</summary>
    public Task Completion { get; private set; } = Task.CompletedTask;

    internal void Run(Func<string, CancellationToken, Task<JsonObject>> work)
    {
        Completion = Task.Run(async () =>
        {
            try
            {
                Result = await work(Id, _cancel.Token);
                State = JobState.Completed;
            }
            catch (OperationCanceledException) when (_cancel.IsCancellationRequested)
            {
                State = JobState.Cancelled;
            }
            catch (Exception ex)
            {
                Error = ex.Message;
                State = JobState.Failed;
            }
            finally
            {
                EndedAt = DateTime.UtcNow;
            }
        });
    }

    public void Cancel() => _cancel.Cancel();

    /// <summary>Waits for the end of the job, at most <paramref name="wait"/>.</summary>
    public async Task WaitAsync(TimeSpan wait, CancellationToken cancellationToken)
    {
        if (wait <= TimeSpan.Zero)
            return;
        try
        {
            await Completion.WaitAsync(wait, cancellationToken);
        }
        catch (TimeoutException)
        {
        }
    }

    /// <summary>State of the job for the agent: { jobId, tool, status, startedAt, elapsedMs, error? }.</summary>
    public JsonObject Describe()
    {
        var json = new JsonObject
        {
            ["jobId"] = Id,
            ["tool"] = Tool,
            ["status"] = State.ToString().ToLowerInvariant(),
            ["startedAt"] = StartedAt.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
            ["elapsedMs"] = (long)((EndedAt ?? DateTime.UtcNow) - StartedAt).TotalMilliseconds,
        };
        if (Error is not null)
            json["error"] = Error;
        if (State == JobState.Running)
            json["message"] = $"Still running. Call job_status with jobId '{Id}' (waitSeconds up to 55) to get the result, or job_cancel to stop it.";
        return json;
    }
}
