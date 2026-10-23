using System.Linq;
using SysInfo.Models;

namespace SysInfo.Mcp;

/// <summary>
/// English descriptions of the MCP tools, built from module.json: they are what lets an AI pick the right tool.
/// </summary>
public static class McpDescriptions
{
    public const string ServerInstructions =
        "Read-only, live data about this computer. get_<module> tools return a module's overview (the same data as its " +
        "page in the SysInfo window); <module>_<function> tools are targeted queries with parameters (top, filter…). " +
        "Every tool returns the same envelope: { module, function, platform, timestamp, durationMs, status (ok, warning, " +
        "critical: the worst finding), data, findings }. Read findings first: each has a severity, a stable code, a message " +
        "and an optional recommendation (texts in French). data holds { Subtitle, Sections }; each section has Title, " +
        "optional Icon, and Type: KeyValue (Items: name → value), Metric (Value, Unit, optional Max, Warning and Critical " +
        "thresholds, Detail, and for two-series metrics Label plus Secondary { Label, Value }), Table (Columns, Rows as " +
        "arrays of values in column order) or Usage (Items: Label, Detail, Value out of Max in Unit, optional Warning and " +
        "Critical, Text).";

    private const string Output =
        " Returns the SysInfo envelope { module, function, status, data: { Subtitle, Sections }, findings } " +
        "(see the server instructions). Values are live, read at call time.";

    public static string Overview(LoadedModule module)
    {
        var manifest = module.Manifest;
        var what = string.IsNullOrWhiteSpace(manifest.Description)
            ? $"Returns the '{manifest.Title}' information of this computer (SysInfo module '{manifest.Id}')."
            : manifest.Description.Trim();

        return what + Admin(manifest.RequiresAdmin) + Targeted(module) + Output;
    }

    public static string Function(ModuleManifest manifest, ModuleFunction function)
    {
        var dependencies = function.Dependencies.Count > 0
            ? $" Uses {string.Join(", ", function.Dependencies)} when installed; without it, a finding says what to install."
            : string.Empty;

        return function.Description.Trim() + Admin(manifest.RequiresAdmin || function.RequiresAdmin) + dependencies + Output;
    }

    private static string Admin(bool requiresAdmin) =>
        requiresAdmin ? " Requires SysInfo to run with administrator rights." : string.Empty;

    // Points the AI to the targeted tools of the module, which return more detail than the overview.
    private static string Targeted(LoadedModule module)
    {
        var names = module.Functions.Where(f => f.Level == AccessLevel.L)
            .Select(f => ModuleTool.FunctionName(module.Manifest, f)).ToList();
        return names.Count > 0 ? $" For more detail, see {string.Join(", ", names)}." : string.Empty;
    }
}
