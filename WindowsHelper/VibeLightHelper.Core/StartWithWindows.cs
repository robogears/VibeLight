namespace VibeLightHelper.Core;

/// <summary>
/// Keeping "Start with Windows" true. It's a value under HKCU's Run key
/// holding the exe's path — and the exe's name changes with every version
/// (VibeLightHelperV0.1.1.exe → V0.1.2…), so a value written once, on the
/// first run, kept pointing at an exe that an update had deleted, and the
/// helper silently stopped starting with Windows. Now every start re-points
/// it at the running exe, unless it was turned off. Pure, so it is tested.
/// </summary>
public static class StartWithWindows
{
    /// The Run value for this exe.
    public static string Command(string exePath) => $"\"{exePath}\"";

    /// What to write to the Run value at startup, or null to leave it: on the
    /// first run it's turned on; after that, if it's on but names another
    /// file (an older version, or the exe moved), it's pointed at this one;
    /// if it's off, it was turned off and stays off.
    public static string? Heal(string? current, string exePath, bool firstRun)
    {
        var wanted = Command(exePath);
        if (firstRun) return string.Equals(current, wanted, StringComparison.OrdinalIgnoreCase) ? null : wanted;
        if (current is null) return null;
        return string.Equals(current, wanted, StringComparison.OrdinalIgnoreCase) ? null : wanted;
    }

    /// <summary>Windows' own switch for a startup app (Settings ▸ Startup
    /// apps, Task Manager): a 12-byte value under
    /// <c>Explorer\StartupApproved\Run</c> whose first byte is even when on
    /// (2, 6) and odd when off (3, 7). No value means on.</summary>
    public static bool IsDisabledByWindows(byte[]? approved) =>
        approved is { Length: > 0 } && (approved[0] & 1) == 1;
}
