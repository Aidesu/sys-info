using System.Linq;
using SysInfo.Models;

namespace SysInfo.Mcp;

/// <summary>
/// English descriptions of the MCP tools, built from module.json: they are what lets an AI pick the right tool.
/// </summary>
public static class McpDescriptions
{
    public const string ServerInstructions =
        "Live data about this computer, and a few actions. get_<module> tools return a module's overview (the same data as " +
        "its page in the SysInfo window); <module>_<function> tools are targeted queries with parameters (top, filter…) or " +
        "actions. An action (restart a service, flush the DNS cache…) is never run silently: SysInfo shows the user a " +
        "confirmation window with a preview and the call waits for their answer; pass dryRun=true first to see what it would " +
        "change. If the user declines, do not retry. Long tasks answer with a jobId: follow them with job_status, stop them " +
        "with job_cancel. " +
        "Every tool returns the same envelope: { module, function, platform, timestamp, durationMs, status (ok, warning, " +
        "critical: the worst finding), data, findings }. Read findings first: each has a severity, a stable code, a message " +
        "and an optional recommendation (texts in French). data holds { Subtitle, Sections }; each section has Title, " +
        "optional Icon, and Type: KeyValue (Items: name → value), Metric (Value, Unit, optional Max, Warning and Critical " +
        "thresholds, Detail, and for two-series metrics Label plus Secondary { Label, Value }), Table (Columns, Rows as " +
        "arrays of values in column order) or Usage (Items: Label, Detail, Value out of Max in Unit, optional Warning and " +
        "Critical, Text). Actions add dryRun, changes [{ target, property, before, after }] and, when they cannot run, " +
        "blocked (the reason).";

    private const string Output =
        " Returns the SysInfo envelope { module, function, status, data: { Subtitle, Sections }, findings } " +
        "(see the server instructions). Values are live, read at call time.";

    public static string Overview(LoadedModule module, bool actions = true)
    {
        var manifest = module.Manifest;
        var what = string.IsNullOrWhiteSpace(manifest.Description)
            ? $"Returns the '{manifest.Title}' information of this computer (SysInfo module '{manifest.Id}')."
            : manifest.Description.Trim();

        return what + Admin(manifest.RequiresAdmin) + Targeted(module, actions) + Output;
    }

    public static string Function(ModuleManifest manifest, ModuleFunction function)
    {
        var dependencies = function.Dependencies.Count > 0
            ? $" Uses {string.Join(", ", function.Dependencies)} when installed; without it, a finding says what to install."
            : string.Empty;

        return function.Description.Trim() + Admin(manifest.RequiresAdmin || function.RequiresAdmin) + dependencies
            + (function.IsAction ? Action : string.Empty)
            + (function.Level == AccessLevel.C ? Critical : string.Empty)
            + (function.Long ? LongTask : string.Empty)
            + Output;
    }

    private const string Action =
        " ACTION (changes the system): the user must confirm it in a SysInfo window showing a preview; the call waits up " +
        "to 2 minutes for the answer and fails if they decline. dryRun=true returns the preview only (planned changes, " +
        "warnings, or why it cannot run) without asking. Every call is written to the SysInfo audit log; when the action " +
        "can be reversed, the result has undo { tool, parameters }.";

    private const string Critical =
        " CRITICAL: needs SysInfo --mcp to run with administrator rights; a restore point is created first when possible. " +
        "Always call it with dryRun=true first and explain the preview to the user before asking for the real run.";

    private const string LongTask =
        " Long task: if it is not over after 25 s, the call returns { jobId, status: running }; then call job_status.";

    private static string Admin(bool requiresAdmin) =>
        requiresAdmin ? " Requires SysInfo to run with administrator rights." : string.Empty;

    // Points the AI to the targeted tools of the module, which return more detail than the overview, and to its actions.
    private static string Targeted(LoadedModule module, bool exposed)
    {
        string Names(AccessLevel level) => string.Join(", ", module.Functions.Where(f => f.Level == level)
            .Select(f => ModuleTool.FunctionName(module.Manifest, f)));
        var reads = Names(AccessLevel.L);
        var actions = exposed ? string.Join(", ", new[] { Names(AccessLevel.A), Names(AccessLevel.C) }.Where(n => n.Length > 0)) : string.Empty;
        return (reads.Length > 0 ? $" For more detail, see {reads}." : string.Empty)
             + (actions.Length > 0 ? $" Actions (confirmed by the user): {actions}." : string.Empty);
    }
}
