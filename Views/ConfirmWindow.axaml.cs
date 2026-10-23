using System;
using Avalonia.Controls;
using SysInfo.ViewModels;

namespace SysInfo.Views;

/// <summary>
/// Window of a <see cref="ConfirmViewModel"/>: computes the preview once shown, closes on the answer, and declines
/// when closed without one.
/// </summary>
public partial class ConfirmWindow : Window
{
    public ConfirmWindow()
    {
        InitializeComponent();
    }

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (DataContext is ConfirmViewModel vm)
            vm.Closed += (_, _) => Close();
    }

    protected override async void OnOpened(EventArgs e)
    {
        base.OnOpened(e);
        Activate();
        if (DataContext is ConfirmViewModel vm)
            await vm.LoadAsync();
    }

    protected override void OnClosed(EventArgs e)
    {
        (DataContext as ConfirmViewModel)?.Finish(ConfirmAnswer.Declined);
        base.OnClosed(e);
    }
}
