using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using SysInfo.Models;

namespace SysInfo.Services;

/// <summary>
/// Audit log (Specifications.md, module 21): one JSON line per call of a module function from the MCP server or the
/// window's Outils card, and per action (levels A and C) with its confirmation and its changes. The automatic refresh
/// of the pages is not logged.
/// <para>
/// One file per month, audit-yyyy-MM.jsonl, in %LOCALAPPDATA%\SysInfo\audit (Windows) or ~/.local/share/SysInfo/audit
/// (Linux). The window and the MCP server can write at the same time: each line is written in one exclusive append,
/// retried while the other process holds the file. Writing never throws: a failure is reported on stderr.
/// </para>
/// </summary>
public static class AuditLog
{
    public static string Directory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SysInfo", "audit");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static readonly Lock Gate = new();

    /// <summary>Appends one entry; id, time, user and host are added here. Returns the entry id.</summary>
    public static string Write(AuditEntry entry)
    {
        var id = Guid.NewGuid().ToString("N")[..12];
        var json = new JsonObject
        {
            ["id"] = id,
            ["time"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture),
            ["origin"] = entry.Origin,
            ["client"] = entry.Client,
            ["user"] = Environment.UserName,
            ["host"] = Environment.MachineName,
            ["elevated"] = Environment.IsPrivilegedProcess,
            ["tool"] = entry.Tool,
            ["module"] = entry.Module,
            ["function"] = entry.Function,
            ["level"] = entry.Level.ToString(),
            ["parameters"] = entry.Parameters is null ? new JsonObject() : FunctionArguments.ToJson(entry.Parameters),
            ["dryRun"] = entry.DryRun,
            ["confirmation"] = entry.Confirmation,
            ["status"] = entry.Status,
            ["durationMs"] = entry.DurationMs,
            ["findings"] = new JsonArray([.. entry.Findings.Select(f => (JsonNode)f)]),
        };
        if (entry.Changes.Count > 0)
            json["changes"] = new JsonArray([.. entry.Changes.Select(c => (JsonNode)new JsonObject
            {
                ["target"] = c.Target, ["property"] = c.Property, ["before"] = c.Before, ["after"] = c.After,
            })]);
        if (entry.Undo is not null)
            json["undo"] = entry.Undo.DeepClone();
        if (entry.RestorePoint is not null)
            json["restorePoint"] = entry.RestorePoint;
        if (entry.JobId is not null)
            json["jobId"] = entry.JobId;
        if (entry.Error is not null)
            json["error"] = entry.Error;

        var line = json.ToJsonString(JsonOptions) + "\n";
        var path = Path.Combine(Directory, $"audit-{DateTime.Now:yyyy-MM}.jsonl");

        lock (Gate)
        {
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    System.IO.Directory.CreateDirectory(Directory);
                    using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
                    var bytes = Encoding.UTF8.GetBytes(line);
                    stream.Write(bytes);
                    return id;
                }
                catch (IOException) when (attempt < 20)
                {
                    // The other process (window or MCP server) is appending: wait a little.
                    Thread.Sleep(25);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    Console.Error.WriteLine($"[audit] impossible d'écrire dans {path} : {ex.Message}");
                    return id;
                }
            }
        }
    }

    /// <summary>
    /// The last <paramref name="max"/> entries (this month and the previous one), newest first. Shared read: the
    /// window and the MCP server may be writing. An unreadable line is skipped.
    /// </summary>
    public static IReadOnlyList<JsonObject> ReadRecent(int max)
    {
        var entries = new List<JsonObject>();
        foreach (var month in new[] { DateTime.Now, DateTime.Now.AddMonths(-1) })
        {
            var path = Path.Combine(Directory, $"audit-{month:yyyy-MM}.jsonl");
            if (!File.Exists(path))
                continue;
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var reader = new StreamReader(stream, Encoding.UTF8);
                var lines = new List<string>();
                while (reader.ReadLine() is { } line)
                    lines.Add(line);
                for (var i = lines.Count - 1; i >= 0 && entries.Count < max; i--)
                {
                    try
                    {
                        if (JsonNode.Parse(lines[i]) is JsonObject entry)
                            entries.Add(entry);
                    }
                    catch (JsonException)
                    {
                    }
                }
            }
            catch (IOException ex)
            {
                Console.Error.WriteLine($"[audit] lecture impossible de {path} : {ex.Message}");
            }
            if (entries.Count >= max)
                break;
        }
        return entries;
    }

    /// <summary>Deletes the monthly files whose last entry is older than <paramref name="days"/> days (0 = keep all).</summary>
    public static void Purge(int days)
    {
        if (days <= 0 || !System.IO.Directory.Exists(Directory))
            return;
        try
        {
            var limit = DateTime.Now.AddDays(-days);
            foreach (var file in System.IO.Directory.EnumerateFiles(Directory, "audit-*.jsonl"))
            {
                if (File.GetLastWriteTime(file) < limit)
                    File.Delete(file);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"[audit] purge impossible : {ex.Message}");
        }
    }

    /// <summary>Status of a result: its worst finding, as in the MCP envelope.</summary>
    public static string StatusOf(IReadOnlyList<Finding> findings) =>
        findings.Select(f => f.Severity).DefaultIfEmpty(FindingSeverity.Info).Max() switch
        {
            FindingSeverity.Critical => "critical",
            FindingSeverity.Warning => "warning",
            _ => "ok",
        };
}

/// <summary>
/// One line of the audit log.
/// Origin: "ui" or "mcp". Confirmation: "not-required" (read, preview), "confirmed", "declined", "timeout",
/// "unavailable". Status: ok, warning, critical (worst finding), error, declined, cancelled, running (long task started).
/// </summary>
public sealed record AuditEntry
{
    public required string Origin { get; init; }
    public string? Client { get; init; }
    public required string Tool { get; init; }
    public required string Module { get; init; }
    public required string Function { get; init; }
    public AccessLevel Level { get; init; }
    public IReadOnlyDictionary<string, object?>? Parameters { get; init; }
    public bool DryRun { get; init; }
    public string Confirmation { get; init; } = "not-required";
    public required string Status { get; init; }
    public long DurationMs { get; init; }
    public IReadOnlyList<string> Findings { get; init; } = [];
    public IReadOnlyList<Change> Changes { get; init; } = [];
    public string? JobId { get; init; }
    public string? Error { get; init; }

    /// <summary>How to undo the action: { tool, function, parameters } (the action's Undo), replayed by audit_undo.</summary>
    public JsonObject? Undo { get; init; }

    /// <summary>Restore point taken before a critical action (or why none was).</summary>
    public string? RestorePoint { get; init; }
}
