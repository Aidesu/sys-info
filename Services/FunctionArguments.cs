using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using SysInfo.Models;

namespace SysInfo.Services;

/// <summary>
/// Arguments of a module function: checked against module.json (type, enum, bounds, unknown names) and converted to
/// the .NET types PowerShell expects. Shared by the MCP tools, the confirmation window and the audit log.
/// </summary>
public static class FunctionArguments
{
    /// <summary>Reserved argument of actions (levels A and C): preview only, nothing is changed.</summary>
    public const string DryRun = "dryRun";

    /// <summary>
    /// Checks each JSON argument and converts it. Throws <see cref="ArgumentException"/> with an English message
    /// (read by the AI) on an unknown argument, a wrong type, a value outside the enum or the bounds, or a missing
    /// required one. Names listed in <paramref name="extra"/> are accepted and left out of the result.
    /// </summary>
    public static Dictionary<string, object?> Bind(
        IReadOnlyList<FunctionParameter> parameters, IDictionary<string, JsonElement>? arguments, params string[] extra)
    {
        var bound = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        arguments ??= new Dictionary<string, JsonElement>();

        foreach (var name in arguments.Keys)
        {
            if (!parameters.Any(p => p.Name.Equals(name, StringComparison.Ordinal)) && !extra.Contains(name, StringComparer.Ordinal))
                throw new ArgumentException($"unknown argument '{name}'" +
                    (parameters.Count > 0 ? $" (expected: {string.Join(", ", parameters.Select(p => p.Name).Concat(extra))})" : " (this tool takes no arguments)"));
        }

        foreach (var parameter in parameters)
        {
            if (!arguments.TryGetValue(parameter.Name, out var value) || value.ValueKind == JsonValueKind.Null)
            {
                if (parameter.Required)
                    throw new ArgumentException($"'{parameter.Name}' is required");
                continue;
            }

            object converted = parameter.Type switch
            {
                ParameterType.Integer when value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var i) => i,
                ParameterType.Number when value.ValueKind == JsonValueKind.Number => value.GetDouble(),
                ParameterType.Boolean when value.ValueKind is JsonValueKind.True or JsonValueKind.False => value.GetBoolean(),
                ParameterType.String when value.ValueKind == JsonValueKind.String => value.GetString()!,
                _ => throw new ArgumentException($"'{parameter.Name}' must be of type {parameter.Type.ToString().ToLowerInvariant()}"),
            };

            if (parameter.Enum.Count > 0 && !parameter.Enum.Contains((string)converted, StringComparer.Ordinal))
                throw new ArgumentException($"'{parameter.Name}' must be one of: {string.Join(", ", parameter.Enum)}");

            if (converted is long or double)
            {
                var number = Convert.ToDouble(converted, CultureInfo.InvariantCulture);
                if (parameter.Minimum is { } min && number < min)
                    throw new ArgumentException($"'{parameter.Name}' must be ≥ {min.ToString(CultureInfo.InvariantCulture)}");
                if (parameter.Maximum is { } max && number > max)
                    throw new ArgumentException($"'{parameter.Name}' must be ≤ {max.ToString(CultureInfo.InvariantCulture)}");
            }

            bound[parameter.Name] = converted;
        }

        return bound;
    }

    /// <summary>Bound arguments as JSON (audit log, confirmation request).</summary>
    public static JsonObject ToJson(IReadOnlyDictionary<string, object?> arguments)
    {
        var json = new JsonObject();
        foreach (var (name, value) in arguments)
        {
            json[name] = value switch
            {
                null => null,
                bool b => JsonValue.Create(b),
                long l => JsonValue.Create(l),
                double d => JsonValue.Create(d),
                _ => JsonValue.Create(value.ToString()),
            };
        }
        return json;
    }

    /// <summary>Same arguments read back from JSON (confirmation request written by the MCP server).</summary>
    public static Dictionary<string, object?> FromJson(IReadOnlyList<FunctionParameter> parameters, JsonObject? json)
    {
        var elements = new Dictionary<string, JsonElement>();
        foreach (var (name, node) in json ?? [])
            elements[name] = node is null ? default : JsonSerializer.SerializeToElement(node);
        return Bind(parameters, elements.Where(e => e.Value.ValueKind != JsonValueKind.Undefined).ToDictionary());
    }

    /// <summary>A value as shown to the user (« Oui », « 1 234 », text).</summary>
    public static string Display(object? value) => value switch
    {
        null => "—",
        bool b => b ? "Oui" : "Non",
        long l => l.ToString("N0", CultureInfo.GetCultureInfo("fr-FR")),
        double d => d.ToString("0.##", CultureInfo.GetCultureInfo("fr-FR")),
        _ => value.ToString() ?? string.Empty,
    };
}
