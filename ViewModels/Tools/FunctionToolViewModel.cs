using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Management.Automation;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using SysInfo.Models;
using SysInfo.Services;
using SysInfo.ViewModels.Sections;

namespace SysInfo.ViewModels.Tools;

/// <summary>
/// A targeted function of the module in the window's Outils card: its form, a Run button and its result
/// (same Sections and Findings as the MCP tool &lt;id&gt;_&lt;name&gt;, rendered with the page's section views).
/// </summary>
public partial class FunctionToolViewModel : ViewModelBase
{
    private readonly ModuleFunction _function;
    private readonly Func<string, IReadOnlyDictionary<string, object?>, Task<PSObject>> _invoke;

    public FunctionToolViewModel(ModuleFunction function, Func<string, IReadOnlyDictionary<string, object?>, Task<PSObject>> invoke)
    {
        _function = function;
        _invoke = invoke;
        Parameters = function.Parameters.Select(p => new FunctionParameterViewModel(p)).ToList();
    }

    public string Title => _function.Title ?? _function.Name;

    public IReadOnlyList<FunctionParameterViewModel> Parameters { get; }

    public bool HasParameters => Parameters.Count > 0;

    /// <summary>Expander state, kept while the page is rebuilt.</summary>
    [ObservableProperty]
    public partial bool IsExpanded { get; set; }

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

    [RelayCommand]
    private async Task RunAsync()
    {
        Dictionary<string, object?> arguments;
        try
        {
            arguments = Parameters
                .Select(p => (p.Name, Value: p.GetValue()))
                .Where(p => p.Value is not null)
                .ToDictionary(p => p.Name, p => p.Value);
        }
        catch (ArgumentException ex)
        {
            ErrorMessage = ex.Message;
            return;
        }

        ErrorMessage = null;
        Status = "En cours…";
        var watch = Stopwatch.StartNew();
        try
        {
            var data = await _invoke(_function.Command, arguments);
            watch.Stop();
            Findings = SectionParser.ParseFindings(data);
            Results = SectionParser.Parse(data).Select(SectionViewModel.Create).ToList();
            var duration = watch.Elapsed.TotalSeconds.ToString("0.0", CultureInfo.GetCultureInfo("fr-FR"));
            var subtitle = SectionParser.ParseSubtitle(data);
            Status = (subtitle is null ? string.Empty : subtitle + " · ") + $"exécuté à {DateTime.Now:HH:mm:ss} en {duration} s";
        }
        catch (Exception ex)
        {
            Status = null;
            ErrorMessage = ex.Message;
        }
    }
}
