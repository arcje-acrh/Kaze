// Menu.qml -- the right-click menu (macOS style). show(items, x, y): items = [{ text, key, run, warn }] or { sep: true }.
// A `warn` item asks "Confirm?" and needs a second click.
import QtQuick

Item {
    id: root
    visible: false
    property var items: []
    signal closed()
    function show(list, x, y) {
        items = list
        box.x = Math.max(4, Math.min(x, width - box.width - 4))
        box.y = Math.max(4, Math.min(y, height - box.height - 4))
        visible = true
    }
    function close() { visible = false; closed() }

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onPressed: root.close() }

    Rectangle {   // soft shadow
        x: box.x; y: box.y + 4; width: box.width; height: box.height; radius: box.radius
        color: Qt.alpha(Theme.shadow, 0.25)
    }
    Rectangle {
        id: box
        width: 260; height: col.height + 10
        color: Theme.surface; radius: 8
        border.width: 1; border.color: Theme.hairline
        Column {
            id: col
            x: 5; y: 5; width: parent.width - 10
            Repeater {
                model: root.items
                delegate: Rectangle {
                    id: it
                    required property var modelData
                    property bool armed: false
                    objectName: "menuitem:" + (modelData.text || "")
                    width: col.width; height: modelData.sep ? 11 : 26; radius: 5
                    color: !modelData.sep && m.containsMouse ? Theme.coral : "transparent"
                    Rectangle { visible: !!it.modelData.sep; anchors.centerIn: parent; width: parent.width - 16; height: 1; color: Theme.hairline }
                    Text {
                        visible: !it.modelData.sep
                        x: 12; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x - keyText.implicitWidth - 24
                        elide: Text.ElideMiddle
                        text: it.armed ? "Click again to confirm" : (it.modelData.text || "")
                        color: m.containsMouse ? Theme.onAccent : it.modelData.warn || it.armed ? Theme.warn : Theme.text
                        font.family: Theme.font; font.pixelSize: 13
                    }
                    Text {
                        id: keyText
                        visible: !it.modelData.sep
                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: it.modelData.key || ""
                        color: m.containsMouse ? Theme.onAccent : Theme.dim; font.family: Theme.font; font.pixelSize: 12
                    }
                    MouseArea {
                        id: m
                        anchors.fill: parent; enabled: !it.modelData.sep; hoverEnabled: true
                        onClicked: {
                            if (it.modelData.warn && !it.armed) { it.armed = true; return }
                            root.close()
                            it.modelData.run()
                        }
                    }
                }
            }
        }
    }
}
