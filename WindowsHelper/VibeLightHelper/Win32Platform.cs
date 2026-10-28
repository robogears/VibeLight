using System.Diagnostics;
using System.Runtime.InteropServices;
using VibeLightHelper.Core;
using static VibeLightHelper.Native;

namespace VibeLightHelper;

/// <summary>
/// The PC side of VibeLight's TV matching and Quit Game, with Win32.
///
/// "The game" is the foreground window when it belongs to a process that may
/// be a game (GameRules) and fills most of its display; the last one seen is
/// remembered, so Quit Game still finds it when VibeLight's stream has ended.
///
/// Match changes the game's DISPLAY to the stream's size (same refresh rate —
/// the owner never wants the frame rate touched) and fits the game window to
/// it, borderless. Games in exclusive fullscreen choose their own resolution;
/// those are left alone and VibeLight is told why. Restore puts back exactly
/// what Match changed. Changes are dynamic (never written to the registry),
/// so a restart of Windows also undoes them.
/// </summary>
sealed class Win32Platform : IPlatform, IDisposable
{
    sealed record GameWindow(IntPtr Hwnd, int Pid, string Process, string Title);
    sealed record SavedDisplay(string Device, int Width, int Height, int RefreshHz);
    sealed record SavedWindow(IntPtr Hwnd, IntPtr Style, IntPtr ExStyle, WINDOWPLACEMENT Placement);

    readonly object gate = new();
    readonly System.Threading.Timer watcher;
    GameWindow? lastGame;
    SavedDisplay? savedDisplay;
    SavedWindow? savedWindow;

    public Win32Platform()
    {
        watcher = new System.Threading.Timer(_ => Watch(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
    }

    void Watch()
    {
        var game = ForegroundGame();
        if (game != null) lock (gate) { lastGame = game; }
    }

    // MARK: - IPlatform

    public StatusResponse Status()
    {
        lock (gate)
        {
            var game = CurrentGame();
            var display = game != null ? DisplayOf(game.Hwnd) : PrimaryDisplay();
            return new StatusResponse(display, game == null ? null : Info(game), savedDisplay != null || savedWindow != null);
        }
    }

    public MatchResponse Match(int width, int height)
    {
        lock (gate)
        {
            var game = CurrentGame();
            var display = game != null ? DisplayOf(game.Hwnd) : PrimaryDisplay();
            if (display is null) return new MatchResponse(false, null, null, false, "Couldn't find the PC's display.");

            if (game != null && IsExclusiveFullscreen())
            {
                return new MatchResponse(false, display, Info(game), false,
                    $"{game.Title} is in exclusive fullscreen and sets its own resolution. " +
                    "Set it in the game, or switch the game to borderless.");
            }

            if (display.Width != width || display.Height != height)
            {
                var pick = GameRules.PickMode(Modes(display.Device), width, height, display.RefreshHz);
                if (pick is null)
                {
                    return new MatchResponse(false, display, game == null ? null : Info(game), false,
                        $"This display has no {width}×{height} mode.");
                }
                // Only the first Match remembers the original: a second TV
                // size while matched still restores to how it was before.
                savedDisplay ??= new SavedDisplay(display.Device, display.Width, display.Height, display.RefreshHz);
                if (!SetMode(display.Device, pick.Value.Width, pick.Value.Height, pick.Value.RefreshHz))
                {
                    return new MatchResponse(false, display, game == null ? null : Info(game), false,
                        $"Windows refused {width}×{height} on this display.");
                }
                display = DisplayOf(game?.Hwnd ?? IntPtr.Zero) ?? display;
            }

            bool fitted = false;
            if (game != null && IsWindow(game.Hwnd))
            {
                savedWindow ??= SaveWindow(game.Hwnd);
                fitted = FitBorderless(game.Hwnd);
            }
            var message = game == null
                ? $"The PC is at {display.Width}×{display.Height}. No game was on screen to fit."
                : fitted ? $"{game.Title} now fills {display.Width}×{display.Height}."
                         : $"The PC is at {display.Width}×{display.Height}; {game.Title} couldn't be resized.";
            return new MatchResponse(true, display, game == null ? null : Info(game), fitted, message);
        }
    }

    public MatchResponse Restore()
    {
        lock (gate)
        {
            if (savedWindow != null && IsWindow(savedWindow.Hwnd)) RestoreWindow(savedWindow);
            var restoredDisplay = savedDisplay != null &&
                SetMode(savedDisplay.Device, savedDisplay.Width, savedDisplay.Height, savedDisplay.RefreshHz);
            var hadSomething = savedDisplay != null || savedWindow != null;
            savedDisplay = null;
            savedWindow = null;
            var game = CurrentGame();
            var display = game != null ? DisplayOf(game.Hwnd) : PrimaryDisplay();
            return new MatchResponse(true, display, game == null ? null : Info(game), false,
                !hadSomething ? "Nothing to put back."
                : restoredDisplay ? $"Back to {display?.Width}×{display?.Height}." : "Put the game window back.");
        }
    }

    public async Task<QuitGameResponse> QuitGameAsync(TimeSpan grace, CancellationToken token)
    {
        GameWindow? game;
        lock (gate) { game = CurrentGame(); }
        if (game is null) return new QuitGameResponse(false, null, false, "No game is running.");

        Process process;
        try { process = Process.GetProcessById(game.Pid); }
        catch (ArgumentException) { return new QuitGameResponse(true, game.Title, false, $"{game.Title} has already closed."); }

        using (process)
        {
            // Politely first: most games save and exit on WM_CLOSE.
            PostMessageW(game.Hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            using var wait = CancellationTokenSource.CreateLinkedTokenSource(token);
            wait.CancelAfter(grace);
            try
            {
                await process.WaitForExitAsync(wait.Token);
                Forget(game);
                return new QuitGameResponse(true, game.Title, false, $"Closed {game.Title}.");
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested) { }

            try
            {
                process.Kill(entireProcessTree: true);
                Forget(game);
                return new QuitGameResponse(true, game.Title, true, $"{game.Title} didn't close, so it was ended.");
            }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
            {
                // Typically a game running as administrator: a normal-user
                // helper may not end it.
                return new QuitGameResponse(false, game.Title, false,
                    $"Windows wouldn't let the helper end {game.Title}. If it runs as administrator, run the helper as administrator too.");
            }
        }
    }

    void Forget(GameWindow game)
    {
        lock (gate)
        {
            if (lastGame?.Pid == game.Pid) lastGame = null;
            if (savedWindow?.Hwnd == game.Hwnd) savedWindow = null;
        }
    }

    // MARK: - The game

    GameWindow? CurrentGame()
    {
        var foreground = ForegroundGame();
        if (foreground != null) { lastGame = foreground; return foreground; }
        return lastGame != null && IsWindow(lastGame.Hwnd) && IsAlive(lastGame.Pid) ? lastGame : null;
    }

    static GameWindow? ForegroundGame()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero || !IsWindowVisible(hwnd)) return null;
        GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == 0 || pid == Environment.ProcessId) return null;
        string name;
        try { using var process = Process.GetProcessById((int)pid); name = process.ProcessName; }
        catch (ArgumentException) { return null; }
        catch (InvalidOperationException) { return null; }
        if (!GameRules.MayBeGame(name)) return null;
        if (!GetWindowRect(hwnd, out var rect)) return null;
        var monitor = MonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
        if (monitor is null || !GameRules.CoversDisplay(rect.Width, rect.Height,
                                                         monitor.Value.rcMonitor.Width, monitor.Value.rcMonitor.Height))
        {
            return null;
        }
        var title = Title(hwnd);
        return new GameWindow(hwnd, (int)pid, name, string.IsNullOrWhiteSpace(title) ? name : title);
    }

    static bool IsAlive(int pid)
    {
        try { using var process = Process.GetProcessById(pid); return !process.HasExited; }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    static string Title(IntPtr hwnd)
    {
        var buffer = new char[256];
        int length = GetWindowTextW(hwnd, buffer, buffer.Length);
        return length > 0 ? new string(buffer, 0, length) : "";
    }

    static GameInfo Info(GameWindow game) => new(game.Title, game.Process, IsExclusiveFullscreen());

    static bool IsExclusiveFullscreen() =>
        SHQueryUserNotificationState(out var state) == 0 && state == QUNS_RUNNING_D3D_FULL_SCREEN;

    // MARK: - Displays

    static MONITORINFOEX? MonitorInfo(IntPtr monitor)
    {
        if (monitor == IntPtr.Zero) return null;
        var info = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>(), szDevice = "" };
        return GetMonitorInfoW(monitor, ref info) ? info : null;
    }

    static DisplayInfo? DisplayOf(IntPtr hwnd) =>
        hwnd == IntPtr.Zero ? PrimaryDisplay() : Display(MonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)));

    static DisplayInfo? PrimaryDisplay() =>
        Display(MonitorInfo(MonitorFromPoint(new POINT { X = 0, Y = 0 }, MONITOR_DEFAULTTOPRIMARY)));

    static DisplayInfo? Display(MONITORINFOEX? monitor)
    {
        if (monitor is null) return null;
        var mode = DEVMODE.Create();
        if (!EnumDisplaySettingsW(monitor.Value.szDevice, ENUM_CURRENT_SETTINGS, ref mode)) return null;
        return new DisplayInfo(monitor.Value.szDevice, (int)mode.dmPelsWidth, (int)mode.dmPelsHeight,
                               (int)mode.dmDisplayFrequency);
    }

    static List<(int Width, int Height, int RefreshHz)> Modes(string device)
    {
        var modes = new List<(int, int, int)>();
        var mode = DEVMODE.Create();
        for (int i = 0; EnumDisplaySettingsW(device, i, ref mode); i++)
        {
            modes.Add(((int)mode.dmPelsWidth, (int)mode.dmPelsHeight, (int)mode.dmDisplayFrequency));
            mode = DEVMODE.Create();
        }
        return modes;
    }

    static bool SetMode(string device, int width, int height, int refreshHz)
    {
        var mode = DEVMODE.Create();
        if (!EnumDisplaySettingsW(device, ENUM_CURRENT_SETTINGS, ref mode)) return false;
        mode.dmPelsWidth = (uint)width;
        mode.dmPelsHeight = (uint)height;
        mode.dmDisplayFrequency = (uint)refreshHz;
        mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
        // 0 = change now, don't save it: a reboot also puts it back.
        return ChangeDisplaySettingsExW(device, ref mode, IntPtr.Zero, 0, IntPtr.Zero) == DISP_CHANGE_SUCCESSFUL;
    }

    // MARK: - The game window

    static SavedWindow SaveWindow(IntPtr hwnd)
    {
        var placement = new WINDOWPLACEMENT { length = Marshal.SizeOf<WINDOWPLACEMENT>() };
        GetWindowPlacement(hwnd, ref placement);
        return new SavedWindow(hwnd, GetWindowLongPtr(hwnd, GWL_STYLE), GetWindowLongPtr(hwnd, GWL_EXSTYLE), placement);
    }

    /// Borderless over the whole display: no frame, no caption, exactly the
    /// display's rectangle (so a window that was 4:3, or windowed, becomes the
    /// TV's shape).
    static bool FitBorderless(IntPtr hwnd)
    {
        var monitor = MonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
        if (monitor is null) return false;
        long style = GetWindowLongPtr(hwnd, GWL_STYLE).ToInt64();
        long exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        style &= ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_MINIMIZE | WS_MAXIMIZE);
        exStyle &= ~(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE);
        SetWindowLongPtr(hwnd, GWL_STYLE, new IntPtr(style));
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(exStyle));
        var bounds = monitor.Value.rcMonitor;
        return SetWindowPos(hwnd, IntPtr.Zero, bounds.Left, bounds.Top, bounds.Width, bounds.Height,
                            SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
    }

    static void RestoreWindow(SavedWindow saved)
    {
        SetWindowLongPtr(saved.Hwnd, GWL_STYLE, saved.Style);
        SetWindowLongPtr(saved.Hwnd, GWL_EXSTYLE, saved.ExStyle);
        var placement = saved.Placement;
        SetWindowPlacement(saved.Hwnd, ref placement);
        SetWindowPos(saved.Hwnd, IntPtr.Zero, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
    }

    public void Dispose() => watcher.Dispose();
}
