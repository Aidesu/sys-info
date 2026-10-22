using System.Collections.Generic;
using CommunityToolkit.Mvvm.ComponentModel;
using SysInfo.Models;

namespace SysInfo.ViewModels.Sections;

public partial class KeyValueSectionViewModel : SectionViewModel
{
    public KeyValueSectionViewModel(KeyValueSection section) : base(section)
    {
        Items = section.Items;
    }

    [ObservableProperty]
    public partial IReadOnlyList<KeyValueItem> Items { get; private set; }

    public override void Update(Section section) => Items = ((KeyValueSection)section).Items;
}
