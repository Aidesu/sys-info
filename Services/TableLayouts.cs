using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia.Threading;
using SysInfo.Models;

namespace SysInfo.Services;

/// <summary>
/// Column layout of the tables chosen by the user (widths, hidden columns), kept in settings.json and shared by every
/// table with the same title and columns (the « Processus » table looks the same wherever it appears).
/// Saved half a second after the last change.
/// </summary>
public static class TableLayouts
{
    private static AppSettings? _settings;
    private static DispatcherTimer? _save;

    /// <summary>Called at startup with the settings the window saves.</summary>
    public static void Use(AppSettings settings) => _settings = settings;

    public static string KeyOf(string title, IEnumerable<string> columns) => $"{title}|{string.Join("|", columns)}";

    public static TableLayout? Get(string key) =>
        _settings?.TableLayouts.TryGetValue(key, out var layout) == true ? layout : null;

    public static void Set(string key, TableLayout? layout)
    {
        if (_settings is null)
            return;
        if (layout is null || (layout.Widths.Count == 0 && layout.Hidden.Count == 0))
            _settings.TableLayouts.Remove(key);
        else
            _settings.TableLayouts[key] = layout;

        _save ??= new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, (_, _) =>
        {
            _save!.Stop();
            SettingsService.Save(_settings!);
        });
        _save.Stop();
        _save.Start();
    }
}
