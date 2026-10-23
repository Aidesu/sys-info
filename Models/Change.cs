namespace SysInfo.Models;

/// <summary>
/// One change made (or, in a dry run, planned) by an action: Changes = @( @{ Target; Property; Before; After } )
/// beside Sections (PROJECT_CONTEXT.md §4.5). Written to the audit log, shown as a table, returned to the AI.
/// </summary>
public sealed record Change(string Target, string Property, string? Before, string? After);
