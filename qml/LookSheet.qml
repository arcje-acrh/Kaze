// LookSheet.qml -- right-click a folder > Change Look…: a small sheet to give the folder a theme colour and an
// emblem. Changes apply live (the icons behind update); Reset = back to the default; Done / Esc / a click outside closes.
import QtQuick

Item {
    id: root
    visible: false
    property var win
    property string path
    readonly property var look: path ? win.look(path) : ({})
    readonly property var chosen: Fs.looks[path] || ({})
    signal closed()
    function show(p) { path = p; visible = true }
    function close() { visible = false; closed() }
    function set(color, emblem) { Fs.setLook(path, color, emblem) }

    Rectangle { anchors.fill: parent; color: Qt.alpha(Theme.shadow, 0.3) }
    MouseArea { anchors.fill: parent; onPressed: root.close() }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 80
        width: 380; height: col.height + 40
        color: Theme.surface; radius: 10
        border.width: 1; border.color: Theme.hairline
        MouseArea { anchors.fill: parent }
        Column {
            id: col
            x: 20; y: 20; width: parent.width - 40
            spacing: 14
            Row {
                spacing: 14
                FileIcon { width: 56; height: 56; kind: "folder"; emblem: root.look.emblem || ""; tint: root.look.color || "" }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3
                    Text { text: "Change look"; color: Theme.text; font.family: Theme.font; font.pixelSize: 14; font.bold: true }
                    Text { width: 260; text: root.path.split("/").pop(); elide: Text.ElideMiddle; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                }
            }
            Text { text: "Colour"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Row {
                spacing: 8
                Repeater {
                    model: Theme.tints
                    delegate: Rectangle {
                        required property string modelData
                        readonly property bool on: (root.look.color || "accent") === modelData
                        width: 28; height: 28; radius: 14
                        color: "transparent"
                        border.width: on ? 2 : 0; border.color: Theme.text
                        Rectangle { anchors.centerIn: parent; width: 20; height: 20; radius: 10; color: Theme.tint(parent.modelData) }
                        MouseArea { anchors.fill: parent; onClicked: root.set(parent.modelData === "accent" ? "" : parent.modelData, root.chosen.emblem || "") }
                    }
                }
            }
            Text { text: "Emblem"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Flow {
                width: parent.width
                spacing: 4
                Repeater {
                    model: ["none"].concat(Theme.emblemNames)
                    delegate: Rectangle {
                        required property string modelData
                        readonly property bool on: (root.look.emblem || "none") === modelData
                        width: 30; height: 30; radius: 6
                        color: on ? Theme.fill2 : em.containsMouse ? Theme.fill : "transparent"
                        border.width: on ? 1 : 0; border.color: Theme.coral
                        Text {
                            anchors.centerIn: parent
                            text: parent.modelData === "none" ? "–" : Theme.g(parent.modelData)
                            color: parent.on ? Theme.coral : Theme.text
                            font.family: Theme.font; font.pixelSize: 15
                        }
                        MouseArea { id: em; anchors.fill: parent; hoverEnabled: true; onClicked: root.set(root.chosen.color || "", parent.modelData) }
                    }
                }
            }
            Item {
                width: parent.width; height: 30
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Reset"; color: rm.containsMouse ? Theme.text : Theme.muted; font.family: Theme.font; font.pixelSize: 12
                    MouseArea { id: rm; anchors { fill: parent; margins: -6 } hoverEnabled: true; onClicked: root.set("", "") }
                }
                Rectangle {
                    anchors.right: parent.right
                    width: 72; height: 30; radius: 6
                    color: dm.pressed ? Qt.darker(Theme.coral, 1.1) : Theme.coral
                    Text { anchors.centerIn: parent; text: "Done"; color: Theme.onAccent; font.family: Theme.font; font.pixelSize: 13; font.bold: true }
                    MouseArea { id: dm; anchors.fill: parent; onClicked: root.close() }
                }
            }
        }
    }
}
