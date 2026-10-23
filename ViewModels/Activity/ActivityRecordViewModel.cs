using System;
using System.Collections.ObjectModel;
using System.Globalization;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.ViewModels.Activity;

/// <summary>
/// One run of a module function started from the window (Outils card): what runs, since when, its current step and
/// progress, and its live log (command, Write-Information, warnings, errors). Kept after it ends, for the session.
/// Thread-safe as a sink: PowerShell reports are posted to the UI thread.
/// </summary>
public partial class ActivityRecordViewModel : ViewModelBase, IActivitySink
{
    private const int MaxLines = 1000;
    private readonly Action? _cancel;

    public ActivityRecordViewModel(string title, string module, string tool, AccessLevel level, bool dryRun, Action? cancel)
    {
        Title = title;
        Module = module;
        Tool = tool;
        Level = level;
        DryRun = dryRun;
        _cancel = cancel;
        StartedAt = DateTime.Now;
    }

    public string Title { get; }
    public string Module { get; }
    public string Tool { get; }
    public AccessLevel Level { get; }
    public bool DryRun { get; }
    public DateTime StartedAt { get; }

    public string Kind => DryRun ? "Simulation" : Level switch
    {
        AccessLevel.C => "Action critique",
        AccessLevel.A => "Action",
        _ => "Consultation",
    };

    public string StartedText => StartedAt.ToString("HH:mm:ss", CultureInfo.CurrentCulture);

    public ObservableCollection<ActivityLine> Lines { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsRunning), nameof(StateText), nameof(IsFailed), nameof(IsWarning), nameof(IsDone))]
    [NotifyCanExecuteChangedFor(nameof(CancelCommand))]
    public partial ActivityState State { get; private set; } = ActivityState.Running;

    public bool IsRunning => State == ActivityState.Running;
    public bool IsFailed => State is ActivityState.Failed;
    public bool IsWarning => State is ActivityState.Warning or ActivityState.Cancelled or ActivityState.Declined;
    public bool IsDone => State == ActivityState.Succeeded;

    public string StateText => State switch
    {
        ActivityState.Running => "En cours",
        ActivityState.Succeeded => "Terminé",
        ActivityState.Warning => "Terminé avec des constats",
        ActivityState.Failed => "Échec",
        ActivityState.Cancelled => "Arrêté",
        ActivityState.Declined => "Refusé",
        _ => string.Empty,
    };

    /// <summary>Current step (Write-Progress) or the result once over.</summary>
    [ObservableProperty]
    public partial string? Status { get; private set; }

    /// <summary>Percent done when the module reports it; null = unknown (indeterminate bar).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasPercent))]
    public partial double? Percent { get; private set; }

    public bool HasPercent => Percent is not null;

    /// <summary>« 1 min 12 s », refreshed every second while running.</summary>
    [ObservableProperty]
    public partial string ElapsedText { get; private set; } = "0 s";

    /// <summary>Id of the audit line written at the end (links the history to this log).</summary>
    public string? AuditId { get; set; }

    [ObservableProperty]
    public partial bool IsExpanded { get; set; }

    public bool CanCancel => IsRunning && _cancel is not null;

    [RelayCommand(CanExecute = nameof(CanCancel))]
    private void Cancel() => _cancel?.Invoke();

    public void Log(string text, ActivityLineKind kind = ActivityLineKind.Info)
    {
        if (string.IsNullOrWhiteSpace(text))
            return;
        var line = new ActivityLine(DateTime.Now, text.TrimEnd(), kind);
        Dispatcher.UIThread.Post(() =>
        {
            Lines.Add(line);
            if (Lines.Count > MaxLines)
                Lines.RemoveAt(0);
        });
    }

    public void Progress(string status, int percent) => Dispatcher.UIThread.Post(() =>
    {
        Status = status;
        Percent = percent is >= 0 and <= 100 ? percent : null;
    });

    /// <summary>Called every second by <see cref="ActivityService"/> while running.</summary>
    internal void Tick() => ElapsedText = Format(DateTime.Now - StartedAt);

    public void Complete(ActivityState state, string? summary)
    {
        Tick();
        State = state;
        Percent = null;
        Status = summary;
        Log(state switch
        {
            ActivityState.Failed => $"Échec : {summary}",
            ActivityState.Cancelled => "Arrêté à la demande.",
            ActivityState.Declined => summary ?? "Refusé.",
            _ => $"Terminé en {ElapsedText}" + (string.IsNullOrEmpty(summary) ? "." : $" · {summary}"),
        }, state == ActivityState.Failed ? ActivityLineKind.Error : ActivityLineKind.Info);
    }

    public static string Format(TimeSpan span) =>
        span.TotalHours >= 1 ? $"{(int)span.TotalHours} h {span.Minutes:00} min"
        : span.TotalMinutes >= 1 ? $"{(int)span.TotalMinutes} min {span.Seconds:00} s"
        : $"{Math.Max(0, (int)span.TotalSeconds)} s";
}

public enum ActivityState
{
    Running,
    Succeeded,
    Warning,
    Failed,
    Cancelled,
    Declined,
}

/// <summary>One line of a live log.</summary>
public sealed record ActivityLine(DateTime Time, string Text, ActivityLineKind Kind)
{
    public string TimeText => Time.ToString("HH:mm:ss", CultureInfo.CurrentCulture);
    public bool IsCommand => Kind == ActivityLineKind.Command;
    public bool IsWarning => Kind == ActivityLineKind.Warning;
    public bool IsError => Kind == ActivityLineKind.Error;
}
