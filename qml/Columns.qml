// Columns.qml -- Finder's column view, two levels deep: the current folder and its parent (never above the pane's
// `base` = the folder last opened from the sidebar), plus Details (preview + facts) of the highlighted item -- or of
// the folder you are in -- on the right. In x/y/z/a/b you see a | b | details. A click on a folder opens it; the arrows
// move the highlight without opening (→ / Enter open, ← goes back).
// The columns live in a ListModel that is synced (drop / add at either end), so moving around keeps loaded columns.
import QtQuick

FocusScope {
    id: root
    property var hub
    property Item current      // the column of the current folder (status bar, select all)

    function under(p, b) { return p === b || p.startsWith(b === "/" ? "/" : b + "/") }
    readonly property var cols: {
        const out = []
        out.push(hub.dir)
        if (hub.dir !== hub.base && hub.dir !== "/") out.unshift(Fs.parent(hub.dir))   // two levels: parent | current
        return out
    }
    onColsChanged: {
        while (cm.count && cols.indexOf(cm.get(0).path) < 0) cm.remove(0)          // went off the left
        const j = cm.count ? cols.indexOf(cm.get(0).path) : cols.length
        for (let i = 0; i < j; i++) cm.insert(i, { path: cols[i] })                // came in on the left
        let k = 0
        while (k < cm.count && k < cols.length && cm.get(k).path === cols[k]) k++
        if (k < cm.count) cm.remove(k, cm.count - k)
        for (; k < cols.length; k++) cm.append({ path: cols[k] })
    }

    // Finder: folder columns keep one width (up to 340), the preview takes the rest -- its picture grows with it.
    // A narrow window shrinks the columns (down to 140) before the preview gets under 280.
    readonly property real colWidth: Math.max(140, Math.min(340, (width - 280) / Math.max(1, cm.count)))

    ListModel { id: cm }

    Flickable {
        id: fl
        anchors.fill: parent
        contentWidth: row.width
        flickableDirection: Flickable.HorizontalFlick
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        onContentWidthChanged: contentX = Math.max(0, contentWidth - width)
        Row {
            id: row
            height: fl.height
            Repeater {
                model: cm
                delegate: Items {
                    id: col
                    required property string path
                    required property int index
                    objectName: "col:" + path
                    width: root.colWidth; height: row.height
                    hub: root.hub
                    mode: "compact"
                    folder: path
                    active: path === root.hub.dir
                    focus: active
                    sel: active ? root.hub.sel : (root.cols[index + 1] ? [root.cols[index + 1]] : [])
                    cur: active ? root.hub.cur : (root.cols[index + 1] || "")
                    onActiveChanged: if (active) root.current = col
                    Component.onCompleted: if (active) root.current = col
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.hairline }
                }
            }
            Details {   // preview + facts of the highlighted item, else of the folder just opened
                width: Math.max(280, fl.width - cm.count * root.colWidth)
                height: row.height
                win: root.hub.win
                path: root.hub.cur || root.hub.dir
            }
        }
    }
}
