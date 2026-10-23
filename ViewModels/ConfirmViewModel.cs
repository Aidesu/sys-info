using System;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;
using SysInfo.Services;
using SysInfo.ViewModels.Sections;

namespace SysInfo.ViewModels;

/// <summary>
/// Confirmation of an action (level A or C), for an AI agent (`SysInfo --confirm`, opened by the MCP server) or for
/// the Outils card: who asks, which action, its parameters, then its preview (-DryRun: planned changes, warnings,
/// sections). « Exécuter » is only enabled once the preview is shown, and never when it says the action cannot run.
/// With a timeout, the window declines by itself when nobody answers.
/// </summary>
public partial class ConfirmViewModel : ViewModelBase
{
    private readonly Func<CancellationToken, Task<PSObject>> _preview;
    private readonly bool _restorePoint;
    private readonly TaskCompletionSource<ConfirmAnswer> _answer = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenSource _cancel = new();
    private readonly DispatcherTimer? _timer;
    private int _remaining;

    public ConfirmViewModel(
        LoadedModule module, ModuleFunction function, IReadOnlyDictionary<string, object?> arguments,
        string origin, Func<CancellationToken, Task<PSObject>> preview, int timeoutSeconds = 0)
    {
        _preview = preview;
        _restorePoint = function.NeedsRestorePoint;
        ModuleTitle = module.Manifest.Title;
        ModuleIcon = module.Manifest.Icon;
        ActionTitle = function.Title ?? function.Name;
        Origin = origin;
        LevelText = function.Level == AccessLevel.C ? "Action critique" : "Action réversible";
        IsCritical = function.Level == AccessLevel.C;
        Parameters = function.Parameters
            .Where(p => arguments.ContainsKey(p.Name))
            .Select(p => new KeyValueItem(p.Label ?? p.Name, FunctionArguments.Display(arguments[p.Name])))
            .ToList();

        if (timeoutSeconds > 0)
        {
            _remaining = timeoutSeconds;
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _timer.Tick += (_, _) =>
            {
                _remaining--;
                OnPropertyChanged(nameof(Countdown));
                if (_remaining <= 0)
                    Finish(ConfirmAnswer.TimedOut);
            };
            _timer.Start();
        }
    }

    /// <summary>The user's answer; also completed when the window is closed (declined).</summary>
    public Task<ConfirmAnswer> Answer => _answer.Task;

    public string ModuleTitle { get; }
    public string ModuleIcon { get; }
    public string ActionTitle { get; }
    public string Origin { get; }
    public string LevelText { get; }
    public bool IsCritical { get; }

    public IReadOnlyList<KeyValueItem> Parameters { get; }
    public bool HasParameters => Parameters.Count > 0;

    public string? Countdown => _timer is null ? null
        : _remaining > 0 ? $"Refus automatique dans {_remaining / 60}:{_remaining % 60:00}"
        : "Délai dépassé";

    public bool HasCountdown => _timer is not null;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowPreview))]
    [NotifyCanExecuteChangedFor(nameof(ConfirmCommand))]
    public partial bool IsLoading { get; private set; } = true;

    /// <summary>First line of the preview (« cups.service sera redémarré »).</summary>
    [ObservableProperty]
    public partial string? Summary { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasFindings))]
    public partial IReadOnlyList<Finding> Findings { get; private set; } = [];

    public bool HasFindings => Findings.Count > 0;

    [ObservableProperty]
    public partial IReadOnlyList<SectionViewModel> Sections { get; private set; } = [];

    /// <summary>Why the action cannot run (preview's Blocked), or why the preview failed.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsBlocked))]
    [NotifyCanExecuteChangedFor(nameof(ConfirmCommand))]
    public partial string? BlockedReason { get; private set; }

    public bool IsBlocked => BlockedReason is not null;

    public bool ShowPreview => !IsLoading;

    /// <summary>Critical action: the user must tick « J'ai lu l'aperçu » before « Exécuter ».</summary>
    public bool NeedsAcknowledge => IsCritical;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ConfirmCommand))]
    public partial bool Acknowledged { get; set; }

    /// <summary>Critical action: the restore point that will be created first, or why none can be.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasRestorePoint))]
    public partial string? RestorePointText { get; private set; }

    [ObservableProperty]
    public partial bool RestorePointAvailable { get; private set; }

    public bool HasRestorePoint => RestorePointText is not null;

    /// <summary>Computes the preview; called once the window is shown.</summary>
    public async Task LoadAsync()
    {
        try
        {
            var restore = _restorePoint ? RestorePoints.PreviewAsync(_cancel.Token) : null;
            var data = await _preview(_cancel.Token);
            if (restore is not null)
            {
                (RestorePointAvailable, RestorePointText) = await restore;
            }
            var changes = SectionParser.ParseChanges(data);
            Summary = SectionParser.ParseSubtitle(data);
            Findings = SectionParser.ParseFindings(data);
            var sections = SectionParser.Parse(data).ToList();
            if (SectionParser.ChangesSection(changes, dryRun: true) is { } table)
                sections.Insert(0, table);
            Sections = sections.Select(SectionViewModel.Create).ToList();
            BlockedReason = SectionParser.ParseBlocked(data);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex)
        {
            BlockedReason = $"Aperçu impossible : {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    private bool CanConfirm() => !IsLoading && !IsBlocked && (!NeedsAcknowledge || Acknowledged);

    [RelayCommand(CanExecute = nameof(CanConfirm))]
    private void Confirm() => Finish(ConfirmAnswer.Confirmed);

    [RelayCommand]
    private void Decline() => Finish(ConfirmAnswer.Declined);

    /// <summary>Closing the window without answering declines.</summary>
    public void Finish(ConfirmAnswer answer)
    {
        _timer?.Stop();
        _cancel.Cancel();
        if (_answer.TrySetResult(answer))
            Closed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Raised once, when the answer is given: the window closes.</summary>
    public event EventHandler? Closed;
}

public enum ConfirmAnswer
{
    Confirmed,
    Declined,
    TimedOut,
}
