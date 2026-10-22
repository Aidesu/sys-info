using SysInfo.Models;

namespace SysInfo.ViewModels.Sections;

public sealed class UnsupportedSectionViewModel : SectionViewModel
{
    public UnsupportedSectionViewModel(UnsupportedSection section) : base(section)
    {
        Type = section.Type;
    }

    public string Type { get; }

    public override void Update(Section section) { }
}
