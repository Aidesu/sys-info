using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using SysInfo.Models;

namespace SysInfo.ViewModels.Tools;

/// <summary>
/// One field of a function's form, generated from module.json: a text box, a number box, a check box or a list.
/// </summary>
public partial class FunctionParameterViewModel : ViewModelBase
{
    private readonly FunctionParameter _parameter;

    public FunctionParameterViewModel(FunctionParameter parameter)
    {
        _parameter = parameter;
        Options = parameter.Enum;

        if (parameter.Default is { } value)
        {
            switch (value.ValueKind)
            {
                case JsonValueKind.Number:
                    Number = value.GetDecimal();
                    break;
                case JsonValueKind.True or JsonValueKind.False:
                    Flag = value.GetBoolean();
                    break;
                case JsonValueKind.String:
                    Text = value.GetString() ?? string.Empty;
                    Choice = value.GetString();
                    break;
            }
        }
        Choice ??= Options.FirstOrDefault();
    }

    public string Name => _parameter.Name;

    public string Label => (_parameter.Label ?? _parameter.Name) + (_parameter.Required ? " *" : string.Empty);

    public bool IsChoice => Options.Count > 0;
    public bool IsText => _parameter.Type == ParameterType.String && !IsChoice;
    public bool IsNumber => _parameter.Type is ParameterType.Integer or ParameterType.Number;
    public bool IsFlag => _parameter.Type == ParameterType.Boolean;

    public IReadOnlyList<string> Options { get; }

    public decimal Minimum => _parameter.Minimum is { } min ? (decimal)min : decimal.MinValue;
    public decimal Maximum => _parameter.Maximum is { } max ? (decimal)max : decimal.MaxValue;
    public int Decimals => _parameter.Type == ParameterType.Integer ? 0 : 2;
    public decimal Increment => _parameter.Type == ParameterType.Integer ? 1 : 0.1m;

    [ObservableProperty]
    public partial string Text { get; set; } = string.Empty;

    [ObservableProperty]
    public partial decimal? Number { get; set; }

    [ObservableProperty]
    public partial bool Flag { get; set; }

    [ObservableProperty]
    public partial string? Choice { get; set; }

    /// <summary>
    /// The value to pass to PowerShell, or null when the field is empty (the function's default applies).
    /// Throws <see cref="ArgumentException"/> with a French message when a required field is empty.
    /// </summary>
    public object? GetValue()
    {
        object? value = _parameter.Type switch
        {
            ParameterType.Boolean => Flag,
            ParameterType.Integer => Number is { } n ? (long)n : null,
            ParameterType.Number => Number is { } d ? (double)d : null,
            _ when IsChoice => Choice,
            _ => string.IsNullOrWhiteSpace(Text) ? null : Text.Trim(),
        };

        if (value is null && _parameter.Required)
            throw new ArgumentException(string.Format(CultureInfo.CurrentCulture, "« {0} » est obligatoire.", _parameter.Label ?? _parameter.Name));
        return value;
    }
}
