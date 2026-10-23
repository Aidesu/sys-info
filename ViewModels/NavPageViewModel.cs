using CommunityToolkit.Mvvm.ComponentModel;
using SysInfo.Models;

namespace SysInfo.ViewModels;

/// <summary>
/// An entry of the sidebar (a module, or Settings) and the page it opens.
/// </summary>
public abstract partial class NavPageViewModel : ViewModelBase
{
    public abstract string Title { get; }

    /// <summary>Icon name from the design system set (Styles/Icons.axaml).</summary>
    public abstract string Icon { get; }

    /// <summary>Worst state of the page. OK is never shown: only Warning and Critical.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsWarning), nameof(IsCritical), nameof(HasStatus), nameof(StatusText), nameof(NavToolTip))]
    public partial SectionStatus Status { get; protected set; }

    public bool IsWarning => Status == SectionStatus.Warning;

    public bool IsCritical => Status == SectionStatus.Critical;

    public bool HasStatus => Status != SectionStatus.None;

    public string StatusText => Status switch
    {
        SectionStatus.Warning => "Attention",
        SectionStatus.Critical => "Critique",
        _ => string.Empty,
    };

    /// <summary>Tooltip of the collapsed sidebar: the title, and the state when there is one.</summary>
    public string NavToolTip => HasStatus ? $"{Title} · {StatusText}" : Title;

    /// <summary>Short counter next to the entry (« 2 » tasks running); null = none.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasBadge))]
    public partial string? Badge { get; protected set; }

    public bool HasBadge => Badge is not null;

    /// <summary>True while the page is shown.</summary>
    [ObservableProperty]
    public partial bool IsActive { get; set; }

    partial void OnIsActiveChanged(bool value) => OnActiveChanged(value);

    protected virtual void OnActiveChanged(bool isActive) { }
}
