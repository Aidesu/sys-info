// Copie, compilée avec l'application, de la classe que Modules/Storage/Storage.psm1 compile avec Add-Type quand il
// tourne seul dans pwsh. Dans SysInfo, le module la trouve déjà chargée et saute Add-Type : pas de compilateur C#
// (Roslyn, ~70 Mio) chargé dans le runspace. Garder les deux copies identiques.
#nullable disable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace SysInfo.Storage
{
    public sealed class SizedEntry
    {
        public string Path;
        public long Bytes;
        public long Files;
    }

    public sealed class SizeReport
    {
        public List<SizedEntry> Folders = new List<SizedEntry>();
        public List<SizedEntry> LargestFiles = new List<SizedEntry>();
        public long TotalBytes;
        public long TotalFiles;
        public bool TimedOut;
    }

    public static class DirectorySizer
    {
        public static SizeReport Analyze(string root, int topFiles, int timeoutMs, string[] excluded)
        {
            var report = new SizeReport();
            var watch = Stopwatch.StartNew();
            var skip = new HashSet<string>(excluded ?? new string[0], StringComparer.Ordinal);
            var largest = new SortedSet<(long, string)>();
            var options = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint, RecurseSubdirectories = false };

            // Fichiers directement à la racine : comptés dans le total, comme une pseudo-entrée.
            var rootFiles = new SizedEntry { Path = Path.Combine(root, "(fichiers à la racine)") };
            foreach (var file in new DirectoryInfo(root).EnumerateFiles("*", options)) { Add(file, rootFiles, largest, topFiles); }
            if (rootFiles.Files > 0) report.Folders.Add(rootFiles);

            foreach (var dir in new DirectoryInfo(root).EnumerateDirectories("*", options))
            {
                if (skip.Contains(dir.FullName)) continue;
                var entry = new SizedEntry { Path = dir.FullName };
                var stack = new Stack<DirectoryInfo>();
                stack.Push(dir);
                while (stack.Count > 0)
                {
                    if (watch.ElapsedMilliseconds > timeoutMs) { report.TimedOut = true; break; }
                    var current = stack.Pop();
                    try
                    {
                        foreach (var file in current.EnumerateFiles("*", options)) Add(file, entry, largest, topFiles);
                        foreach (var sub in current.EnumerateDirectories("*", options)) if (!skip.Contains(sub.FullName)) stack.Push(sub);
                    }
                    catch (Exception) { }
                }
                report.Folders.Add(entry);
                if (report.TimedOut) break;
            }

            foreach (var f in report.Folders) { report.TotalBytes += f.Bytes; report.TotalFiles += f.Files; }
            report.Folders.Sort((a, b) => b.Bytes.CompareTo(a.Bytes));
            foreach (var item in largest.Reverse()) report.LargestFiles.Add(new SizedEntry { Path = item.Item2, Bytes = item.Item1, Files = 1 });
            return report;
        }

        private static void Add(FileInfo file, SizedEntry entry, SortedSet<(long, string)> largest, int top)
        {
            long length;
            try { length = file.Length; } catch (Exception) { return; }
            entry.Bytes += length;
            entry.Files++;
            if (top <= 0) return;
            if (largest.Count < top) { largest.Add((length, file.FullName)); }
            else if (length > largest.Min.Item1) { largest.Remove(largest.Min); largest.Add((length, file.FullName)); }
        }

        // Taille d'un seul dossier (récursive), 0 s'il n'existe pas.
        public static long Size(string path, int timeoutMs)
        {
            if (!Directory.Exists(path)) return 0;
            var parent = Path.GetDirectoryName(path.TrimEnd(Path.DirectorySeparatorChar)) ?? path;
            var options = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint, RecurseSubdirectories = true };
            long total = 0;
            var watch = Stopwatch.StartNew();
            try
            {
                foreach (var file in new DirectoryInfo(path).EnumerateFiles("*", options))
                {
                    try { total += file.Length; } catch (Exception) { }
                    if (watch.ElapsedMilliseconds > timeoutMs) break;
                }
            }
            catch (Exception) { }
            return total;
        }
    }
}
