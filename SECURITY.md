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

## Reporting a vulnerability

Please report privately through GitHub's *Security → Report a vulnerability* on
this repository rather than a public issue. Replies are best-effort.
This is a volunteer project, so there is no bug bounty.
