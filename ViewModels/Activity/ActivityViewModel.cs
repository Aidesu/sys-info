using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;
using SysInfo.Services;

namespace SysInfo.ViewModels.Activity;

/// <summary>
/// Activité page (sidebar, above Paramètres): what SysInfo is doing now and what it did.
///   En cours    the functions started from the window, with their live log and progress, and the long tasks an
///               AI agent started over MCP (read from the audit log, without their log: it runs in another process);
///   Historique  the audit log (window and MCP, last 200 entries), each with its details, and the live log of the runs
///               of this session.
/// The automatic refresh of the pages is not shown. The sidebar entry shows how many tasks are running.
/// </summary>
public partial class ActivityViewModel : NavPageViewModel
{
    private const int HistorySize = 200;

    private readonly Dictionary<string, string> _titles;
    private readonly DispatcherTimer _clock;
    private readonly DispatcherTimer _reload;
    private readonly FileSystemWatcher? _watcher;

    public ActivityViewModel(IReadOnlyList<LoadedModule> modules)
    {
        // Tool name → « Module · Fonction », for the history lines written by the MCP server.
        _titles = modules
            .SelectMany(m => m.Functions.Select(f => (Tool: Mcp.ModuleTool.FunctionName(m.Manifest, f), Title: $"{m.Manifest.Title} · {f.Title ?? f.Name}"))
                .Prepend((Tool: Mcp.ModuleTool.OverviewName(m.Manifest), Title: $"{m.Manifest.Title} · vue d'ensemble")))
            .GroupBy(t => t.Tool)
            .ToDictionary(g => g.Key, g => g.First().Title);

        _clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _clock.Tick += (_, _) =>
        {
            foreach (var record in Running)
                record.Tick();
            foreach (var external in External)
                external.Tick();
        };
        _clock.Start();

        // The MCP server writes to the same audit log: reload shortly after a change.
        _reload = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        _reload.Tick += (_, _) =>
        {
            _reload.Stop();
            LoadHistory();
        };
        try
        {
            Directory.CreateDirectory(AuditLog.Directory);
            _watcher = new FileSystemWatcher(AuditLog.Directory, "audit-*.jsonl") { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size };
            _watcher.Changed += (_, _) => Dispatcher.UIThread.Post(ScheduleReload);
            _watcher.Created += (_, _) => Dispatcher.UIThread.Post(ScheduleReload);
            _watcher.EnableRaisingEvents = true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            Console.Error.WriteLine($"[activité] suivi du journal impossible : {ex.Message}");
        }

        LoadHistory();
    }

    /// <summary>Shared by the Outils cards of every module.</summary>
    public static ActivityViewModel? Current { get; set; }

    public override string Title => "Activité";
    public override string Icon => "pulse";

    /// <summary>Runs started from the window that are not over.</summary>
    public ObservableCollection<ActivityRecordViewModel> Running { get; } = [];

    /// <summary>Long tasks started by an AI agent (MCP) that are not over.</summary>
    public ObservableCollection<ExternalTaskViewModel> External { get; } = [];

    /// <summary>The audit log, newest first.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasHistory))]
    public partial IReadOnlyList<HistoryItemViewModel> History { get; private set; } = [];

    public bool HasHistory => History.Count > 0;

    public int RunningCount => Running.Count + External.Count;

    public bool HasRunning => RunningCount > 0;

    public string RunningText => RunningCount switch
    {
        0 => "Rien en cours",
        1 => "1 tâche en cours",
        var n => $"{n} tâches en cours",
    };

    // Runs of this session, by audit id, to show their live log in the history.
    private readonly Dictionary<string, ActivityRecordViewModel> _session = [];

    /// <summary>Starts following a run of the Outils card.</summary>
    public ActivityRecordViewModel Start(string title, string module, string tool, AccessLevel level, bool dryRun, Action? cancel)
    {
        var record = new ActivityRecordViewModel(title, module, tool, level, dryRun, cancel);
        Running.Insert(0, record);
        UpdateBadge();
        return record;
    }

    /// <summary>The run is over: it leaves « En cours » and its audit line (if any) gets its log.</summary>
    public void Finish(ActivityRecordViewModel record, ActivityState state, string? summary)
    {
        record.Complete(state, summary);
        Running.Remove(record);
        if (record.AuditId is { } id)
            _session[id] = record;
        UpdateBadge();
        ScheduleReload();
    }

    [RelayCommand]
    private void Reload() => LoadHistory();

    private void ScheduleReload()
    {
        _reload.Stop();
        _reload.Start();
    }

    private void LoadHistory()
    {
        var entries = AuditLog.ReadRecent(HistorySize);

        // A long task started over MCP is running while its start line has no end line (same jobId).
        var ended = entries.Where(e => e["status"]?.GetValue<string>() != "running")
            .Select(e => e["jobId"]?.GetValue<string>()).Where(j => j is not null).ToHashSet();
        var running = entries
            .Where(e => e["status"]?.GetValue<string>() == "running" && e["origin"]?.GetValue<string>() == "mcp"
                        && e["jobId"]?.GetValue<string>() is { } job && !ended.Contains(job))
            .Where(e => DateTime.UtcNow - Time(e) < TimeSpan.FromHours(6)) // server killed meanwhile: forget it
            .ToList();

        External.Clear();
        foreach (var e in running)
            External.Add(new ExternalTaskViewModel(TitleOf(e), e["client"]?.GetValue<string>(), Time(e).ToLocalTime()));

        History = entries
            .Where(e => e["status"]?.GetValue<string>() != "running")
            .Select(e => new HistoryItemViewModel(e, TitleOf(e), e["id"]?.GetValue<string>() is { } id && _session.TryGetValue(id, out var r) ? r : null))
            .ToList();
        UpdateBadge();
    }

    private string TitleOf(JsonObject entry)
    {
        var tool = entry["tool"]?.GetValue<string>() ?? "?";
        return _titles.TryGetValue(tool, out var title) ? title : tool;
    }

    private static DateTime Time(JsonObject entry) =>
        DateTime.TryParse(entry["time"]?.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var t)
            ? t : DateTime.UtcNow;

    private void UpdateBadge()
    {
        OnPropertyChanged(nameof(RunningCount));
        OnPropertyChanged(nameof(HasRunning));
        OnPropertyChanged(nameof(RunningText));
        Badge = RunningCount > 0 ? RunningCount.ToString(CultureInfo.CurrentCulture) : null;
    }

    public void Dispose()
    {
        _clock.Stop();
        _reload.Stop();
        _watcher?.Dispose();
    }
}

/// <summary>A long task started by an AI agent over MCP, still running in the server.</summary>
public partial class ExternalTaskViewModel(string title, string? client, DateTime startedAt) : ViewModelBase
{
    public string Title { get; } = title;
    public string Origin { get; } = $"Agent IA{(string.IsNullOrWhiteSpace(client) ? string.Empty : $" · {client}")}";
    public string StartedText { get; } = startedAt.ToString("HH:mm:ss", CultureInfo.CurrentCulture);

    [ObservableProperty]
    public partial string ElapsedText { get; private set; } = ActivityRecordViewModel.Format(DateTime.Now - startedAt);

    internal void Tick() => ElapsedText = ActivityRecordViewModel.Format(DateTime.Now - startedAt);
}

/// <summary>One line of the audit log, with its details (and the live log of this session's runs).</summary>
public partial class HistoryItemViewModel : ViewModelBase
{
    public HistoryItemViewModel(JsonObject entry, string title, ActivityRecordViewModel? session)
    {
        string? Get(string name) => entry[name] is JsonValue v ? v.ToString() : null;

        Title = title;
        Tool = Get("tool") ?? string.Empty;
        var time = DateTime.TryParse(Get("time"), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var t)
            ? t.ToLocalTime() : DateTime.Now;
        TimeText = time.Date == DateTime.Today ? time.ToString("HH:mm:ss", CultureInfo.CurrentCulture) : time.ToString("dd/MM HH:mm", CultureInfo.CurrentCulture);
        Origin = Get("origin") == "mcp" ? $"Agent IA{(Get("client") is { Length: > 0 } c ? $" · {c}" : string.Empty)}" : "Fenêtre";
        var level = Get("level");
        var dryRun = entry["dryRun"]?.GetValue<bool>() == true;
        Kind = dryRun ? "Simulation" : level switch { "C" => "Action critique", "A" => "Action", _ => "Consultation" };
        IsAction = level is "A" or "C" && !dryRun;

        var status = Get("status");
        var confirmation = Get("confirmation");
        StatusText = (status, confirmation) switch
        {
            (_, "declined") => "Refusé",
            (_, "timeout") => "Sans réponse",
            (_, "unavailable") => "Confirmation impossible",
            ("ok", _) => "Terminé",
            ("warning", _) => "Constats : attention",
            ("critical", _) => "Constats : critique",
            ("error", _) => "Échec",
            ("blocked", _) => "Impossible",
            ("cancelled", _) => "Arrêté",
            _ => status ?? string.Empty,
        };
        IsFailed = status is "error" || confirmation is "unavailable";
        IsWarning = status is "warning" or "critical" or "blocked" or "cancelled" || confirmation is "declined" or "timeout";
        DurationText = !long.TryParse(Get("durationMs"), out var ms) || ms <= 0 ? string.Empty
            : ms < 1000 ? $"{ms} ms"
            : ActivityRecordViewModel.Format(TimeSpan.FromMilliseconds(ms));

        var details = new List<KeyValueItem>();
        if (entry["parameters"] is JsonObject parameters && parameters.Count > 0)
            details.Add(new("Paramètres", string.Join(", ", parameters.Select(p => $"{p.Key} = {p.Value}"))));
        if (confirmation is { Length: > 0 } and not "not-required")
            details.Add(new("Confirmation", confirmation switch { "confirmed" => "confirmée", "declined" => "refusée", "timeout" => "sans réponse", _ => "impossible" }));
        if (entry["changes"] is JsonArray changes && changes.Count > 0)
            details.Add(new("Modifications", string.Join("\n", changes.OfType<JsonObject>().Select(c => $"{c["target"]} · {c["property"]} : {c["before"]} → {c["after"]}"))));
        if (entry["findings"] is JsonArray findings && findings.Count > 0)
            details.Add(new("Constats", string.Join(", ", findings.Select(f => f?.ToString()))));
        if (Get("restorePoint") is { Length: > 0 } restore)
            details.Add(new("Point de restauration", restore));
        if (entry["undo"] is JsonObject undo)
            details.Add(new("Annulable", $"audit_undo, id {Get("id")} ({undo["tool"]})"));
        if (Get("error") is { Length: > 0 } error)
            details.Add(new("Erreur", error));
        details.Add(new("Compte", $"{Get("user")}{(entry["elevated"]?.GetValue<bool>() == true ? " (administrateur)" : string.Empty)}"));
        details.Add(new("Outil", Tool));
        Details = details;
        Lines = session?.Lines;
    }

    public string Title { get; }
    public string Tool { get; }
    public string TimeText { get; }
    public string Origin { get; }
    public string Kind { get; }
    public bool IsAction { get; }
    public string StatusText { get; }
    public bool IsFailed { get; }
    public bool IsWarning { get; }
    public string DurationText { get; }
    public IReadOnlyList<KeyValueItem> Details { get; }

    /// <summary>Live log, for the runs of this session.</summary>
    public ObservableCollection<ActivityLine>? Lines { get; }

    public bool HasLines => Lines is { Count: > 0 };

    [ObservableProperty]
    public partial bool IsExpanded { get; set; }

    [RelayCommand]
    private void Toggle() => IsExpanded = !IsExpanded;
}
