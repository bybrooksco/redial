# re:dial beta guide

What you need, hardware basics, what to try, and how to report back. Thank you for helping.

## What you need

- **Linux with Omarchy.** Omarchy is a ready-made Arch Linux desktop (Hyprland). It is a separate project: get it at [omarchy.org](https://omarchy.org). Other Linux desktops, Windows and macOS are not supported in this beta.
- **A Microsoft Surface Dial**, paired over Bluetooth.
- **The beta installer**, `redial-0.9.1.5-installer.sh`, from the [release page](https://github.com/bybrooksco/redial/releases/tag/v0.9.1.5).
- **About ten minutes** to install, and a willingness to restart your shell once.
- **A normal week of use.** Use it for the work you already do.

The installer only changes your own user, shows a plan, and asks before it does anything. It asks separately before using `sudo` for a udev rule (so the dial can be read) and for adding you to the `input` group. Read [SECURITY.md](../SECURITY.md) before you agree. The software sends nothing anywhere, and `uninstall.sh` removes it.

## Hardware basics

- **The Dial.** Microsoft stopped making it, so used ones are the usual source. It runs on batteries and connects over Bluetooth. If yours seems dead, try fresh batteries first.
- **Pairing.** Hold the small button on the underside until the white light flashes. Then pair it from your Bluetooth settings, or run `redial-setup`, which checks and tells you what is missing.
- **Used with another computer before?** Remove it from that computer's Bluetooth list first, because a dial remembers its last partner. Pairing a dial that was used elsewhere is untested, so tell us how it goes.
- **Your computer** needs Bluetooth and Omarchy. If you are not sure your machine will run Omarchy, check the Omarchy site before installing anything.
- **Where to put it.** Somewhere your hand rests naturally, near the keyboard or mouse. It is a desk knob and does not sit on the screen.
- **Optional: a Surface Pen.** The software supports the pen's buttons and eraser. You do not need one to test.

This is basic guidance from one person's setup, not a buying guide.

## What to try

The most useful thing you can tell us is **where you got confused or annoyed.** "I didn't understand this" helps as much as "this is broken." You are not being tested; if something is hard, that is the software's fault.

**First day**, in any order:

1. Before you read or open anything, turn the dial. What happened on screen? Did you know what it was doing?
2. Open the settings: Omarchy menu (`SUPER+SPACE`) > **Setup > re:dial**.
3. Hold the dial's button until a menu appears, turn to pick a different tool (for example Scroll), and let go. Use it to scroll a long page.
4. Click once, twice and three times. Did you know what each would do?
5. On the **Feel** page, change one thing, such as Sensitivity. Did the dial feel different straight away?
6. Short hints appear on screen while you learn. Were they clear, too soon, or annoying? You can turn them off on the Feel page or change the style.

**Over the week**, use it for ordinary work and notice when you reach for it and when you do not:

- What made you not use it?
- Did anything surprise you or happen by accident?
- Was anything hard to read or click, or too fast or too small?
- Is there something you wanted it to do that it could not?
- Would you keep using it (yes, maybe, no), and why, in a sentence?

Things not yet checked: other people's hands, screen readers, other machines and themes, and pairing a dial that was used elsewhere first.

## How to report

Reply to the email, or [open an issue](https://github.com/bybrooksco/redial/issues). A short list is perfect: **what you did, what you expected, what happened.** Blank answers are fine.

If something goes wrong, include:

1. The version: the settings window's **Help** page, or `redial-hypr --version`.
2. The output of `redial-setup`. It checks everything and says what to fix.
3. Anything relevant from `~/.local/state/redial/daemon.log`.

**Read logs and screenshots before you send them.** The log can contain window names. It does not record what you type.

A feedback sheet, [FEEDBACK.md](../FEEDBACK.md), can be copied into an email if you would like a guide. You can stop at any time. To remove everything:

```
bash ~/.local/share/redial-beta/redial-0.9.1.5/uninstall.sh
```

---

An independent project. "Surface Dial" and "Surface Pen" are Microsoft's names, used only to say which hardware it works with. It is not made or endorsed by Microsoft or Omarchy. Free and MIT licensed, provided as is.
