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

namespace SysInfo.ViewModels;

/// <summary>
/// One sidebar tab = one module: its data, its errors and its refresh cycle.
/// Every module refreshes in the background, shown or not (except while paused), so its history is ready.
/// </summary>
public partial class ModuleTabViewModel : NavPageViewModel, IDisposable
{
    private readonly LoadedModule _module;
    private readonly DispatcherTimer? _timer;
    private PowerShellService? _powerShell;
    private bool _started;

    public ModuleTabViewModel(LoadedModule module)
    {
        _module = module;

        if (module.Manifest.RefreshSeconds > 0)
        {
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(module.Manifest.RefreshSeconds) };
            _timer.Tick += (_, _) => { if (!IsBusy) RefreshCommand.Execute(null); };
        }
    }

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
        // Consecutive single-series Metric → MetricGroup (compact cards in a row, charts under them);
        // consecutive two-series Metric → ChartGroup (wide charts, two per row).
        var blocks = new List<ViewModelBase>();
        var metrics = new List<MetricSectionViewModel>();
        var charts = new List<MetricSectionViewModel>();

        void Flush()
        {
            if (metrics.Count > 0)
                blocks.Add(new MetricGroupViewModel([.. metrics]));
            if (charts.Count > 0)
                blocks.Add(new ChartGroupViewModel([.. charts]));
            metrics.Clear();
            charts.Clear();
        }

        foreach (var section in value)
        {
            if (section is MetricSectionViewModel metric)
            {
                var target = metric.IsDual ? charts : metrics;
                if ((metric.IsDual ? metrics : charts).Count > 0)
                    Flush();
                target.Add(metric);
                continue;
            }
            Flush();
            blocks.Add(section);
        }
        Flush();

        Blocks = blocks;
    }

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

    private void UpdateTimer()
    {
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
            _powerShell ??= await Task.Run(() => new PowerShellService(_module.ScriptPath));
            var data = await _powerShell.GetModuleDataAsync();
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

        Status = Sections.Select(s => s.Status).DefaultIfEmpty(SectionStatus.None).Max();
    }

    public void Dispose()
    {
        _timer?.Stop();
        _powerShell?.Dispose();
    }
}
