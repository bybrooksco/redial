.pragma library

// The Live peek: the overlay shown from the settings window while the dial is not turning.
// Kept apart from DialMenu so it is testable without the Omarchy shell.
// s: { opened (the overlay is up), liveDriven (the dial put it there) }

// Pressing Live: hide a peek that is showing, else show one. Never hides the dial's own ring.
function toggle(s) { return s.opened && !s.liveDriven ? "close" : "open" }

// The settings window closed (Close, Escape, Super+W): a peek goes with it; the dial's ring stays.
function closesWithSettings(s) { return s.opened && !s.liveDriven }
