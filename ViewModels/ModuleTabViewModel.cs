using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;
using SysInfo.Services;
using SysInfo.ViewModels.Sections;
using SysInfo.ViewModels.Tools;

namespace SysInfo.ViewModels;

/// <summary>
/// One sidebar tab = one module: its data, its errors and its refresh cycle.
/// Every module refreshes in the background, shown or not (except while paused), so its history is ready.
/// </summary>
public partial class ModuleTabViewModel : NavPageViewModel, IDisposable
{
    private readonly LoadedModule _module;
    private readonly DispatcherTimer? _timer;
    // Page refresh, Outils card and long tasks each have their own runspace: a 30 s analysis never stalls the page.
    private readonly ModuleRunner _runner;
    private bool _started;

    public ModuleTabViewModel(LoadedModule module)
    {
        _module = module;
        _runner = new ModuleRunner(module);
        Host.ModuleHost.Register(_runner);

        if (module.Manifest.RefreshSeconds > 0)
        {
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(module.Manifest.RefreshSeconds) };
            _timer.Tick += (_, _) => { if (!IsBusy) RefreshCommand.Execute(null); };
        }

        // Reads and actions (A and C, confirmed in a window); X functions are UI-only and have no generic card.
        Tools = module.Functions
            .Where(f => f.Level != AccessLevel.X)
            .Select(f => new FunctionToolViewModel(f, _runner))
            .ToList();
    }

    /// <summary>Targeted functions of the module (module.json › functions), shown in the Outils card.</summary>
    public IReadOnlyList<FunctionToolViewModel> Tools { get; }

    public bool HasTools => Tools.Count > 0;

    /// <summary>Tools that only read (L), listed first in the Outils card.</summary>
    public IReadOnlyList<FunctionToolViewModel> ReadTools => [.. Tools.Where(t => !t.IsAction)];

    /// <summary>Actions (A, C), under their own heading.</summary>
    public IReadOnlyList<FunctionToolViewModel> ActionTools => [.. Tools.Where(t => t.IsAction)];

    public bool HasReadTools => ReadTools.Count > 0;

    public bool HasActionTools => ActionTools.Count > 0;

    public string Id => _module.Manifest.Id;
    public override string Title => _module.Manifest.Title;
    public override string Icon => _module.Manifest.Icon;

    [ObservableProperty]
    public partial IReadOnlyList<SectionViewModel> Sections { get; private set; } = [];

    /// <summary>
    /// What the page shows, in order: each section, except that consecutive Metric sections form one
    /// <see cref="MetricGroupViewModel"/> (cards side by side, charts underneath). Rebuilt only when the
    /// list of sections changes, not on each refresh.
    /// </summary>
    [ObservableProperty]
    public partial IReadOnlyList<ViewModelBase> Blocks { get; private set; } = [];

    partial void OnSectionsChanged(IReadOnlyList<SectionViewModel> value)
    {
        Blocks = SectionBlocks.Build(value);
    }

    /// <summary>Normalized findings of the module, worst first, shown above the sections.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasFindings))]
    public partial IReadOnlyList<Finding> Findings { get; private set; } = [];

    public bool HasFindings => Findings.Count > 0;

    /// <summary>Findings on screen: kept between refreshes to animate those that appear or leave.</summary>
    public FindingListViewModel FindingList { get; } = new();

    /// <summary>Optional subtitle from the module, shown after the page title ("wlp4s0 · 192.168.1.42").</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSubtitle))]
    public partial string? Subtitle { get; private set; }

    public bool HasSubtitle => !string.IsNullOrEmpty(Subtitle);

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError), nameof(ShowSkeleton))]
    public partial string? ErrorMessage { get; private set; }

    public bool HasError => ErrorMessage is not null;

    /// <summary>True when the module needs admin rights the app does not have: retrying cannot help.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ErrorTitle))]
    [NotifyPropertyChangedFor(nameof(CanRetry))]
    public partial bool NeedsElevation { get; private set; }

    public string ErrorTitle => NeedsElevation ? "Droits administrateur requis" : $"Le module {Title} ne répond pas";

    public bool CanRetry => !NeedsElevation;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusLine), nameof(ShowSkeleton))]
    public partial bool IsBusy { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusLine), nameof(ShowSkeleton))]
    public partial DateTime? LastUpdated { get; private set; }

    /// <summary>First load: placeholders shaped like the content, never a full-page spinner.</summary>
    public bool ShowSkeleton => LastUpdated is null && !HasError;

    public string StatusLine =>
        IsBusy && LastUpdated is null ? "Chargement…"
        : LastUpdated is { } at ? $"Mis à jour à {at:HH:mm:ss}"
        : string.Empty;

    /// <summary>Automatic refresh suspended (window minimized, see Settings).</summary>
    [ObservableProperty]
    public partial bool IsPaused { get; set; }

    /// <summary>
    /// Starts collecting: a first load, then the automatic refresh. Called for every module when the window
    /// opens, so that history, statistics and tab states are already filled when a page is opened.
    /// </summary>
    public void Start()
    {
        if (_started)
            return;
        _started = true;
        RefreshCommand.Execute(null);
        UpdateTimer();
    }

    partial void OnIsPausedChanged(bool value) => UpdateTimer();

    /// <summary>
    /// Saves resources (Settings, on by default): while its page is not shown, the module refreshes less often
    /// (<see cref="HiddenInterval"/>); its tab state and chart history keep going. Opening the page refreshes it at once.
    /// </summary>
    [ObservableProperty]
    public partial bool EcoMode { get; set; } = true;

    partial void OnEcoModeChanged(bool value) => UpdateTimer();

    /// <summary>Hidden page: 5 × the module's rhythm, at least its rhythm, at most a minute (2 s → 10 s, 10 s → 50 s, 60 s → 60 s).</summary>
    private TimeSpan HiddenInterval
    {
        get
        {
            var seconds = _module.Manifest.RefreshSeconds;
            return TimeSpan.FromSeconds(Math.Max(seconds, Math.Min(seconds * 5, 60)));
        }
    }

    protected override void OnActiveChanged(bool isActive)
    {
        UpdateTimer();
        // Back on screen after a slower rhythm: fresh data now rather than at the next tick.
        if (isActive && _started && EcoMode && !IsBusy && LastUpdated is { } at
            && DateTime.Now - at > TimeSpan.FromSeconds(_module.Manifest.RefreshSeconds))
            RefreshCommand.Execute(null);
    }

    private void UpdateTimer()
    {
        if (_timer is not null)
        {
            var interval = EcoMode && !IsActive ? HiddenInterval : TimeSpan.FromSeconds(_module.Manifest.RefreshSeconds);
            if (_timer.Interval != interval)
                _timer.Interval = interval;
        }
        if (_started && !IsPaused)
            _timer?.Start();
        else
            _timer?.Stop();
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        if (_module.Manifest.RequiresAdmin && !Environment.IsPrivilegedProcess)
        {
            NeedsElevation = true;
            ErrorMessage = "Relancez SysInfo en administrateur (root sous Linux) pour afficher ce module.";
            return;
        }

        IsBusy = true;
        try
        {
            var (data, _) = await _runner.InvokeAsync(null);
            Findings = SectionParser.ParseFindings(data);
            // Animated only when the page is on screen and already showed data: not at first load, not in the
            // background (opening the page then shows the current state at once).
            FindingList.Animate = IsActive && LastUpdated is not null;
            FindingList.Update(Findings);
            ApplySections(SectionParser.Parse(data));
            Subtitle = SectionParser.ParseSubtitle(data);
            ErrorMessage = null;
            LastUpdated = DateTime.Now;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    // Same sections as before (type + title, same order): update them in place, so the view is not rebuilt
    // and Metric history / Table sort are kept. Otherwise rebuild the list, reusing what still matches.
    private void ApplySections(IReadOnlyList<Section> sections)
    {
        var keys = sections.Select(SectionViewModel.KeyOf).ToList();
        if (keys.SequenceEqual(Sections.Select(s => s.Key)))
        {
            for (var i = 0; i < sections.Count; i++)
                Sections[i].Refresh(sections[i]);
        }
        else
        {
            var previous = Sections.GroupBy(s => s.Key).ToDictionary(g => g.Key, g => g.First());
            Sections = sections
                .Select(s =>
                {
                    if (previous.Remove(SectionViewModel.KeyOf(s), out var existing))
                    {
                        existing.Refresh(s);
                        return existing;
                    }
                    return SectionViewModel.Create(s);
                })
                .ToList();
        }

        // Charts are laid out by time over the module's normal rhythm (samples are sparser while the page is hidden).
        foreach (var metric in Sections.OfType<MetricSectionViewModel>().Where(m => !m.HasHistory))
            metric.ChartWindow = TimeSpan.FromSeconds(_module.Manifest.RefreshSeconds * (MetricSectionViewModel.HistoryLength - 1));

        // The tab carries the worst state of its Metric / Usage thresholds and of its findings.
        Status = Sections.Select(s => s.Status)
            .Concat(Findings.Select(f => f.Status))
            .DefaultIfEmpty(SectionStatus.None)
            .Max();
    }

    public void Dispose()
    {
        _timer?.Stop();
        _runner.Dispose();
    }
}
