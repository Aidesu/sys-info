using System;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Threading;
using SysInfo.Services;
using SysInfo.ViewModels;
using SysInfo.Views;

namespace SysInfo;

/// <summary>
/// `SysInfo --confirm &lt;request.json&gt;`: the confirmation window of an action requested over MCP
/// (see Mcp/ConfirmationProcess.cs). Reads the request (module, function, parameters, client, timeout), computes the
/// preview itself with the module's -DryRun, then writes the answer on stdout (confirmed, declined or timeout) and
/// exits with 0 (confirmed), 1 (declined), 2 (timeout) or 3 (invalid request).
/// </summary>
public static class ConfirmLauncher
{
    public static void Start(IClassicDesktopStyleApplicationLifetime desktop, string requestPath)
    {
        ConfirmViewModel viewModel;
        ModuleRunner runner;
        try
        {
            var request = JsonNode.Parse(File.ReadAllText(requestPath)) as JsonObject
                ?? throw new InvalidDataException("demande vide");
            var moduleId = request["module"]?.GetValue<string>();
            var functionName = request["function"]?.GetValue<string>();

            var module = ModuleLoader.Load(ModuleLoader.DefaultModulesDirectory).Modules.FirstOrDefault(m => m.Manifest.Id == moduleId)
                ?? throw new InvalidDataException($"module « {moduleId} » introuvable");
            var function = module.Functions.FirstOrDefault(f => f.Name == functionName && f.IsAction)
                ?? throw new InvalidDataException($"action « {functionName} » introuvable dans {moduleId}");
            var arguments = FunctionArguments.FromJson(function.Parameters, request["parameters"] as JsonObject);
            var client = request["client"]?.GetValue<string>();
            var timeout = request["timeoutSeconds"]?.GetValue<int>() ?? 120;

            runner = new ModuleRunner(module);
            var origin = $"Demandée par {(string.IsNullOrWhiteSpace(client) ? "un agent IA" : client)} (MCP), " +
                         $"exécutée sous le compte {Environment.UserName}" +
                         (Environment.IsPrivilegedProcess ? " avec les droits administrateur." : ".");
            viewModel = new ConfirmViewModel(module, function, arguments, origin,
                async token => (await runner.InvokeAsync(function, arguments, dryRun: true, token)).Data, timeout);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[confirm] demande invalide : {ex.Message}");
            Console.Out.WriteLine("error");
            Environment.Exit(3);
            return;
        }

        desktop.MainWindow = new ConfirmWindow { DataContext = viewModel, Topmost = true };
        viewModel.Answer.ContinueWith(task => Dispatcher.UIThread.Post(() =>
        {
            var (text, code) = task.Result switch
            {
                ConfirmAnswer.Confirmed => ("confirmed", 0),
                ConfirmAnswer.TimedOut => ("timeout", 2),
                _ => ("declined", 1),
            };
            Console.Out.WriteLine(text);
            Console.Out.Flush();
            runner.Dispose();
            desktop.Shutdown(code);
        }));
    }
}
