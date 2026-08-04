# VibeLight v0.2.1 — Type on your PC from the iPad, and presets a thumb away

*Nothing to redo this time — no re-pairing, no lost settings. Update and carry on. This release is mostly about the two places you actually touch: your presets, and the iPad while a game is running.*

### ⌨️ Type on your PC with the iPad's keyboard
A keyboard button now sits under the ✕ while you're streaming. Tap it and the iPad's own keyboard slides up — what you type goes straight to the PC, as if a keyboard were plugged into it. Chat boxes, launcher search fields, that one game that wants you to name your save.

It's the real iPadOS keyboard, so you get every symbol page, dictation, and the layout you already know. Autocorrect is off on purpose: "w" needs to arrive as "w", not as "We".

While it's up, only the part of the screen the keyboard actually covers stops passing taps through to the game — so you can tap a text field first and then type into it. That holds whether the keyboard is docked at the bottom, split in half, or floating wherever you dragged it.

### 👋 The stream buttons get out of the way
The ✕ and keyboard buttons show for about 7 seconds when a game starts, then slide off the right edge. Swipe in from the top-right corner and they come back, following your finger.

Once they're gone they stop taking taps entirely — no invisible button sitting on top of your game. Using either one resets the timer, and raising the keyboard keeps them put, since those are exactly the two buttons you want mid-sentence.

### 🎛️ Presets moved under your games
They used to live on the right edge, a whole shelf-width away. Now they sit in a row directly beneath the games: **press down** from any game to reach them, and up to go back to the exact game you left.

They're a proper part of the navigation now rather than a bolt-on, so the mouse, a controller, the keyboard and touch all agree about what's selected — and your slot position follows you between the home screen and Settings. Your games also scroll all the way to the edge of the screen now, instead of fading out early to make room for the old rail.

### 🛡️ Confirmations that don't bite
"Forget Computer?" and "Clear Preset?" are meant to open with **Cancel** selected. They did — until the first time you moved to or hovered the red button, after which every later opening started with the destructive option already selected, one press away from deleting something. Fixed.

Right-clicking a preset on the home screen and choosing **Clear** now asks first too, like it already did everywhere else.

### 🎮 The PlayStation button needs two presses — that's Apple, not us
If you've wondered why the PS button takes two presses on iPad: the first opens iOS's own Game Overlay, and only the second reaches the game. iPadOS says so itself, on screen, naming VibeLight. There's no way to opt out, so the in-app shortcut list now reads "PS / Xbox button ×2" instead of sending you hunting for a bug that was never there.

VibeLight also identifies itself to iOS as a game now, which switches on Game Mode — that meaningfully lowers controller latency over Bluetooth.

### 🔒 Reliability
Two full audits and a deep review of every change went into this release. What you'd actually notice:

- Your game shelf no longer goes blank on a newly added computer if the PC sleeps right after you add it.
- **Forget Computer** always works — there was a window where the button quietly did nothing and left the computer in the list.
- Limits on how much a computer can make the app hold now genuinely hold. Two of them were checking the size *after* loading everything into memory, which on an iPad could mean the app being killed mid-pairing.
- The iPad's encryption library moved up to mbedTLS 3.6.7.
- Errors during pairing and PC restarts say what actually happened instead of collapsing into "offline".

### 🧹 Housekeeping
The separate "VibeLight Dev" build is gone — unused for months, and it only cluttered the project. This doesn't affect the app you use.

---
*Install (Mac): open the `.dmg` and drag VibeLight to Applications. Already on an earlier version? VibeLight offers this update in-app.*
*Install (iPad / iPhone): build `VibeLight-iOS` from source with Xcode, or sideload via AltStore.*
