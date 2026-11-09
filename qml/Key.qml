// Key.qml -- a borderless toolbar button (Finder style): glyph, rounded hover fill. `on` = selected.
import QtQuick

Rectangle {
    id: root
    property string icon: ""
    property bool on: false
    property int size: 16
    signal clicked()
    width: 32; height: 28; radius: 6
    opacity: enabled ? 1 : 0.3
    color: on ? Theme.fill2 : m.pressed ? Theme.fill2 : m.containsMouse ? Theme.fill : "transparent"
    Text {
        anchors.centerIn: parent
        text: root.icon; color: root.on ? Theme.text : Theme.muted
        font.family: Theme.font; font.pixelSize: root.size
    }
    MouseArea { id: m; anchors.fill: parent; hoverEnabled: true; onClicked: root.clicked() }
}
