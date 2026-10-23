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
/// </summary>
public static class Envelope
{
    public static JsonObject Build(string module, string function, PSObject data, TimeSpan duration)
    {
        var findings = SectionParser.ParseFindings(data);

        var payload = PsJson.ToJson(data) as JsonObject ?? new JsonObject();
        payload.Remove("Findings");
        PsJson.NormalizeTables(payload);

        var worst = findings.Select(f => f.Severity).DefaultIfEmpty(FindingSeverity.Info).Max();

        return new JsonObject
        {
            ["module"] = module,
            ["function"] = function,
            ["platform"] = OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsLinux() ? "linux" : "other",
            ["timestamp"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
            ["durationMs"] = (long)duration.TotalMilliseconds,
            ["status"] = worst switch
            {
                FindingSeverity.Critical => "critical",
                FindingSeverity.Warning => "warning",
                _ => "ok",
            },
            ["data"] = payload,
            ["findings"] = new JsonArray([.. findings.Select(ToJson)]),
        };
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
