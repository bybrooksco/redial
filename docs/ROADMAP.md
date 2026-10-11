# Roadmap to 1.0

re:dial for Omarchy is in **beta**. Version numbers say how close it is; 1.0 means "ready for
people who are not the author, including people who depend on it to use a computer".

## 0.8.0: first beta package (done, not sent)

A working build with an installer, an uninstaller and a testing plan. It was first numbered 0.9.7 and
renumbered on 2026-10-09: by the 1.0 checklist below it is nowhere near done, and 0.9.x is kept for
the stage when people other than the author use it.

## 0.8.1: first-run experience (done)

The first informal test (2026-10-08) showed that turning the dial for the first time does too little.
This stage adds a visible response on the first turn and an adaptive, dial-driven introduction that
teaches turn, press and hold as the person is ready for them. See the design note in the project vault.

## 0.8.2: teaching styles (done)

Three ways of teaching the dial, switchable in Settings (adaptive by default, discover, guided tour),
plus a hint for each tool the first time it is tried.

## 0.8.3 and 0.8.4: fixes, backends and the rename (done)

0.8.3: the pen-eraser fix, launchers no longer killed, safer settings writes, and window-manager
backends for Sway, i3 and niri. 0.8.4: the project became re:dial, and installing it upgrades an
earlier Surface Dial beta in place.

## Other compositors (merged in 0.8.3; Sway, i3 and niri still untested)

Window tools go through a backend: Hyprland (reference), Sway/i3 and niri written, untested on a real
session. Next: run each in a nested session and fix what that shows; an on-screen display that does not
need Quickshell (notifications) so GNOME and KDE feel finished; then GNOME/KDE window tools through
D-Bus. The dial's own input, haptics, volume, brightness, media and key tools do not depend on the
compositor. See CHANGELOG.

## 0.9.0: first outside testers (under way)

A few people who already run Omarchy and own a Surface Dial install it and use it for ordinary
work. The aim is to find what the author cannot see: things that are confusing, things that break
on a different machine, things that feel wrong in a different hand.

## 0.9.x: what the testers found

Fixes and clarifications from their notes. No new features unless a tester's problem needs one.
The release candidate adds:

- The first run of the automated checks on a public repository, with whatever that finds fixed.
- A decision on splitting the single-file daemon into modules (it changes how updates and
  rollbacks work, so it is deliberately not done during the beta).
- Testing with people who use the dial because of a disability, once they can be found and are
  willing: their notes outrank every other source.

## 1.0

Ready when all of these are true:

- [ ] Used for real work by people other than the author, on more than one machine, for long
      enough to trust (not just installed).
- [ ] Tried with at least one screen reader and at least one person with limited hand function,
      and what they found is fixed or written down as a known limit.
- [ ] Every tool and click action has been used on real hardware at least once.
- [ ] The automated checks have run green on the public repository.
- [ ] The installer and uninstaller have been run on a clean machine that is not the author's.
- [ ] The README says plainly what works and what does not.

## After 1.0 (not promised)

A theme system and an extension point for tool packs from other people; a macOS port; translations;
an optional local assistant that can carry out the actions the dial already knows (it would need
its own design: what it may do, confirmation before anything with side effects, and entirely
optional).
