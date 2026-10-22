using System;
using System.Globalization;
using Avalonia;
using Avalonia.Data.Converters;
using Avalonia.Media;

namespace SysInfo.Converters;

/// <summary>
/// Turns an icon name from module.json ("settings") into its geometry (resource Icon.settings, Styles/Icons.axaml).
/// Unknown name → the "board" icon, and a warning on stderr.
/// </summary>
public sealed class IconConverter : IValueConverter
{
    public static IconConverter Instance { get; } = new();

    private const string Fallback = "board";

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var name = value as string;
        if (!string.IsNullOrEmpty(name) && TryFind(name, out var geometry))
            return geometry;

        Console.Error.WriteLine($"[icons] icône inconnue « {name} », remplacée par « {Fallback} »");
        return TryFind(Fallback, out var fallback) ? fallback : null;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();

    private static bool TryFind(string name, out Geometry? geometry)
    {
        geometry = null;
        if (Application.Current?.TryGetResource($"Icon.{name}", null, out var resource) == true && resource is Geometry g)
            geometry = g;
        return geometry is not null;
    }
}
