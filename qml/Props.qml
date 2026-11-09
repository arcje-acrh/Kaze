// Props.qml -- Properties (right-click > Properties…): the facts about one file or folder, and the only place its
// access and owner can be changed. Access = read / write / run (open, for a folder) keys for owner, group and others:
// a click changes it at once (Fs.chmod, undoable); a folder can pass its access to everything inside. Owner: a menu ->
// "user:group" (asks for the password only when your own rights are not enough). Everything wraps or elides: no row
// is wider than the sheet.
import QtQuick

Item {
    id: root
    visible: false
    property var win
    property string path: ""
    property var info: ({})
    readonly property bool dir: !!info.dir
    readonly property bool canChange: !!info.octal && !Fs.inArchive(path)
    readonly property int mode: parseInt(info.octal || "0", 8)
    signal closed()
    function show(p) { path = p; info = ({}); Fs.askInfo(p); visible = true; root.forceActiveFocus() }
    function close() { visible = false; closed() }
    Connections {
        target: Fs
        function onInfoReady(p, m) { if (p === root.path) root.info = m }
        function onJobDone(verb, name, how) { if (root.visible && verb.startsWith("Changing")) Fs.askInfo(root.path) }
    }
    Keys.onEscapePressed: close()

    Rectangle { anchors.fill: parent; color: Qt.alpha(Theme.shadow, 0.3) }
    MouseArea { anchors.fill: parent; onPressed: root.close() }
    Rectangle {
        id: card
        objectName: "propsCard"
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(20, Math.min(70, parent.height * 0.08))
        width: Math.min(parent.width - 40, 480); height: Math.min(parent.height - y - 20, col.height + 40)
        color: Theme.surface; radius: 10
        border.width: 1; border.color: Theme.hairline
        clip: true
        MouseArea { anchors.fill: parent }
        Flickable {
            anchors { fill: parent; margins: 20 }
            contentHeight: col.height; clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: col
                width: parent.width
                spacing: 10
                readonly property int labelW: 76
                readonly property int valueW: width - labelW - 14

                Row {
                    width: parent.width; spacing: 12
                    FileIcon { width: 40; height: 40; path: root.path; kind: Fs.kind(root.path, root.dir); suffix: root.path.split("/").pop().split(".").slice(1).pop() || "" }
                    Column {
                        width: parent.width - 52; anchors.verticalCenter: parent.verticalCenter
                        spacing: 3
                        Text { width: parent.width; elide: Text.ElideMiddle; text: root.path ? root.win.name(root.path) : ""; color: Theme.text; font.family: Theme.font; font.pixelSize: 14; font.bold: true }
                        Text { width: parent.width; elide: Text.ElideRight; text: [root.info.type, root.info.size].filter(x => x).join("  ·  "); color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    }
                }
                Rectangle { width: parent.width; height: 1; color: Theme.hairline }

                component Fact: Row {
                    property string label
                    property string value
                    visible: value !== ""
                    spacing: 14
                    Text { width: col.labelW; horizontalAlignment: Text.AlignRight; text: parent.label; color: Theme.dim; font.family: Theme.font; font.pixelSize: 12 }
                    Text { width: col.valueW; text: parent.value; wrapMode: Text.WrapAnywhere; maximumLineCount: 3; elide: Text.ElideMiddle; color: Theme.text; font.family: Theme.font; font.pixelSize: 12 }
                }
                Fact { label: "Where"; value: Fs.archiveOf(root.path) ? Fs.parent(Fs.archiveOf(root.path)).replace(Fs.home, "~") : root.info.where || "" }
                Fact { label: "Links to"; value: root.info.link || "" }
                Fact { label: "Created"; value: root.info.created || "" }
                Fact { label: "Modified"; value: root.info.modified || "" }
                Fact { label: "Opened"; value: root.dir ? "" : (root.info.opened || "") }

                Rectangle { width: parent.width; height: 1; color: Theme.hairline; visible: root.canChange }
                // ----- access -----
                Row {
                    visible: root.canChange
                    spacing: 14
                    Text { width: col.labelW; horizontalAlignment: Text.AlignRight; text: "Access"; color: Theme.dim; font.family: Theme.font; font.pixelSize: 12; y: 3 }
                    Column {
                        id: keys
                        width: col.valueW
                        spacing: 4
                        // key width: what fits next to the 52 px names, at most 56
                        readonly property int keyW: Math.max(36, Math.min(56, Math.floor((width - 52 - 3 * 3) / 3)))
                        Repeater {
                            model: ["Owner", "Group", "Others"]
                            delegate: Row {
                                id: who
                                required property string modelData
                                required property int index
                                spacing: 3
                                Text { width: 52; elide: Text.ElideRight; text: who.modelData; color: Theme.muted; font.family: Theme.font; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
                                Repeater {
                                    model: root.dir ? ["read", "write", "open"] : ["read", "write", "run"]
                                    delegate: Rectangle {
                                        id: bit
                                        required property string modelData
                                        required property int index
                                        readonly property int mask: 1 << (8 - who.index * 3 - index)
                                        readonly property bool on: (root.mode & mask) !== 0
                                        objectName: "perm:" + who.modelData + ":" + modelData
                                        width: keys.keyW; height: 22; radius: 2
                                        color: on ? Qt.alpha(Theme.coral, 0.16) : bm.containsMouse ? Theme.hover : Theme.raised
                                        border.width: on ? 1 : 0; border.color: Qt.alpha(Theme.coral, 0.6)
                                        Text { anchors.centerIn: parent; width: parent.width - 4; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: bit.modelData; color: bit.on ? Theme.text : Theme.dim; font.family: Theme.font; font.pixelSize: 11 }
                                        MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true; onClicked: Fs.chmod([root.path], root.mode ^ bit.mask, false) }
                                    }
                                }
                            }
                        }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: (root.info.perms || "") + "  " + (root.info.octal || "")
                            color: Theme.dim; font.family: Theme.font; font.pixelSize: 11; font.features: { "calt": 0, "liga": 0 }
                        }
                        Btn {
                            objectName: "applyInside"
                            visible: root.dir; height: 24
                            width: Math.min(parent.width, implicitWidth)
                            label: "Apply to everything inside"
                            onHit: Fs.chmod([root.path], root.mode, true)
                        }
                    }
                }
                // ----- owner -----
                Row {
                    visible: !!root.info.owner && !Fs.inArchive(root.path)
                    spacing: 14
                    Text { width: col.labelW; horizontalAlignment: Text.AlignRight; text: "Owner"; color: Theme.dim; font.family: Theme.font; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                    Rectangle {
                        objectName: "owner"
                        width: Math.min(col.valueW, ownerText.implicitWidth + 16); height: 24; radius: 4
                        color: om.containsMouse ? Theme.fill : "transparent"
                        Text {
                            id: ownerText
                            x: 8; width: parent.width - 16; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideMiddle
                            text: (root.info.owner || "") + " : " + (root.info.group || "") + "   " + Theme.g("chevron")
                            color: Theme.text; font.family: Theme.font; font.pixelSize: 12
                        }
                        MouseArea {
                            id: om; anchors.fill: parent; hoverEnabled: true
                            onClicked: {
                                const p = root.path, w = mapToItem(null, 0, height)
                                const change = deep => root.win.ask(deep ? "Owner of “" + root.win.name(p) + "” and everything inside" : "Owner of “" + root.win.name(p) + "”",
                                                                    root.info.owner + ":" + root.info.group, -1, t => { Fs.chown([p], t.trim(), deep); return "" })
                                root.win.showMenu([{ text: "Change Owner…", run: () => change(false) }]
                                                  .concat(root.dir ? [{ text: "Change Owner of Everything Inside…", run: () => change(true) }] : []), w.x, w.y)
                            }
                        }
                    }
                }
                Item { width: 1; height: 4 }
                Btn { anchors.right: parent.right; label: "Close"; primary: true; onHit: root.close() }
            }
        }
    }
}
