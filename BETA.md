# Surface Dial for Omarchy: beta notes

Thank you for trying this. It is an early version, and you are among the first people to run it
other than its author, so please read this page before you install. It is short.

## What it is

Software that makes a Microsoft Surface Dial (the haptic knob) work as a control for an
[Omarchy](https://omarchy.org) desktop: turn it for volume, scrolling, zoom, switching windows and
more; hold the button to pick a tool; click for what you choose. It includes an on-screen display
and a settings window. A new user is also shown a few short hints as they go, one idea at a time, which can be turned off. It also supports the Surface Pen's buttons and eraser. It is free and MIT
licensed.

## What you need

- Linux with **Omarchy** (Hyprland and its Quickshell shell). Omarchy is a separate project and is *not*
  included in this download; get it from <https://omarchy.org> first. Arch-based; the installer uses `pacman`
  through Omarchy's own helper.
- A **Surface Dial**, paired over Bluetooth. The installer does not pair it for you; `redial-setup` tells you if none is paired and explains how, and `scripts/pair-dial.sh` does the pairing.
- About ten minutes, and willingness to restart your shell once.

It is not for other Linux desktops, and it is not a Windows or macOS program.

## What has and has not been tested

**Tested:** daily use by its author on one Surface Studio running Omarchy; a few hundred automated
tests; an earlier version briefly on a second laptop.

**Not tested yet, so please watch for these:**

- How it feels in other hands and on other machines. The author has used one dial on one desk.
- Screen readers. The settings window is built for the keyboard and for assistive technology, but no
  real screen reader has been run against it.
- Spoken tool names (optional), the Pointer and sideways-scroll tools, Move Window and Tile Focus,
  and several of the newest click actions have been checked by automated tests but not used for real.
- Machines without a backlight, other monitors and other themes beyond a check of text contrast.
- The Bluetooth pairing steps on a dial that has been used with a different computer first.

If something does not work, that is exactly what this beta is for. You are not doing it wrong.

## What the installer changes

For your user only, after showing you a plan and asking once:

- puts programs in `~/.local/bin` (`redial-hypr` and a few helpers);
- puts the plugin in `~/.config/omarchy/plugins/redial`;
- adds one line to start the daemon at login in `~/.config/hypr/autostart.lua`;
- adds **Setup > Surface Dial** to your Omarchy menu;
- installs one small package, `playerctl` (for the Media tool), through Omarchy's package helper if it is missing, and tells you about other optional tools it did not find (for example `voxtype` for dictation, `brightnessctl` for the Brightness tool);
- restarts the daemon and the shell if you agree.

It asks separately before using `sudo`, for two things: a udev rule so the dial can be read, and
adding you to the `input` group. **Read `SECURITY.md` for what those permissions mean**: anything in
the `input` group can read every input device on the machine. Anything it replaces is copied to
`~/.local/share/redial-backups/` first.

## Privacy

Nothing is sent anywhere: the daemon makes no network connections. It keeps a small log at
`~/.local/state/redial/daemon.log` (256 KB, one rotation). It records connections, errors and
which gestures fired, and occasionally an application name (for example the window the pen's
eraser was used in). It does not record what you type. **Look at the log before sending it to
anyone.** The optional "Quick assistant" action only runs the command you yourself put in the config.

The hints that teach you the dial keep their progress in `~/.config/redial/progress.json`: which
hints you have seen and plain counts of how many steps, clicks, menu openings and tool choices you have
made. It stays on your computer, is never sent anywhere, and is not read by anything but the dial's own
program. You can turn the hints off ("Hints while you learn" on the Feel page), and `--purge` on the
uninstaller moves the file to the backup folder with your settings.

## Things to know before you click

- The **Zoom** tool holds the Ctrl key while it is active, so it hands back to Volume after at most
  ten seconds. Nothing destructive (such as closing a window) is offered as a click action.
- Click actions can press Enter, Backspace, copy and paste and similar. If you set the double-click to
  something, it will do it.
- The settings window takes over the keyboard while it is open. Escape closes it.

## How to undo everything

```
bash uninstall.sh            # keeps your settings
bash uninstall.sh --purge    # removes them too
```

It stops the daemon and removes what the installer added, moving each piece to a backup folder first
(the folder is named at the end of the run). It asks before removing the udev rule. It does not take
you out of the `input` group, because other things may need it.

## How to give feedback

The most useful notes are specific and small: what you did, what you expected, what happened.
Please include:

1. the version (it is on the settings window's **Help** page, or run `redial-hypr --version`);
2. the output of `redial-setup` (it checks everything and says what to fix);
3. anything from `~/.local/state/redial/daemon.log` that looks relevant, after reading it.

`FEEDBACK.md` is a short sheet you can copy into an email: setup, a few things to try on the first day,
and questions for after a few days. Use it or not, as you like.

A good first week: use it for ordinary work, open the settings once and change something, try the
**Feel** page's sliders if the dial feels too fast or too slow, and note anything that annoyed you,
even slightly. "I did not understand this" is as valuable as "this is broken".

## Not affiliated

This is an independent project. "Surface Dial" and "Surface Pen" are Microsoft's names and are used
here only to say which hardware it works with. It is not made by or endorsed by Microsoft or by
Omarchy. It is provided as is, under the MIT licence, with no warranty.
