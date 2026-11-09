// Switch.qml -- the classy hairline switch with its label.
import QtQuick

Item {  // classy hairline switch with its label
    id: sw
    property bool checked: false
    property string label
    signal toggled()
    width: sl.x + sl.implicitWidth; height: 22
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 30; height: 14; radius: 2
        color: sw.checked ? Qt.alpha(Theme.coral, 0.18) : "transparent"
        border.width: 1; border.color: sw.checked ? Theme.coral : Theme.dim
        Rectangle {
            width: 12; height: 10; radius: 1; y: 2
            x: sw.checked ? parent.width - width - 2 : 2
            color: sw.checked ? Theme.coral : Theme.dim
            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
    }
    Text { id: sl; x: 40; anchors.verticalCenter: parent.verticalCenter; text: sw.label; color: Theme.text; font.family: Theme.font; font.pixelSize: 12 }
    MouseArea { anchors.fill: parent; onClicked: sw.toggled() }
}
