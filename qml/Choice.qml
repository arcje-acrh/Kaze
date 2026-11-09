// Choice.qml -- retro keys: LED + label, one lit (as in the shell's Seg). `options` = labels, `current` = lit one.
import QtQuick

Row {   // retro keys: LED + label, one lit (as in the shell's Seg)
    id: ch
    property var options: []         // labels
    property int current: -1
    signal picked(int index)
    spacing: 4
    Repeater {
        model: ch.options
        delegate: Rectangle {
            required property int index
            required property string modelData
            readonly property bool on: ch.current === index
            objectName: "choice:" + modelData
            width: cl.implicitWidth + 28; height: 28; radius: 2
            color: on ? Theme.bg : cma.containsMouse ? Theme.hover : Theme.raised
            border.width: on ? 1 : 0; border.color: Theme.hairline
            Rectangle {
                x: 8; anchors.verticalCenter: parent.verticalCenter
                width: 5; height: 5; radius: 2.5
                color: parent.on ? Theme.coral : Theme.dim
                Rectangle { visible: parent.parent.on; anchors.centerIn: parent; width: 11; height: 11; radius: 5.5; z: -1; color: Qt.alpha(Theme.coral, 0.3) }
            }
            Text { id: cl; x: 18; anchors.verticalCenter: parent.verticalCenter; text: parent.modelData; color: parent.on ? Theme.text : Theme.muted; font.family: Theme.font; font.pixelSize: 12; font.bold: true }
            MouseArea { id: cma; anchors.fill: parent; hoverEnabled: true; onClicked: ch.picked(parent.index) }
        }
    }
}
