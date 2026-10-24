using System;
using System.Runtime.InteropServices;

namespace SysInfo.Native;

/// <summary>
/// Battery and power source of a Windows computer (GetSystemPowerStatus), for the Sensors module (helper of the host,
/// §4.6): live charge and source at each refresh without WMI. Capacities, cycles and chemistry stay in the module
/// (root/wmi, cached). Linux reads /sys/class/power_supply directly.
/// </summary>
public static class PowerStatus
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

    /// <summary>Null outside Windows or when the call fails.</summary>
    public static PowerSample? Read()
    {
        if (!OperatingSystem.IsWindows() || !GetSystemPowerStatus(out var s))
            return null;
        return new PowerSample(
            s.ACLineStatus switch { 0 => false, 1 => true, _ => null },
            HasBattery: (s.BatteryFlag & 128) == 0 && s.BatteryFlag != 255,
            Charging: (s.BatteryFlag & 8) != 0,
            Percent: s.BatteryLifePercent == 255 ? null : s.BatteryLifePercent,
            SecondsLeft: s.BatteryLifeTime < 0 ? null : s.BatteryLifeTime,
            BatterySaver: s.SystemStatusFlag == 1);
    }
}

/// <summary>OnAc is null when unknown; Percent and SecondsLeft are null when unknown (or on AC for SecondsLeft).</summary>
public sealed record PowerSample(bool? OnAc, bool HasBattery, bool Charging, int? Percent, int? SecondsLeft, bool BatterySaver);
