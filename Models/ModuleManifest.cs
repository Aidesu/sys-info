using System.Collections.Generic;

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
}

/// <summary>
/// A module found on disk and compatible with the current OS.
/// </summary>
public sealed record LoadedModule(ModuleManifest Manifest, string Directory, string ScriptPath);
