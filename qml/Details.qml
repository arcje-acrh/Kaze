// Details.qml -- the preview of a file or folder with its facts under it: size (a folder is counted on a worker, its
// own drive only; the count stops when you move on), what a folder holds, where it is, dates, permissions, owner.
// Column view shows it on the right; list / icon view as a side panel (Ctrl+I). A folder's look is set elsewhere
// (right-click > Change Look…).
import QtQuick

Item {
    id: root
    objectName: "details"
    property var win
    property string path
    property var info: ({})
    property string total: ""
    property string holds: ""
    property string counting: ""
    property var media: []                // [label, value] rows from inside the file (Fs.askMedia)          // the folder being counted (to stop it when we move on)
    readonly property bool dir: path !== "" && Fs.isDir(path)
    readonly property var look: dir ? win.look(path) : ({})

    onPathChanged: {
        info = ({}); total = ""; holds = ""; media = []
        if (counting) { Fs.stopDirSize(counting); counting = "" }
        if (path) { Fs.askInfo(path); Qt.callLater(() => { if (root.path && !root.dir) Fs.askMedia(root.path, Fs.kind(root.path, false)) }) }
        later.restart()
    }
    Timer {   // count only once the highlight rests here (arrowing past folders starts nothing)
        id: later; interval: 250
        onTriggered: if (root.dir) { root.counting = root.path; Fs.askDirSize(root.path) }
    }
    Component.onDestruction: if (counting) Fs.stopDirSize(counting)
    Connections {
        target: Fs
        function onInfoReady(p, m) { if (p === root.path) root.info = m }
        function onMediaReady(p, rows) { if (p === root.path) root.media = rows }
        function onJobDone(verb, name, how) { if (root.path && verb.startsWith("Changing")) Fs.askInfo(root.path) }   // after Properties changed it
        function onDirSizeReady(d, bytes, files, folders, done) {   // also while counting (done false): the counts so far
            if (d !== root.path) return
            if (done) root.counting = ""
            root.total = Fs.size(bytes) + (done ? "" : "…")
            root.holds = (((files ? files + (files === 1 ? " file" : " files") : "") + (files && folders ? ", " : "")
                       + (folders ? folders + (folders === 1 ? " folder" : " folders") : "")) || (done ? "Empty" : "Counting")) + (done ? "" : "  so far…")
        }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: col.height + 56
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        acceptedButtons: Qt.NoButton
        Column {
            id: col
            width: Math.min(root.width - 48, 640)          // grows with a wide window
            x: (root.width - width) / 2; y: Math.max(20, root.height * 0.05)

            Preview {
                objectName: "preview"
                width: parent.width
                height: root.dir ? Math.max(112, Math.min(200, width * 0.32)) : Math.min(width, Math.max(140, root.height * 0.5))
                path: root.path
                look: root.look
            }
            Item { width: 1; height: 14 }
            Text {
                width: parent.width; horizontalAlignment: Text.AlignHCenter
                text: root.path ? root.win.name(root.path) : ""
                wrapMode: Text.WrapAnywhere; maximumLineCount: 2; elide: Text.ElideMiddle
                color: Theme.text; font.family: Theme.font; font.pixelSize: 15; font.bold: true
            }
            Item { width: 1; height: 4 }
            Text {
                width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                text: [root.info.type, root.dir ? (root.total || "…") : (root.info.size || "").split(" (")[0]].filter(x => x).join("  ·  ")
                color: Theme.muted; font.family: Theme.font; font.pixelSize: 12
            }
            Item { width: 1; height: 16 }

            Grid {   // the facts: label | value, side by side
                columns: 2
                columnSpacing: 14; rowSpacing: 7
                Repeater {
                    model: [
                        ["Contains", root.dir ? (root.holds || "Counting…") : ""],
                        ["Size", root.dir ? "" : (root.info.size || "")]].concat(root.media).concat([
                        ["Where", Fs.archiveOf(root.path) ? Fs.parent(Fs.archiveOf(root.path)).replace(Fs.home, "~") : root.info.where || ""],
                        ["Links to", root.info.link || ""],
                        ["Created", root.info.created || ""],
                        ["Modified", root.info.modified || ""],
                        ["Opened", root.dir ? "" : (root.info.opened || "")],
                        ["Access", root.info.perms ? root.info.perms + "  " + root.info.octal : ""],
                        ["Owner", root.info.owner ? root.info.owner + (root.info.group && root.info.group !== root.info.owner ? " : " + root.info.group : "") : ""]
                    ]).filter(r => r[1] !== "").reduce((a, r) => a.concat([{ t: r[0], label: true }, { t: r[1], label: false }]), [])
                    delegate: Text {
                        required property var modelData
                        width: modelData.label ? 76 : col.width - 90
                        text: modelData.t
                        horizontalAlignment: modelData.label ? Text.AlignRight : Text.AlignLeft
                        elide: Text.ElideMiddle
                        color: modelData.label ? Theme.dim : Theme.text
                        font.family: Theme.font; font.pixelSize: 12
                        font.features: { "calt": 0, "liga": 0 }   // "rwx------" stays dashes, not one joined line
                    }
                }
            }

        }
    }
}
