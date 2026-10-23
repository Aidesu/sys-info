using System;
using System.Globalization;
using System.Linq;
using System.Management.Automation;
using System.Text.Json.Nodes;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.Mcp;

/// <summary>
/// Standard result of every MCP tool (Specifications.md, « Sortie standard ») :
/// <code>
/// { "module", "function", "platform", "timestamp", "durationMs", "status",
///   "data": { "Subtitle", "Sections" }, "findings": [ { "severity", "code", "message", "recommendation" } ] }
/// </code>
/// data is what the function returned (same Sections as the window); findings are parsed and normalized here,
/// with the same rules as the window; status is the worst finding: ok, warning or critical.
/// Actions add "dryRun" (true for a preview), "changes" ([ { target, property, before, after } ], made or planned)
/// and, when the preview says the action cannot run, "blocked"; once run, "undo" ({ tool, parameters } that reverses
/// it, when there is one) and, for a critical action, "restorePoint"; a long task run as a job adds "jobId".
/// </summary>
public static class Envelope
{
    public static JsonObject Build(string module, string function, PSObject data, TimeSpan duration,
        bool action = false, bool dryRun = false, string? jobId = null, JsonObject? undo = null, string? restorePoint = null)
    {
        var findings = SectionParser.ParseFindings(data);
        var changes = SectionParser.ParseChanges(data);
        var blocked = SectionParser.ParseBlocked(data);

        var payload = PsJson.ToJson(data) as JsonObject ?? new JsonObject();
        payload.Remove("Findings");
        payload.Remove("Changes");
        payload.Remove("Blocked");
        payload.Remove("Undo");
        PsJson.NormalizeTables(payload);

        var envelope = new JsonObject
        {
            ["module"] = module,
            ["function"] = function,
            ["platform"] = OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsLinux() ? "linux" : "other",
            ["timestamp"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
            ["durationMs"] = (long)duration.TotalMilliseconds,
            ["status"] = AuditLog.StatusOf(findings),
        };
        if (jobId is not null)
            envelope["jobId"] = jobId;
        if (action)
        {
            envelope["dryRun"] = dryRun;
            if (blocked is not null)
                envelope["blocked"] = blocked;
            envelope["changes"] = new JsonArray([.. changes.Select(c => (JsonNode)new JsonObject
            {
                ["target"] = c.Target, ["property"] = c.Property, ["before"] = c.Before, ["after"] = c.After,
            })]);
            if (undo is not null && !dryRun)
                envelope["undo"] = undo.DeepClone();
            if (restorePoint is not null)
                envelope["restorePoint"] = restorePoint;
        }
        envelope["data"] = payload;
        envelope["findings"] = new JsonArray([.. findings.Select(ToJson)]);
        return envelope;
    }

    private static JsonNode ToJson(Finding finding)
    {
        var json = new JsonObject
        {
            ["severity"] = finding.Severity.ToString().ToLowerInvariant(),
            ["code"] = finding.Code,
            ["message"] = finding.Message,
        };
        if (finding.HasRecommendation)
            json["recommendation"] = finding.Recommendation;
        return json;
    }
}
