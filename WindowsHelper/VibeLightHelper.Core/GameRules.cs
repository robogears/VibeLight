namespace VibeLightHelper.Core;

/// <summary>What the PC can do for VibeLight. Windows implements it with
/// Win32 (VibeLightHelper/Win32Platform.cs); tests use a fake.</summary>
public interface IPlatform
{
    StatusResponse Status();

    /// <summary>Sets the game's display to this size (same refresh rate) and
    /// fits the game window to it, remembering what to put back.</summary>
    MatchResponse Match(int width, int height);

    /// <summary>Puts back what <see cref="Match"/> changed.</summary>
    MatchResponse Restore();

    /// <summary>Asks the game to close, and ends it if it hasn't after <paramref name="grace"/>.</summary>
    Task<QuitGameResponse> QuitGameAsync(TimeSpan grace, CancellationToken token);
}

/// <summary>Which window is "the game", and which display mode to use. Pure,
/// so it is tested.</summary>
public static class GameRules
{
    /// Things that are on screen while you stream but are never the game:
    /// the shell, launchers and overlays, the streaming host itself, browsers
    /// and chat. Quit Game must never end any of them.
    static readonly HashSet<string> NotGames = new(StringComparer.OrdinalIgnoreCase)
    {
        "explorer", "dwm", "csrss", "winlogon", "lockapp", "logonui", "taskmgr", "rundll32",
        "shellexperiencehost", "startmenuexperiencehost", "searchhost", "searchapp",
        "textinputhost", "applicationframehost", "systemsettings", "widgets", "widgetservice",
        "vibelighthelper", "sunshine", "apollo", "vibepollo", "moondeckbuddy",
        "steam", "steamwebhelper", "gameoverlayui", "epicgameslauncher", "eadesktop", "eabackgroundservice",
        "galaxyclient", "upc", "ubisoftconnect", "battle.net", "riotclientservices", "xboxpcapp",
        "playnite.desktopapp", "playnite.fullscreenapp", "launchbox", "bigbox",
        "gamebar", "gamebarftserver", "xboxgamebarwidgets", "nvidia overlay", "nvcontainer",
        "msedge", "chrome", "firefox", "opera", "brave", "discord", "obs64", "obs32",
        "devenv", "code", "cmd", "powershell", "pwsh", "windowsterminal", "conhost",
    };

    public static bool MayBeGame(string processName) =>
        !string.IsNullOrWhiteSpace(processName) && !NotGames.Contains(processName.Trim());

    /// A game fills most of its display (fullscreen, borderless, or a big window).
    public static bool CoversDisplay(int windowWidth, int windowHeight, int displayWidth, int displayHeight) =>
        displayWidth > 0 && displayHeight > 0 && windowWidth > 0 && windowHeight > 0 &&
        (long)windowWidth * windowHeight >= 0.3 * displayWidth * displayHeight;

    /// <summary>
    /// The mode to switch to: exactly width×height, at the current refresh
    /// rate when the display has it (owner: never change the frame rate),
    /// else the fastest rate not above it, else the slowest above it. Null if
    /// the display has no mode of that size at all.
    /// </summary>
    public static (int Width, int Height, int RefreshHz)? PickMode(
        IEnumerable<(int Width, int Height, int RefreshHz)> modes, int width, int height, int currentHz)
    {
        var sized = modes.Where(m => m.Width == width && m.Height == height).Distinct().ToList();
        if (sized.Count == 0) return null;
        var same = sized.Where(m => m.RefreshHz == currentHz).ToList();
        if (same.Count > 0) return same[0];
        var below = sized.Where(m => m.RefreshHz < currentHz).OrderByDescending(m => m.RefreshHz).ToList();
        if (below.Count > 0) return below[0];
        return sized.OrderBy(m => m.RefreshHz).First();
    }

    /// The sizes VibeLight may ask for: anything a TV or monitor might be.
    public static bool IsSaneSize(int width, int height) =>
        width is >= 320 and <= 7680 && height is >= 240 and <= 4320;
}
