using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Management.Automation;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;
using SysInfo.Services;
using SysInfo.ViewModels.Activity;
using SysInfo.ViewModels.Sections;

namespace SysInfo.ViewModels.Tools;

/// <summary>
/// A targeted function of the module in the window's Outils card: its form, a Run button and its result
/// (same Sections and Findings as the MCP tool &lt;id&gt;_&lt;name&gt;, rendered with the page's section views).
/// An action (level A) also has « Simuler » (its -DryRun preview), and « Exécuter… » opens the confirmation window
/// first. A running function can be cancelled. Every run is written to the audit log (origin "ui") and followed live
/// on the Activité page (steps, progress, log).
/// </summary>
public partial class FunctionToolViewModel : ViewModelBase
{
    private readonly ModuleFunction _function;
    private readonly ModuleRunner _runner;
    private CancellationTokenSource? _cancel;

    public FunctionToolViewModel(ModuleFunction function, ModuleRunner runner)
    {
        _function = function;
        _runner = runner;
        Parameters = function.Parameters.Select(p => new FunctionParameterViewModel(p)).ToList();
    }

    public string Title => _function.Title ?? _function.Name;

    public bool IsAction => _function.IsAction;

    /// <summary>Tag after the title: « Action » or « Tâche longue ».</summary>
    public string? Tag => IsAction ? (_function.Level == AccessLevel.C ? "Action critique" : "Action") : _function.Long ? "Tâche longue" : null;

    public bool IsCritical => _function.Level == AccessLevel.C;

    public bool HasTag => Tag is not null;

    public string RunLabel => IsAction ? "Exécuter…" : "Exécuter";

    public IReadOnlyList<FunctionParameterViewModel> Parameters { get; }

    public bool HasParameters => Parameters.Count > 0;

    /// <summary>Expander state, kept while the page is rebuilt.</summary>
    [ObservableProperty]
    public partial bool IsExpanded { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RunCommand), nameof(PreviewCommand), nameof(CancelCommand))]
    public partial bool IsRunning { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasResult))]
    public partial IReadOnlyList<SectionViewModel> Results { get; private set; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasFindings))]
    public partial IReadOnlyList<Finding> Findings { get; private set; } = [];

    public bool HasResult => Results.Count > 0;
    public bool HasFindings => Findings.Count > 0;

    /// <summary>Subtitle returned by the function, then when and how long it ran.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasStatus))]
    public partial string? Status { get; private set; }

    public bool HasStatus => !string.IsNullOrEmpty(Status);

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    public partial string? ErrorMessage { get; private set; }

    public bool HasError => ErrorMessage is not null;

    private bool CanRun() => !IsRunning;

    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task RunAsync()
    {
        if (ReadArguments(dryRun: false) is not { } arguments)
            return;

        var activity = StartActivity(dryRun: false);
        var confirmation = "not-required";
        if (IsAction)
        {
            activity.Progress("En attente de confirmation…", -1);
            var confirm = new ConfirmViewModel(_runner.Module, _function, arguments,
                $"Depuis la fenêtre SysInfo, sous le compte {Environment.UserName}" +
                (Environment.IsPrivilegedProcess ? " avec les droits administrateur." : "."),
                async token => (await _runner.InvokeAsync(_function, arguments, dryRun: true, token)).Data);
            var answer = await DialogService.ConfirmAsync(confirm);
            if (answer != ConfirmAnswer.Confirmed)
            {
                activity.AuditId = AuditLog.Write(Audit(arguments, false) with { Confirmation = "declined", Status = "declined" });
                Status = "Action annulée : rien n'a été modifié.";
                Finish(activity, ActivityState.Declined, "Action refusée à la confirmation : rien n'a été modifié.");
                return;
            }
            confirmation = "confirmed";
            activity.Log("Action confirmée.");
        }

        // Critical action: restore point first; if it cannot be created, the action does not run.
        string? restorePoint = null;
        if (_function.NeedsRestorePoint)
        {
            IsRunning = true;
            Status = "Création du point de restauration…";
            activity.Progress("Création du point de restauration…", -1);
            activity.Log("New-SIRestorePoint (module Maintenance)", ActivityLineKind.Command);
            try
            {
                restorePoint = await RestorePoints.CreateBeforeAsync(_runner.Module, _function, CancellationToken.None);
                activity.Log($"Point de restauration : {restorePoint ?? "aucun"}");
            }
            catch (Exception ex)
            {
                activity.AuditId = AuditLog.Write(Audit(arguments, false) with { Confirmation = confirmation, Error = ex.Message });
                Status = null;
                ErrorMessage = ex.Message;
                Finish(activity, ActivityState.Failed, ex.Message);
                return;
            }
            finally
            {
                IsRunning = false;
            }
        }

        await ExecuteAsync(arguments, activity, dryRun: false, confirmation, restorePoint);
    }

    /// <summary>Preview of an action: what it would change, without changing anything.</summary>
    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task PreviewAsync()
    {
        if (ReadArguments(dryRun: true) is { } arguments)
            await ExecuteAsync(arguments, StartActivity(dryRun: true), dryRun: true, "not-required");
    }

    [RelayCommand(CanExecute = nameof(IsRunning))]
    private void Cancel() => _cancel?.Cancel();

    private Dictionary<string, object?>? ReadArguments(bool dryRun)
    {
        if (_runner.RightsProblem(_function, dryRun) is { } problem)
        {
            ErrorMessage = problem;
            return null;
        }
        try
        {
            ErrorMessage = null;
            return Parameters
                .Select(p => (p.Name, Value: p.GetValue()))
                .Where(p => p.Value is not null)
                .ToDictionary(p => p.Name, p => p.Value, StringComparer.OrdinalIgnoreCase);
        }
        catch (ArgumentException ex)
        {
            ErrorMessage = ex.Message;
            return null;
        }
    }

    // The Activité page follows the run (a standalone record when there is no page, in the confirmation window).
    private ActivityRecordViewModel StartActivity(bool dryRun)
    {
        var title = $"{_runner.Module.Manifest.Title} · {Title}";
        var tool = Mcp.ModuleTool.FunctionName(_runner.Module.Manifest, _function);
        return ActivityViewModel.Current?.Start(title, _runner.Module.Manifest.Title, tool, _function.Level, dryRun, () => _cancel?.Cancel())
               ?? new ActivityRecordViewModel(title, _runner.Module.Manifest.Title, tool, _function.Level, dryRun, null);
    }

    private static void Finish(ActivityRecordViewModel activity, ActivityState state, string? summary)
    {
        if (ActivityViewModel.Current is { } page)
            page.Finish(activity, state, summary);
        else
            activity.Complete(state, summary);
    }

    private async Task ExecuteAsync(Dictionary<string, object?> arguments, ActivityRecordViewModel activity, bool dryRun, string confirmation, string? restorePoint = null)
    {
        var audit = Audit(arguments, dryRun) with { Confirmation = confirmation, RestorePoint = restorePoint };
        _cancel = new CancellationTokenSource();
        IsRunning = true;
        Status = dryRun ? "Simulation…" : "En cours…";
        activity.Progress(dryRun ? "Simulation…" : "En cours…", -1);
        try
        {
            var (data, duration) = await _runner.InvokeAsync(_function, arguments, dryRun, _cancel.Token, activity);
            var findings = SectionParser.ParseFindings(data);
            var changes = SectionParser.ParseChanges(data);
            activity.AuditId = AuditLog.Write(audit with
            {
                Status = SectionParser.ParseBlocked(data) is null ? AuditLog.StatusOf(findings) : "blocked",
                DurationMs = (long)duration.TotalMilliseconds,
                Findings = [.. findings.Select(f => f.Code)],
                Changes = changes,
                Undo = dryRun ? null : SectionParser.ParseUndo(data, _runner.Module.Manifest),
            });

            var sections = SectionParser.Parse(data).ToList();
            if (SectionParser.ChangesSection(changes, dryRun) is { } table)
                sections.Insert(0, table);
            Findings = findings;
            Results = sections.Select(SectionViewModel.Create).ToList();
            if (SectionParser.ParseBlocked(data) is { } blocked)
                ErrorMessage = $"Action impossible : {blocked}";

            var seconds = duration.TotalSeconds.ToString("0.0", CultureInfo.GetCultureInfo("fr-FR"));
            var subtitle = SectionParser.ParseSubtitle(data);
            Status = (dryRun ? "Simulation, rien n'a été modifié · " : string.Empty)
                     + (restorePoint is null ? string.Empty : $"point de restauration : {restorePoint} · ")
                     + (subtitle is null ? string.Empty : subtitle + " · ") + $"exécuté à {DateTime.Now:HH:mm:ss} en {seconds} s";

            foreach (var change in changes)
                activity.Log($"{change.Target} · {change.Property} : {change.Before ?? "—"} → {change.After ?? "—"}");
            foreach (var finding in findings)
                activity.Log($"{finding.Code} : {finding.Message}", finding.Severity == FindingSeverity.Info ? ActivityLineKind.Info : ActivityLineKind.Warning);
            var blockedReason = SectionParser.ParseBlocked(data);
            Finish(activity,
                blockedReason is not null || findings.Any(f => f.Severity != FindingSeverity.Info) ? ActivityState.Warning : ActivityState.Succeeded,
                blockedReason is not null ? $"Impossible : {blockedReason}" : subtitle);
        }
        catch (OperationCanceledException)
        {
            activity.AuditId = AuditLog.Write(audit with { Status = "cancelled" });
            Status = "Arrêté.";
            Finish(activity, ActivityState.Cancelled, null);
        }
        catch (Exception ex)
        {
            activity.AuditId = AuditLog.Write(audit with { Error = ex.Message });
            Status = null;
            ErrorMessage = ex.Message;
            Finish(activity, ActivityState.Failed, ex.Message);
        }
        finally
        {
            IsRunning = false;
            _cancel.Dispose();
            _cancel = null;
        }
    }

    private AuditEntry Audit(IReadOnlyDictionary<string, object?> arguments, bool dryRun) => new()
    {
        Origin = "ui",
        Tool = Mcp.ModuleTool.FunctionName(_runner.Module.Manifest, _function),
        Module = _runner.Module.Manifest.Id,
        Function = _function.Name,
        Level = _function.Level,
        Parameters = arguments,
        DryRun = dryRun,
        Status = "error",
    };
}
