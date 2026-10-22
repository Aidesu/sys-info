using Avalonia;
using Avalonia.Media;
using System;

namespace SysInfo;

sealed class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called: things aren't initialized
    // yet and stuff might break.
    [STAThread]
    public static void Main(string[] args) => BuildAvaloniaApp()
        .StartWithClassicDesktopLifetime(args);

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
