using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using SysInfo.ViewModels;
using SysInfo.Views;

namespace SysInfo.Services;

/// <summary>Opens the window's dialogs from the view models.</summary>
public static class DialogService
{
    /// <summary>Shows the confirmation of an action over the main window and returns the answer.</summary>
    public static async Task<ConfirmAnswer> ConfirmAsync(ConfirmViewModel viewModel)
    {
        var window = new ConfirmWindow { DataContext = viewModel, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        if ((Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow is { } owner)
            await window.ShowDialog(owner);
        else
            window.Show();
        return await viewModel.Answer;
    }
}
