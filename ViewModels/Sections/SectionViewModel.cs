using CommunityToolkit.Mvvm.ComponentModel;
using SysInfo.Models;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// A section on screen. It survives refreshes (same type and title) so that a Metric keeps its history
/// and a Table keeps its sort order; each refresh only calls <see cref="Update"/>.
/// </summary>
public abstract partial class SectionViewModel : ViewModelBase
{
    protected SectionViewModel(Section section)
    {
        Title = section.Title;
        Key = KeyOf(section);
        Icon = section.Icon;
    }

    public string Title { get; }

    /// <summary>Optional icon name shown before the card title.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasIcon))]
    public partial string? Icon { get; private set; }

    public bool HasIcon => !string.IsNullOrEmpty(Icon);

    /// <summary>Applies a refresh: the icon, then the section's own data.</summary>
    public void Refresh(Section section)
    {
        Icon = section.Icon;
        Update(section);
    }

    public string Key { get; }

    public virtual SectionStatus Status => SectionStatus.None;

    public abstract void Update(Section section);

    public static string KeyOf(Section section) => $"{section.GetType().Name}/{section.Title}";

    public static SectionViewModel Create(Section section) => section switch
    {
        KeyValueSection kv => new KeyValueSectionViewModel(kv),
        MetricSection m => new MetricSectionViewModel(m),
        TableSection t => new TableSectionViewModel(t),
        UsageSection u => new UsageSectionViewModel(u),
        UnsupportedSection u => new UnsupportedSectionViewModel(u),
        _ => new UnsupportedSectionViewModel(new UnsupportedSection(section.Title, section.GetType().Name)),
    };
}
