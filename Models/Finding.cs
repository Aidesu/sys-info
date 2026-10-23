namespace SysInfo.Models;

/// <summary>
/// A normalized observation returned beside the Sections (PROJECT_CONTEXT.md §4.3, Findings):
/// a stable Code lets an AI aggregate and prioritize without rereading all the data.
/// Message and Recommendation are written in French by the module.
/// </summary>
public sealed record Finding(FindingSeverity Severity, string Code, string Message, string? Recommendation)
{
    public bool IsInfo => Severity == FindingSeverity.Info;
    public bool IsWarning => Severity == FindingSeverity.Warning;
    public bool IsCritical => Severity == FindingSeverity.Critical;
    public bool HasRecommendation => !string.IsNullOrWhiteSpace(Recommendation);

    /// <summary>State carried on the tab: info carries none.</summary>
    public SectionStatus Status => Severity switch
    {
        FindingSeverity.Critical => SectionStatus.Critical,
        FindingSeverity.Warning => SectionStatus.Warning,
        _ => SectionStatus.None,
    };
}

public enum FindingSeverity
{
    Info,
    Warning,
    Critical,
}
