// Btn.qml -- a sheet button: filled accent when `primary`, amber text when `warn` (deleting permanently).
import QtQuick

Rectangle {
    property string label
    property bool primary: false
    property bool warn: false
    signal hit()
    implicitWidth: Math.max(72, bt.implicitWidth + 24); implicitHeight: 28; radius: 6
    opacity: enabled ? 1 : 0.4
    color: primary ? (bma.pressed ? Qt.darker(Theme.coral, 1.1) : Theme.coral) : bma.containsMouse ? Theme.fill2 : Theme.fill
    Text { id: bt; anchors.centerIn: parent; width: Math.min(implicitWidth, parent.width - 12); elide: Text.ElideRight; text: parent.label; color: parent.primary ? Theme.onAccent : parent.warn ? Theme.amber : Theme.text; font.family: Theme.font; font.pixelSize: 13; font.bold: parent.primary }
    MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; onClicked: parent.hit() }
}
