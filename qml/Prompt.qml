// Prompt.qml -- a small sheet with one line of input (rename, new folder, go to folder). ask(title, text, selectTo, done):
// `done(text)` returns an error message to show, or "" to close. Enter = OK, Esc = cancel.
// confirm(title, text, okLabel, done): the same sheet as a question (no input), e.g. "Delete permanently?".
import QtQuick

Item {
    id: root
    visible: false
    property var done
    property bool plain: false     // a question, no input
    property string okLabel: "OK"
    signal closed()
    property var nope: null        // confirm: called when it is answered no (Esc, Cancel, a click outside)
    function confirm(title, text, ok, cb, no) {
        head.text = title; body.text = text; err.text = ""; okLabel = ok; plain = true
        nope = no || null
        done = () => { nope = null; cb(); return "" }
        visible = true
        root.forceActiveFocus()
    }
    function ask(title, text, selectTo, cb) {
        nope = null
        head.text = title; input.text = text; err.text = ""; done = cb; plain = false; okLabel = "OK"
        visible = true
        input.forceActiveFocus()
        input.select(0, selectTo < 0 ? text.length : selectTo)
    }
    function accept() { const m = root.done(input.text); if (m) err.text = m; else close() }
    function close() { visible = false; if (nope) { const n = nope; nope = null; n() } closed() }

    Keys.onPressed: (e) => {   // the question (no input): Enter = yes, Esc = no
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) root.accept()
        else if (e.key === Qt.Key_Escape) root.close()
        else return
        e.accepted = true
    }
    Rectangle { anchors.fill: parent; color: Qt.alpha(Theme.shadow, 0.3) }
    MouseArea { anchors.fill: parent; onPressed: root.close() }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 80
        width: 440; height: col.height + 40
        color: Theme.surface; radius: 10
        border.width: 1; border.color: Theme.hairline
        MouseArea { anchors.fill: parent }
        Column {
            id: col
            x: 20; y: 20; width: parent.width - 40
            spacing: 12
            Text { id: head; width: parent.width; wrapMode: Text.Wrap; color: Theme.text; font.family: Theme.font; font.pixelSize: 14; font.bold: true }
            Text { id: body; visible: root.plain; width: parent.width; wrapMode: Text.Wrap; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Rectangle {
                visible: !root.plain
                width: parent.width; height: 32; radius: 6
                color: Theme.bg
                border.width: 2; border.color: Qt.alpha(Theme.coral, 0.6)
                TextInput {
                    id: input
                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: Theme.text; selectionColor: Theme.coral; selectedTextColor: Theme.onAccent
                    font.family: Theme.font; font.pixelSize: 13
                    Keys.onPressed: (e) => {
                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) root.accept()
                        else if (e.key === Qt.Key_Escape) root.close()
                        else return
                        e.accepted = true
                    }
                }
            }
            Text { id: err; visible: text !== ""; width: parent.width; wrapMode: Text.Wrap; color: Theme.amber; font.family: Theme.font; font.pixelSize: 12 }
            Row {
                anchors.right: parent.right
                spacing: 8
                Btn { label: "Cancel"; onHit: root.close() }
                Btn { objectName: "prompt:ok"; label: root.okLabel; primary: !root.plain; warn: root.plain; onHit: root.accept() }
            }
        }
    }
}
