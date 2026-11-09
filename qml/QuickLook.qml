// QuickLook.qml -- Space: a floating panel over the window with a big preview of the file under the cursor.
// The arrow keys keep moving the cursor underneath, so the preview follows. Space / Esc / a click outside closes it.
import QtQuick

Item {
    id: root
    property string path
    visible: false
    property var info: ({})
    readonly property string want: visible ? path : ""
    onWantChanged: { info = ({}); if (want) Fs.askInfo(want) }
    Connections { target: Fs; function onInfoReady(p, m) { if (p === root.want) root.info = m } }

    Rectangle { anchors.fill: parent; color: Qt.alpha(Theme.shadow, 0.35) }
    MouseArea { anchors.fill: parent; onClicked: root.visible = false }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 1100); height: parent.height - 80
        radius: 10
        color: Theme.surface
        border.width: 1; border.color: Theme.hairline
        MouseArea { anchors.fill: parent }   // clicks inside stay

        Item {
            id: title
            width: parent.width; height: 44
            Key { x: 10; anchors.verticalCenter: parent.verticalCenter; icon: Theme.g("close"); onClicked: root.visible = false }
            Text {
                anchors.centerIn: parent
                width: parent.width - 260; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideMiddle
                text: root.path.split("/").pop(); color: Theme.text
                font.family: Theme.font; font.pixelSize: 13; font.bold: true
            }
            Rectangle {   // "Open" pill
                visible: root.info.dir === false
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                width: openText.implicitWidth + 24; height: 26; radius: 6
                color: om.pressed ? Qt.darker(Theme.coral, 1.1) : Theme.coral
                Text { id: openText; anchors.centerIn: parent; text: "Open"; color: Theme.onAccent; font.family: Theme.font; font.pixelSize: 12; font.bold: true }
                MouseArea { id: om; anchors.fill: parent; onClicked: { Fs.open(root.path); root.visible = false } }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
        }

        Preview {
            anchors { left: parent.left; right: parent.right; top: title.bottom; bottom: foot.top; margins: 20 }
            path: root.visible ? root.path : ""
            big: true
        }

        Text {
            id: foot
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 14 }
            text: [root.info.type, root.info.size, root.info.modified ? "modified " + root.info.modified : ""].filter(x => x).join("  –  ")
            color: Theme.muted; font.family: Theme.font; font.pixelSize: 12
        }
    }
}
