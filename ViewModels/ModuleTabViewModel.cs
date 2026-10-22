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
/// Only the active tab refreshes automatically, and not while paused.
/// </summary>
public partial class ModuleTabViewModel : NavPageViewModel, IDisposable
{
    private readonly LoadedModule _module;
    private readonly DispatcherTimer? _timer;
    private PowerShellService? _powerShell;
    private bool _loadedOnce;

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

    protected override void OnActiveChanged(bool isActive)
    {
        if (isActive && !_loadedOnce)
        {
            _loadedOnce = true;
            RefreshCommand.Execute(null);
        }
        UpdateTimer();
    }

    partial void OnIsPausedChanged(bool value) => UpdateTimer();

    private void UpdateTimer()
    {
        if (IsActive && !IsPaused)
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
                Sections[i].Update(sections[i]);
        }
        else
        {
            var previous = Sections.GroupBy(s => s.Key).ToDictionary(g => g.Key, g => g.First());
            Sections = sections
                .Select(s =>
                {
                    if (previous.Remove(SectionViewModel.KeyOf(s), out var existing))
                    {
                        existing.Update(s);
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
