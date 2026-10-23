using Avalonia;
using Avalonia.Media;
using System;
using System.Linq;

namespace SysInfo;

sealed class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called: things aren't initialized
    // yet and stuff might break.
    [STAThread]
    public static int Main(string[] args)
    {
        // `SysInfo --mcp`: MCP server on stdin/stdout for AI agents, no window.
        if (args.Contains("--mcp"))
            return Mcp.McpServerHost.RunAsync().GetAwaiter().GetResult();

        // `SysInfo --confirm <request.json>`: confirmation window of an action asked by the MCP server.
        var confirm = Array.IndexOf(args, "--confirm");
        if (confirm >= 0)
        {
            App.ConfirmRequestPath = args.ElementAtOrDefault(confirm + 1) ?? string.Empty;
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args, Avalonia.Controls.ShutdownMode.OnExplicitShutdown);
        }

        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
#if DEBUG
            .WithDeveloperTools()
#endif
            // IBM Plex Sans (Assets/Fonts) is the default font of every control, Fluent ones included
            .With(new FontManagerOptions { DefaultFamilyName = "avares://SysInfo/Assets/Fonts#IBM Plex Sans" })
            .LogToTrace();
}
