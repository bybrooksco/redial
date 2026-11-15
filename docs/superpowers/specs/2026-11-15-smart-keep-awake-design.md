# Smart keep-awake, battery baseline, wake from the dial

Date: 2026-11-15 · Status: approved by Brooks (chat, 2026-11-15) · Branch: `keep-awake-smart`

## Why

`keep_awake` (0.9.x) pokes the dial with a silent NONE-waveform haptic every 60 s whenever it is
attached, even hours after the last touch and while the screen is locked. That spends battery for
nothing. Brooks wants the always-there feel while he is working, not around the clock.

## Design (approved)

1. **Smart keep-awake.** With `keep_awake` on, the daemon pokes only while the dial was last used
   within `keep_awake_minutes` (default 30, 5–240, live) and the screen is not locked. After that
   the dial falls back to its own firmware sleep (at most 5:00). `keep_awake` stays off by default.
2. **Battery baseline.** `status.json` gains `keeping_awake` (true while pokes are actually being
   sent). The battery logger records it as a fifth column, so rows where keep-awake is on but idle
   don't pollute the comparison. Brooks runs 3–4 days with `keep_awake` off for the baseline.
3. **Wake the computer from the dial.** An opt-in udev rule `udev/71-redial-wake.rules` enables
   USB wakeup on the Bluetooth adapter (BlueZ already has `WakeAllowed=yes` for the dial). Asked
   for separately by the installer (sudo). Tested on the laptop; Studio suspend is still broken.

## Calls made by Claude (correct if wrong)

- "Last used" = any dial event (turn or press), stamped in the read loop.
- "Locked" = a known locker process is running (`hyprlock`, `swaylock`, `gtklock`, `waylock`,
  `i3lock`), read from `/proc`, checked only when a poke is due. GNOME/KDE lockers aren't
  detected yet (would need logind's `LockedHint`).
- The wake rule matches any USB device of class `e0` (wireless controller: Bluetooth adapters).
  Side effect, written in the rule and the docs: any paired Bluetooth device allowed to wake
  (keyboard, mouse) can now wake the computer, not only the dial.

## Non-goals

No firmware sleep-timer change (not in the dial's HID descriptor). No Studio suspend fix.

## Approaches considered

- Poke while unlocked regardless of use: simpler, but still drains all day while the desk is idle.
- Idle window only, ignore lock: the lock screen is the clearest "I'm away" signal; chosen both.
- Wake rule per adapter VID:PID: exact but breaks on other machines; class match chosen.
