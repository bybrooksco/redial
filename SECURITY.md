# Security

## What this software needs, and what that means

To drive the dial and pen, the daemon needs two privileges. Please read them
before installing.

- **Membership in the `input` group.** The dial is read from `/dev/input/event*`.
  Anything in the `input` group can read **every** input device on the machine,
  including your keyboard. In practice that is keylogger-equivalent access for any
  process you run. Many Linux desktop tools ask for this; it is still a real
  trade-off, and `install.sh` asks before adding you.
- **Write access to `/dev/uinput`** (rule in `udev/70-surface-dial.rules`). This
  lets the daemon create virtual keyboards and mice to send scroll and key events.
  It also lets any `input`-group process inject keystrokes.
- **Write access to the dial's `hidraw` node**, scoped by the rule to the Surface
  Dial's Bluetooth ID only, to drive the haptic motor.

The daemon makes **no network connections** (its only socket is a local one to the overlay), and runs as your user, not root.
`install.sh` uses `sudo` only for the udev rule and the group change, after asking.

## What it keeps on your machine

The daemon's own files (config, a small `progress.json` of usage counts, `status.json`, and the log)
are private to your user (mode 0600, folders 0700); earlier versions left them readable by other
accounts and the daemon tightens them on start. The log can name windows. Nothing is sent anywhere.
The overlay socket lives in `$XDG_RUNTIME_DIR` (private to you); there is no `/tmp` fallback.

## Commands in your config

`launchers`, `assistant` and custom `tools` in `config.json` run programs as you. That is not a
privilege escalation (anything that can edit your config can already run code as you), but it is the
reason for the rule below.

## Themes and tool packs from other people (planned; this is the rule they must meet)

- A **theme** is data (colours, sizes, which layout), never code. Loading one must not be able to run
  anything. A theme written in QML is code and will be labelled that way, off by default, and
  something you turn on after reading it.
- A **tool pack** that can run a command must show you exactly which commands, and ask before it is
  enabled. Packs get no other access than the dial's own actions.
- Anything downloaded is unreviewed unless it says otherwise. Read it first.

## Getting a copy you can trust

The single-file installer checks that it arrived intact (a checksum inside the file), but a checksum
that travels with a file cannot prove who made it. Releases are published on this repository's
GitHub Releases page with a SHA-256 list; compare it with the file you downloaded. Do not run
anything you were told to pipe from `curl` into a shell, here or elsewhere. Read `install.sh`: it is
short.

## Known limits

- Anything running as you, once you are in the `input` group, can read every input device. Replacing
  the group with a narrower rule that tags only the dial and pen for the logged-in user is planned;
  until then this is the trade-off in the first section.
- The daemon recognises the dial by its device name, so another program in the same group could
  create a virtual device with that name. It could then only trigger the dial's own tools.
- It has been tested on one machine, with one dial, on Hyprland. The Sway, i3 and niri backends are
  untested on real sessions.

## Reporting a vulnerability

Please report privately through GitHub's *Security → Report a vulnerability* on
this repository rather than a public issue. Replies are best-effort.
This is a volunteer project, so there is no bug bounty.
