.pragma library

// When a state from the daemon ("turn", "hint", "cant") may take the overlay, and for how long.
// Kept apart from DialMenu so it is testable without the Omarchy shell.

var MS = { turn: 1200, hint: 3500, cant: 2500 }

// now: { kind: the note showing ("" for none), ringOpen, ageMs: how long the showing note has
// been up }. The settings window is a normal window now, so a brief note may sit over it.
function accept(kind, now) {
  if (!MS[kind]) return false
  if (kind === "turn" && now.ringOpen && now.kind === "") return false   // the ring shows the tool itself
  // a level arriving under a hint or status waits until that has been readable for a second
  if (kind === "turn" && (now.kind === "hint" || now.kind === "cant") && now.ageMs < 1000) return false
  return true
}
