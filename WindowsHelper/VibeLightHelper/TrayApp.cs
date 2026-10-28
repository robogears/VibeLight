using System.Net.Sockets;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using VibeLightHelper.Core;
using static VibeLightHelper.NativeTray;

namespace VibeLightHelper;

/// <summary>
/// The whole UI: an icon by the clock (owner: "just a bottom task bar icon,
/// kind of like MoonDeckBuddy"). Everything else is controlled from the iPad.
/// The menu says whether it's working and who may use it, and can start it
/// with Windows, put the display back, or quit. Plain Win32: a hidden window
/// owns the icon and receives its clicks.
/// </summary>
sealed class TrayApp
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunValue = "VibeLight Helper";
    const string Title = "VibeLight Helper";
    /// "0.1.1", from the project's Version: the menu's heading says which build this is.
    static readonly string AppVersion = typeof(TrayApp).Assembly.GetName().Version?.ToString(3) ?? "";
    const uint TrayMessage = WM_APP + 1;
    /// From PcStateHandler's events (a server thread) to the window's thread.
    const uint RestartScheduledMessage = WM_APP + 2;
    const uint RestartCancelledMessage = WM_APP + 3;
    const uint IconId = 1;

    enum Command : uint { None, Header, StartWithWindows = 10, PutDisplayBack, CancelRestart, Quit }

    readonly Win32Platform platform = new();
    readonly PcStateHandler power;
    readonly TrustedClients trust;
    readonly HelperServer? server;
    readonly string status;
    readonly bool firstRun;
    readonly WndProc wndProc;   // held: Windows calls it for the life of the window
    readonly uint taskbarCreated;
    IntPtr window;
    IntPtr icon;
    volatile string? lastUsed;

    public TrayApp()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        trust = new TrustedClients(() => TrustedClients.DefaultCandidatePaths(programFiles));
        // Restart PC, MoonDeckBuddy's way: scheduled, cancellable, then forced.
        power = new PcStateHandler(() => platform.CanRestart, platform.RestartNow);
        power.RestartScheduled += seconds =>
            Native.PostMessageW(window, RestartScheduledMessage, new IntPtr(seconds), IntPtr.Zero);
        power.RestartCancelled += () =>
            Native.PostMessageW(window, RestartCancelledMessage, IntPtr.Zero, IntPtr.Zero);
        var api = new HelperApi(platform, trust, Environment.MachineName, power);
        api.DeviceServed += name =>
            lastUsed = $"Last used by {(string.IsNullOrEmpty(name) ? "a paired device" : name)} at {DateTime.Now:t}";

        var dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                   "VibeLightHelper");
        try
        {
            server = new HelperServer(api, CertificateStore.LoadOrCreate(Path.Combine(dataDir, "helper.pfx")),
                                      Protocol.DefaultPort);
            server.Start();
            status = $"Ready on port {Protocol.DefaultPort}";
        }
        catch (SocketException)
        {
            status = $"Port {Protocol.DefaultPort} is in use. Is it already running?";
        }

        // First run: start with Windows, so it's there whenever the iPad is.
        var firstRunMarker = Path.Combine(dataDir, "first-run-done");
        firstRun = !File.Exists(firstRunMarker);
        if (firstRun)
        {
            SetStartWithWindows(true);
            Directory.CreateDirectory(dataDir);
            File.WriteAllText(firstRunMarker, DateTime.UtcNow.ToString("O"));
        }

        wndProc = WindowProc;
        // Explorer announces a restart with this; the icon has to be added again.
        taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
    }

    public void Run()
    {
        var instance = GetModuleHandleW(null);
        var windowClass = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProc),
            hInstance = instance,
            lpszClassName = "VibeLightHelperTray",
        };
        RegisterClassExW(ref windowClass);
        // A top-level window that is never shown (a message-only window
        // would miss Explorer's TaskbarCreated broadcast).
        window = CreateWindowExW(0, windowClass.lpszClassName, Title, 0, 0, 0, 0, 0,
                                 IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        icon = LoadTrayIcon();
        AddIcon();
        if (firstRun) Notify("Running by the clock. Your iPad finds it on its own.");

        while (GetMessageW(out var message, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref message);
            DispatchMessageW(ref message);
        }
    }

    IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == TrayMessage)
        {
            uint mouse = (uint)(lParam.ToInt64() & 0xFFFF);
            if (mouse == WM_RBUTTONUP || mouse == WM_LBUTTONUP) ShowMenu();
            return IntPtr.Zero;
        }
        if (msg == RestartScheduledMessage)
        {
            // MoonDeckBuddy's tray message, in our words.
            Notify($"Restarting in {wParam.ToInt64()} second(s). Cancel it from this menu.");
            return IntPtr.Zero;
        }
        if (msg == RestartCancelledMessage)
        {
            Notify("Restart cancelled.");
            return IntPtr.Zero;
        }
        if (msg == taskbarCreated && taskbarCreated != 0)
        {
            AddIcon();
            return IntPtr.Zero;
        }
        if (msg == WM_DESTROY)
        {
            PostQuitMessage(0);
            return IntPtr.Zero;
        }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    // MARK: - The icon

    NOTIFYICONDATA IconData(uint flags) => new()
    {
        cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
        hWnd = window,
        uID = IconId,
        uFlags = flags,
        uCallbackMessage = TrayMessage,
        hIcon = icon,
        szTip = Title,
        szInfo = "",
        szInfoTitle = "",
    };

    void AddIcon()
    {
        var data = IconData(NIF_MESSAGE | NIF_ICON | NIF_TIP);
        Shell_NotifyIconW(NIM_ADD, ref data);
    }

    void Notify(string text)
    {
        var data = IconData(NIF_INFO);
        data.szInfo = text;
        data.szInfoTitle = Title;
        data.dwInfoFlags = NIIF_NONE;
        Shell_NotifyIconW(NIM_MODIFY, ref data);
    }

    static IntPtr LoadTrayIcon()
    {
        using var stream = typeof(TrayApp).Assembly.GetManifestResourceStream("VibeLightHelper.helper.ico");
        if (stream is null) return IntPtr.Zero;
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        var ico = buffer.ToArray();
        int size = Math.Max(16, GetSystemMetrics(SM_CXSMICON));
        if (IconFile.Pick(ico, size) is not { } image) return IntPtr.Zero;
        var bits = ico.AsSpan(image.Offset, image.Length).ToArray();
        return CreateIconFromResourceEx(bits, (uint)bits.Length, true, 0x00030000, size, size, LR_DEFAULTCOLOR);
    }

    // MARK: - The menu

    void ShowMenu()
    {
        var menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING | MF_GRAYED, (UIntPtr)(uint)Command.Header, $"{Title} {AppVersion}");
        SetMenuDefaultItem(menu, (uint)Command.Header, 0);   // bold, as a heading
        AppendMenuW(menu, MF_STRING | MF_GRAYED, UIntPtr.Zero, status);
        AppendMenuW(menu, MF_STRING | MF_GRAYED, UIntPtr.Zero, DevicesLine());
        if (lastUsed is { } used) AppendMenuW(menu, MF_STRING | MF_GRAYED, UIntPtr.Zero, used);
        AppendMenuW(menu, MF_SEPARATOR, UIntPtr.Zero, null);
        AppendMenuW(menu, MF_STRING | (StartsWithWindows() ? MF_CHECKED : 0),
                    (UIntPtr)(uint)Command.StartWithWindows, "Start with Windows");
        AppendMenuW(menu, MF_STRING, (UIntPtr)(uint)Command.PutDisplayBack, "Put the Display Back");
        if (power.State == PcStateHandler.PcState.Restarting)
        {
            AppendMenuW(menu, MF_STRING, (UIntPtr)(uint)Command.CancelRestart, "Cancel Restart");
        }
        AppendMenuW(menu, MF_SEPARATOR, UIntPtr.Zero, null);
        AppendMenuW(menu, MF_STRING, (UIntPtr)(uint)Command.Quit, "Quit");

        // The foreground dance is what lets a click elsewhere close the menu.
        GetCursorPos(out var cursor);
        SetForegroundWindow(window);
        var chosen = (Command)TrackPopupMenuEx(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_BOTTOMALIGN,
                                               cursor.X, cursor.Y, window, IntPtr.Zero);
        Native.PostMessageW(window, WM_NULL, IntPtr.Zero, IntPtr.Zero);
        DestroyMenu(menu);

        switch (chosen)
        {
            case Command.StartWithWindows:
                SetStartWithWindows(!StartsWithWindows());
                break;
            case Command.PutDisplayBack:
                Notify(platform.Restore().Message);
                break;
            case Command.CancelRestart:
                power.Cancel();   // its event says "Restart cancelled."
                break;
            case Command.Quit:
                Quit();
                break;
        }
    }

    string DevicesLine()
    {
        int allowed = trust.AllowedCount;
        return trust.Sources.Count == 0 ? "Vibepollo/Sunshine not found on this PC"
            : allowed == 1 ? "1 device paired with Vibepollo can use it"
            : $"{allowed} devices paired with Vibepollo can use it";
    }

    static bool StartsWithWindows()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(RunValue) is string;
    }

    static void SetStartWithWindows(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on && Environment.ProcessPath is { } path) key.SetValue(RunValue, $"\"{path}\"");
        else key.DeleteValue(RunValue, throwOnMissingValue: false);
    }

    void Quit()
    {
        // Leaving the PC as it was found.
        platform.Restore();
        server?.Dispose();
        power.Dispose();
        platform.Dispose();
        var data = IconData(0);
        Shell_NotifyIconW(NIM_DELETE, ref data);
        if (icon != IntPtr.Zero) DestroyIcon(icon);
        DestroyWindow(window);
    }
}
