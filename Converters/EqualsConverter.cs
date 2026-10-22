using System;
using System.Globalization;
using Avalonia.Data;
using Avalonia.Data.Converters;

namespace SysInfo.Converters;

/// <summary>
/// Binds a group of exclusive options (RadioButton.IsChecked) to one string property:
/// checked when the value equals the parameter; checking an option writes its parameter back.
/// </summary>
public sealed class EqualsConverter : IValueConverter
{
    public static EqualsConverter Instance { get; } = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        Equals(value?.ToString(), parameter?.ToString());

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is true ? parameter?.ToString() : BindingOperations.DoNothing;
}
