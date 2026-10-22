using System.Collections.Generic;
using System.Linq;
using Avalonia.Media;

namespace SysInfo.Services;

/// <summary>
/// Accent hues offered in Settings (design system, SwatchPicker guide): each passes 4.5:1 on Surface.
/// No green, amber or red: those are reserved for states.
/// </summary>
public static class AccentPalette
{
    public const string DefaultId = "azur";

    public static IReadOnlyList<AccentOption> Options { get; } =
    [
        new("azur", "Azur", Color.Parse("#6ea8ec"), Color.Parse("#1f65bd")),
        new("indigo", "Indigo", Color.Parse("#8f9cf2"), Color.Parse("#4152c4")),
        new("violet", "Violet", Color.Parse("#b394ec"), Color.Parse("#7445c2")),
        new("sarcelle", "Sarcelle", Color.Parse("#4fbfc2"), Color.Parse("#0c7478")),
        new("magenta", "Magenta", Color.Parse("#e48ad0"), Color.Parse("#a83591")),
        new("graphite", "Graphite", Color.Parse("#c3c8cf"), Color.Parse("#4a525b")),
    ];

    public static AccentOption Find(string? id) =>
        Options.FirstOrDefault(o => o.Id == id) ?? Options.First(o => o.Id == DefaultId);
}

/// <param name="Dark">Accent in the dark theme.</param>
/// <param name="Light">Accent in the light theme.</param>
public sealed record AccentOption(string Id, string Name, Color Dark, Color Light);
