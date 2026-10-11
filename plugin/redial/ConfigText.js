.pragma library

// Read config.json text for the settings window.
//
// Returns { ok, doc }. An empty or missing file is fine (a fresh install): ok with an empty doc.
// Text that is not a JSON object is NOT fine: ok is false, and the window must neither use it
// nor write over it. A file caught mid-edit (a trailing comma) is the usual cause, and one click
// on a setting would otherwise replace the whole hand-written file with that one key.
function parse(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: true, doc: ({}) }
  try {
    var parsed = JSON.parse(text)
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return { ok: true, doc: parsed }
  } catch (e) {
  }
  return { ok: false, doc: null }
}
