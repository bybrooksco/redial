import QtQuick
// A user-installed language for tst_languages.qml, loaded from an absolute path.
QtObject {
  readonly property string name: "Sample"
  readonly property var looks: ({ "capsule": "Capsule.qml" })
  readonly property string defaultLook: "capsule"
}
