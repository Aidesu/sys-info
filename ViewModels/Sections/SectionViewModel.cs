using SysInfo.Models;

namespace SysInfo.ViewModels.Sections;

/// <summary>
/// A section on screen. It survives refreshes (same type and title) so that a Metric keeps its history
/// and a Table keeps its sort order; each refresh only calls <see cref="Update"/>.
/// </summary>
public abstract class SectionViewModel : ViewModelBase
{
    protected SectionViewModel(Section section)
    {
        Title = section.Title;
        Key = KeyOf(section);
    }

    public string Title { get; }

    public string Key { get; }

    public virtual SectionStatus Status => SectionStatus.None;

    public abstract void Update(Section section);

    public static string KeyOf(Section section) => $"{section.GetType().Name}/{section.Title}";

    public static SectionViewModel Create(Section section) => section switch
    {
        KeyValueSection kv => new KeyValueSectionViewModel(kv),
        MetricSection m => new MetricSectionViewModel(m),
        TableSection t => new TableSectionViewModel(t),
        UnsupportedSection u => new UnsupportedSectionViewModel(u),
        _ => new UnsupportedSectionViewModel(new UnsupportedSection(section.Title, section.GetType().Name)),
    };
}
