using System;
using System.Collections;
using System.Globalization;
using System.Linq;
using System.Management.Automation;
using System.Text.Json.Nodes;

namespace SysInfo.Mcp;

/// <summary>
/// Converts what Get-ModuleData returns into JSON, keeping the contract's structure and raw values
/// (numbers stay numbers, unformatted): the AI gets exactly what the module produced.
/// </summary>
public static class PsJson
{
    private const int MaxDepth = 10;

    public static JsonNode? ToJson(object? value, int depth = 0)
    {
        if (value is PSObject ps)
        {
            // PSCustomObject: its note properties; anything else: the wrapped .NET object.
            if (ps.BaseObject is PSCustomObject)
                return ToObject(ps, depth);
            value = ps.BaseObject;
        }

        if (depth > MaxDepth)
            return JsonValue.Create(value?.ToString());

        return value switch
        {
            null => null,
            string s => JsonValue.Create(s),
            bool b => JsonValue.Create(b),
            byte or sbyte or short or ushort or int or uint or long or ulong => JsonValue.Create(Convert.ToInt64(value, CultureInfo.InvariantCulture)),
            float or double or decimal => JsonValue.Create(Convert.ToDouble(value, CultureInfo.InvariantCulture)),
            DateTime d => JsonValue.Create(d.ToString("o", CultureInfo.InvariantCulture)),
            TimeSpan t => JsonValue.Create(t.ToString("c", CultureInfo.InvariantCulture)),
            Enum e => JsonValue.Create(e.ToString()),
            IDictionary dictionary => ToObject(dictionary, depth),
            IEnumerable list => ToArray(list, depth),
            _ => JsonValue.Create(value.ToString()),
        };
    }

    /// <summary>
    /// Same fix as the window (SectionParser): PowerShell unrolls a one-row table, @( @("a", 1) ) arrives
    /// as @("a", 1). Rows made only of scalars, with several columns, are wrapped back into one row.
    /// </summary>
    public static void NormalizeTables(JsonObject data)
    {
        if (data["Sections"] is not JsonArray sections)
            return;

        foreach (var section in sections)
        {
            if (section is JsonObject s
                && s["Type"]?.GetValue<string>() == "Table"
                && s["Columns"] is JsonArray { Count: > 1 }
                && s["Rows"] is JsonArray { Count: > 0 } rows
                && rows.All(r => r is not JsonArray))
            {
                var single = new JsonArray();
                foreach (var cell in rows.ToList())
                {
                    rows.Remove(cell);
                    single.Add(cell);
                }
                rows.Add(single);
            }
        }
    }

    private static JsonObject ToObject(PSObject ps, int depth)
    {
        var obj = new JsonObject();
        foreach (var property in ps.Properties)
            obj[property.Name] = ToJson(property.Value, depth + 1);
        return obj;
    }

    // [ordered] hashtables keep their order.
    private static JsonObject ToObject(IDictionary dictionary, int depth)
    {
        var obj = new JsonObject();
        foreach (DictionaryEntry entry in dictionary)
            obj[entry.Key.ToString() ?? string.Empty] = ToJson(entry.Value, depth + 1);
        return obj;
    }

    private static JsonArray ToArray(IEnumerable list, int depth)
    {
        var array = new JsonArray();
        foreach (var item in list)
            array.Add(ToJson(item, depth + 1));
        return array;
    }
}
