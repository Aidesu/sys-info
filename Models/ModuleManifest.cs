using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SysInfo.Models;

/// <summary>
/// Content of a module's module.json (see PROJECT_CONTEXT.md §4.1).
/// </summary>
public sealed record ModuleManifest
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public string Icon { get; init; } = string.Empty;
    public int Order { get; init; }
    public int RefreshSeconds { get; init; }
    public IReadOnlyList<string> Platforms { get; init; } = [];
    public bool RequiresAdmin { get; init; }

    /// <summary>
    /// Optional, in English: what the module returns. Used as the MCP tool description,
    /// which is what lets an AI pick the right tool.
    /// </summary>
    public string? Description { get; init; }

    /// <summary>
    /// Optional targeted functions of the module, besides Get-ModuleData (PROJECT_CONTEXT.md §4.4).
    /// Each one becomes the MCP tool &lt;id&gt;_&lt;name&gt;.
    /// </summary>
    public IReadOnlyList<ModuleFunction> Functions { get; init; } = [];
}

/// <summary>
/// A targeted function declared in module.json: a public PowerShell function of the .psm1, with parameters,
/// returning the same shape as Get-ModuleData (Subtitle, Sections, Findings).
/// </summary>
public sealed record ModuleFunction
{
    /// <summary>snake_case, ex. get_processes → MCP tool system_get_processes.</summary>
    public required string Name { get; init; }

    /// <summary>PowerShell function of the .psm1, ex. Get-SIProcesses.</summary>
    public required string Command { get; init; }

    /// <summary>In English: what the function returns, for the MCP tool description.</summary>
    public required string Description { get; init; }

    /// <summary>In French, for the window's Outils card (« Ping »). Default: the name.</summary>
    public string? Title { get; init; }

    public AccessLevel Level { get; init; } = AccessLevel.L;

    /// <summary>Subset of the module's platforms; empty = same as the module.</summary>
    public IReadOnlyList<string> Platforms { get; init; } = [];

    /// <summary>True if the function needs admin rights even when the module does not.</summary>
    public bool RequiresAdmin { get; init; }

    public IReadOnlyList<FunctionParameter> Parameters { get; init; } = [];

    /// <summary>Optional external tools the function uses when present (smartctl, nvidia-smi…).</summary>
    public IReadOnlyList<string> Dependencies { get; init; } = [];
}

/// <summary>
/// A parameter of a <see cref="ModuleFunction"/>, passed as -Name to the PowerShell function.
/// </summary>
public sealed record FunctionParameter
{
    /// <summary>camelCase name, same as the PowerShell parameter (case-insensitive), ex. top.</summary>
    public required string Name { get; init; }

    public ParameterType Type { get; init; } = ParameterType.String;

    /// <summary>In English, for the MCP input schema.</summary>
    public string Description { get; init; } = string.Empty;

    /// <summary>In French, for the form of the window's Outils card (« Cible »). Default: the name.</summary>
    public string? Label { get; init; }

    public bool Required { get; init; }

    /// <summary>Allowed values (string parameters only).</summary>
    public IReadOnlyList<string> Enum { get; init; } = [];

    public double? Minimum { get; init; }
    public double? Maximum { get; init; }

    /// <summary>Documented default; the PowerShell function applies it when the parameter is not sent.</summary>
    public JsonElement? Default { get; init; }
}

[JsonConverter(typeof(JsonStringEnumConverter<ParameterType>))]
public enum ParameterType
{
    String,
    Integer,
    Number,
    Boolean,
}

/// <summary>
/// Access level of a function (Specifications.md, « Règles MCP ») :
/// L read only · A reversible action · C critical action · X never exposed to MCP.
/// Only L is exposed to MCP for now; A and C wait for the confirmation and audit framework (sprint S4).
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<AccessLevel>))]
public enum AccessLevel
{
    L,
    A,
    C,
    X,
}

/// <summary>
/// A module found on disk and compatible with the current OS. Functions only holds the valid functions
/// compatible with this OS.
/// </summary>
public sealed record LoadedModule(ModuleManifest Manifest, string Directory, string ScriptPath)
{
    public IReadOnlyList<ModuleFunction> Functions { get; init; } = [];
}
