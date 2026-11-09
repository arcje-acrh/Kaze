// Conflicts.qml -- a paste / drop meets names that are taken: per item Keep Both ("x (2)"), Replace (the one there
// goes to the Trash; deleted on a network share), Skip, or Merge (folder into folder: what is missing is added, newer
// files replace older). "All" sets every row. Enter = Continue, Esc = cancel the whole paste.
import QtQuick

Item {
    id: root
    visible: false
    property int job: 0
    property var items: []
    property var picks: []
    property string verb: ""
    property string dest: ""
    signal closed()
    readonly property var label: ({ both: "Keep Both", merge: "Merge", replace: "Replace", skip: "Skip" })
    readonly property var keyOf: ({ "Keep Both": "both", "Merge": "merge", "Replace": "replace", "Skip": "skip" })
    function opts(it) { return it.dir && it.theirDir ? ["Keep Both", "Merge", "Replace", "Skip"] : ["Keep Both", "Replace", "Skip"] }
    function show(id, list, v, d) {
        job = id; items = list; verb = v; dest = d
        picks = list.map(() => "both")
        visible = true
        root.forceActiveFocus()
    }
    function setAll(k) { picks = items.map(it => k === "merge" && !(it.dir && it.theirDir) ? "both" : k) }
    function finish(go) { Fs.resolve(job, go ? picks : []); visible = false; closed() }

    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) finish(true)
        else if (e.key === Qt.Key_Escape) finish(false)
        else return
        e.accepted = true
    }
    Rectangle { anchors.fill: parent; color: Qt.alpha(Theme.shadow, 0.3) }
    MouseArea { anchors.fill: parent }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 70
        width: Math.min(parent.width - 40, 560); height: col.height + 40
        color: Theme.surface; radius: 10
        border.width: 1; border.color: Theme.hairline
        Column {
            id: col
            x: 20; y: 20; width: parent.width - 40
            spacing: 12
            Text {
                width: parent.width; wrapMode: Text.Wrap
                text: (root.items.length === 1 ? "“" + (root.items[0] || {}).name + "” is" : root.items.length + " items are") + " already in “" + root.dest.split("/").pop() + "”"
                color: Theme.text; font.family: Theme.font; font.pixelSize: 14; font.bold: true
            }
            Row {
                visible: root.items.length > 1
                spacing: 12
                Text { text: "All"; width: 40; anchors.verticalCenter: parent.verticalCenter; color: Theme.dim; font.family: Theme.font; font.pixelSize: 12 }
                Choice {
                    objectName: "all"
                    options: root.items.some(it => it.dir && it.theirDir) ? ["Keep Both", "Merge", "Replace", "Skip"] : ["Keep Both", "Replace", "Skip"]
                    current: root.picks.every(p => p === root.picks[0]) ? options.indexOf(root.label[root.picks[0]]) : -1
                    onPicked: (i) => root.setAll(root.keyOf[options[i]])
                }
            }
            Flickable {
                width: parent.width; height: Math.min(list.height, root.height - 300)
                contentHeight: list.height; clip: true
                boundsBehavior: Flickable.StopAtBounds
                Column {
                    id: list
                    width: parent.width
                    Repeater {
                        model: root.items
                        delegate: Item {
                            id: row
                            required property var modelData
                            required property int index
                            width: list.width; height: facts.height + choice.height + 26
                            Rectangle { visible: row.index > 0; width: parent.width; height: 1; color: Theme.hairline }
                            Column {
                                id: facts
                                y: 10; width: parent.width
                                spacing: 3
                                Text { width: parent.width; elide: Text.ElideMiddle; text: row.modelData.name; color: Theme.text; font.family: Theme.font; font.pixelSize: 13; font.bold: true }
                                Text {
                                    width: parent.width; elide: Text.ElideRight
                                    text: "This one: " + [row.modelData.dir ? "folder" : row.modelData.size, row.modelData.date].join("  ·  ") + (row.modelData.newer ? "  (newer)" : "")
                                    color: Theme.muted; font.family: Theme.font; font.pixelSize: 11
                                }
                                Text {
                                    width: parent.width; elide: Text.ElideRight
                                    text: "There:      " + [row.modelData.theirDir ? "folder" : row.modelData.theirSize, row.modelData.theirDate].join("  ·  ") + (row.modelData.newer ? "" : "  (newer)")
                                    color: Theme.muted; font.family: Theme.font; font.pixelSize: 11
                                }
                            }
                            Choice {
                                id: choice
                                objectName: "pick:" + row.modelData.name
                                y: facts.y + facts.height + 8
                                options: root.opts(row.modelData)
                                current: options.indexOf(root.label[root.picks[row.index]])
                                onPicked: (i) => { const p = root.picks.slice(); p[row.index] = root.keyOf[options[i]]; root.picks = p }
                            }
                        }
                    }
                }
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                visible: root.picks.indexOf("replace") >= 0
                text: "What is replaced goes to the Trash (on a network share it is deleted)."
                color: Theme.amber; font.family: Theme.font; font.pixelSize: 11
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                Btn { label: "Cancel"; onHit: root.finish(false) }
                Btn { objectName: "conflicts:go"; label: root.verb === "Moving" ? "Move" : "Copy"; primary: true; onHit: root.finish(true) }
            }
        }
    }
}
