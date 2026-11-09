// Usage.qml -- what takes the space in a folder: each item with an LED bar (against the biggest), its size and share,
// biggest first. Click a folder to go into it, Back to come out; "Show in Kaze" opens the folder in the pane.
// Counting happens on a worker (Fs.askUsage), each folder on its own drive only.
import QtQuick

Item {
    id: root
    visible: false
    property var win
    property string dir: ""
    property var trail: []        // folders entered, for Back
    property var rows: []
    property real total: -1
    signal closed()
    function show(d) { trail = []; go(d); visible = true; root.forceActiveFocus() }
    function go(d) { dir = d; rows = []; total = -1; Fs.askUsage(d) }
    function enter(d) { trail = trail.concat([dir]); go(d) }
    function back() { if (!trail.length) return; const t = trail.slice(); go(t.pop()); trail = t }
    function close() { visible = false; closed() }
    Connections {
        target: Fs
        function onUsageReady(d, r, t) { if (d === root.dir) { root.rows = r; root.total = t } }
        function onTouched(d) { if (root.visible && d === root.dir) root.go(root.dir) }
    }
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Escape) close()
        else if (e.key === Qt.Key_Backspace) back()
        else return
        e.accepted = true
    }

    Rectangle { anchors.fill: parent; color: Qt.alpha(Theme.shadow, 0.3) }
    MouseArea { anchors.fill: parent; onPressed: root.close() }
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 60
        width: Math.min(parent.width - 40, 640); height: Math.min(parent.height - 100, col.height + 40)
        color: Theme.surface; radius: 10
        border.width: 1; border.color: Theme.hairline
        MouseArea { anchors.fill: parent }
        Column {
            id: col
            x: 20; y: 20; width: parent.width - 40
            spacing: 12
            Row {
                width: parent.width; spacing: 10
                Key { visible: root.trail.length > 0; icon: Theme.g("back"); size: 18; onClicked: root.back(); anchors.verticalCenter: parent.verticalCenter }
                Column {
                    width: parent.width - 40 - (root.trail.length ? 42 : 0)
                    spacing: 2
                    Text { width: parent.width; elide: Text.ElideMiddle; text: "Disk usage of “" + root.win.name(root.dir) + "”"; color: Theme.text; font.family: Theme.font; font.pixelSize: 14; font.bold: true }
                    Text {
                        width: parent.width; elide: Text.ElideMiddle
                        text: root.total < 0 ? "Counting…" : Fs.size(root.total) + " in " + root.rows.length + (root.rows.length === 1 ? " item" : " items") + "  ·  " + root.dir.replace(Fs.home, "~")
                        color: Theme.muted; font.family: Theme.font; font.pixelSize: 11
                    }
                }
            }
            ListView {
                id: lv
                objectName: "usageList"
                width: parent.width; height: Math.min(contentHeight, root.height - 260)
                clip: true; boundsBehavior: Flickable.StopAtBounds
                model: root.rows
                delegate: Rectangle {
                    id: r
                    required property var modelData
                    width: lv.width; height: 30; radius: 4
                    color: rm.containsMouse && modelData.dir ? Theme.fill : "transparent"
                    readonly property real most: root.rows.length ? Math.max(1, root.rows[0].bytes) : 1
                    Text {
                        x: 8; width: parent.width * 0.38; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideMiddle
                        text: (r.modelData.dir ? Theme.g("folder") + "  " : "") + r.modelData.name
                        color: r.modelData.dir ? Theme.text : Theme.muted; font.family: Theme.font; font.pixelSize: 12
                    }
                    LedBar {
                        x: parent.width * 0.38 + 16; width: parent.width * 0.38; segH: 8
                        anchors.verticalCenter: parent.verticalCenter
                        frac: r.modelData.bytes / r.most
                    }
                    Text {
                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        text: r.modelData.size + (root.total > 0 ? "  " + String(Math.round(100 * r.modelData.bytes / root.total)).padStart(3) + " %" : "")
                        color: Theme.muted; font.family: Theme.font; font.pixelSize: 11
                        font.features: { "calt": 0, "liga": 0 }
                    }
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; onClicked: if (r.modelData.dir && r.modelData.bytes > 0) root.enter(r.modelData.path) }
                }
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                Btn { label: "Show in Kaze"; onHit: { root.win.pane.go(root.dir); root.close() } }
                Btn { label: "Close"; primary: true; onHit: root.close() }
            }
        }
    }
}
