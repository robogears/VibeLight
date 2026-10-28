# VibeLight Helper (Windows)

A small app that lives by the clock on the gaming PC, kind of like
MoonDeckBuddy. It lets VibeLight on the iPad do two things the stream can't
do by itself:

- **Match TV.** When the iPad is plugged into a TV, VibeLight restarts the
  stream at the TV's size. The helper then sets the PC's display to that size
  (the refresh rate stays the same) and fits the game window to it, borderless.
  Unplugging puts everything back.
- **Quit Game.** Closes the game that's running. It asks politely first
  (`WM_CLOSE`, the same as clicking ✕). If the game is still open after a few
  seconds, it ends the game.

There are no settings on the PC. Everything is set from VibeLight on the iPad,
under **Settings ▸ Windows Helper**. Without the helper, those rows are greyed
out.

## Install

1. Copy `VibeLightHelper.exe` anywhere on the PC (for example
   `%LOCALAPPDATA%\Programs\VibeLight Helper\`) and run it. It runs as you,
   and doesn't need administrator rights.
2. Windows Firewall asks once. Allow it on **private networks**: that is how
   the iPad reaches it (TCP port 47333).
3. That's it. On first run it starts with Windows (you can untick
   **Start with Windows** in its menu). If your iPad can stream from this PC,
   it can use the helper. No PIN, no pairing.

## Who may use it

Only devices that this PC's streaming host (Vibepollo, Apollo or Sunshine)
has paired and allowed to launch apps. When the iPad connects, it shows the
same client certificate it paired with the host. The helper checks it against
the host's own list of paired devices, in
`C:\Program Files\<Vibepollo|Apollo|Sunshine>\config\sunshine_state.json`.
Unpair a device in the host's web UI and the helper stops answering it at
once. Nothing else on the network gets in. `GET /info` is the one exception:
it tells VibeLight the helper is there and gives the PC's name, nothing more.

The iPad checks the helper too. It remembers the helper's certificate the
first time it connects and refuses a different one after that.

## What it can't do

- **Games in exclusive fullscreen** pick their own resolution, so the helper
  won't change it underneath them. VibeLight says so: switch the game to
  borderless or windowed, or set the resolution in the game. Most modern games
  default to borderless.
- **Games running as administrator** can't be ended by a helper running as
  you. Quit Game tells you this; run the helper as administrator too if you
  need it.
- Display changes are temporary, never saved. **Put the Display Back** in the
  menu, quitting the helper, or restarting Windows all undo them.

## Build

Needs the .NET 8 SDK. It builds from Windows, macOS or Linux because the tray
app is plain Win32, with no Windows Forms.

```bash
dotnet test VibeLightHelper.Tests                    # protocol, trust, rules, real TLS
dotnet publish VibeLightHelper -c Release -o out     # out/VibeLightHelper.exe
```

The result is one self-contained `VibeLightHelper.exe` (win-x64, about 35 MB).
It needs no .NET installed on the PC.

## Layout

| Project | What |
| --- | --- |
| `VibeLightHelper.Core` | The cross-platform part: HTTPS server, routes, who-may-use-it, game and display rules. |
| `VibeLightHelper` | The Windows part: tray icon and menu, display modes, game window, Quit Game. |
| `VibeLightHelper.Tests` | xunit tests for Core. They run on any OS, including a real mutual-TLS round trip. |

The wire contract is in `VibeLightHelper.Core/Protocol.cs`. VibeLight's side is
`VibeLight/Core/WindowsHelperClient.swift`.

| Route | Does |
| --- | --- |
| `GET /info` | `{name, version, hostName}`. No certificate needed. |
| `GET /status` | The display, the game in front (if any), and whether anything is changed. |
| `POST /match {width, height}` | The display to that size (same Hz), the game fitted borderless. |
| `POST /restore` | Puts back whatever `/match` changed. |
| `POST /quit-game {graceSeconds}` | Closes the game, then ends it after the grace period (1–30 s, 5 by default). |
