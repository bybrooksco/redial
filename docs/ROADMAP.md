# Roadmap to 1.0

Surface Dial for Omarchy is in **beta**. Version numbers say how close it is; 1.0 means "ready for
people who are not the author, including people who depend on it to use a computer".

## 0.9.7: first beta (now)

A few people who already run Omarchy and own a Surface Dial install it and use it for ordinary
work. The aim is to find what the author cannot see: things that are confusing, things that break
on a different machine, things that feel wrong in a different hand.

## 0.9.8: what the first testers found

Fixes and clarifications from the first round of notes. No new features unless a tester's problem
needs one. Re-run the full checks, rebuild the package, send it back to the same people.

## 0.9.9: release candidate

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
