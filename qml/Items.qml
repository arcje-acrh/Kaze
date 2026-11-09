// Items.qml -- the files of one folder, Finder style: "list" (striped rows, Name / Date Modified / Size / Kind,
// click a heading to sort), "grid" (icons: big icon + name pill) or "compact" (one column of the column view).
// One GridView does all three (a list = one cell per row). Clicks, drag-to-select and keys go to `hub` (Main),
// which owns the selection; `sel` / `cur` only draw it.
import QtQuick

FocusScope {
    id: root
    property var hub
    property string folder
    property string mode: "list"
    property var sel: []
    property string cur: ""
    property bool active: true
    property string query: ""                    // search this folder and all below it (results as a list)
    readonly property bool searching: query !== ""
    readonly property alias count: fm.count
    readonly property alias ready: fm.ready
    readonly property bool lit: activeFocus      // focused view = accent selection, else grey

    function where(p) {   // below this folder: the rest of the path; elsewhere (search everywhere): from ~ or /
        const d = Fs.parent(p)
        if (d === root.folder) return root.hub.win.name(d)
        if (d.startsWith(root.folder === "/" ? "/" : root.folder + "/")) return d.slice(root.folder.length + (root.folder === "/" ? 0 : 1))
        return d === Fs.home || d.startsWith(Fs.home + "/") ? "~" + d.slice(Fs.home.length) : d
    }
    function pathAt(i) { return fm.get(i, "filePath") }
    function isDirAt(i) { return fm.get(i, "fileIsDir") }
    function indexOf(p) { return p ? fm.indexOf(p) : -1 }
    function reveal() { const i = indexOf(cur); if (i >= 0) grid.positionViewAtIndex(i, GridView.Contain) }
    onCurChanged: reveal()
    onActiveChanged: if (active) forceActiveFocus()

    Folder {   // src/folder.h: read on a worker thread, so a slow or dead drive never freezes the window
        id: fm
        folder: Fs.url(root.folder)
        showHidden: root.hub.win?.hidden ?? false
        sortField: root.hub.win?.sortField ?? "name"
        sortReversed: root.hub.win?.sortReversed ?? false
        query: root.query
        everywhere: root.hub.everywhere ?? false
        onReadyChanged: if (ready) {
            root.slow = false; root.reveal(); root.hub.loaded(root)
            if (!root.searching) Fs.prefetch(root.folder)   // previews of the pictures / PDFs / videos here, made before you scroll to them
            if (error && root.active) root.hub.win.flash(error, true)
        }
    }
    Connections {
        target: Fs
        function onTouched(dir) { if (dir === root.folder && !root.searching) fm.refresh() }
        function onGitReady(dir, m) { if (dir === root.folder) root.git = m }
    }
    // git: a letter after changed names (M changed, A added, U untracked, ! conflict), asked each time the folder is read
    property var git: ({})
    onFolderChanged: git = ({})
    Connections { target: fm; function onReadyChanged() { if (fm.ready && !root.searching) Fs.askGit(root.folder) } }
    function gitColor(s, hot) { return hot ? Theme.onAccent : s === "U" ? Theme.muted : s === "A" ? Theme.coral : Theme.amber }
    property bool slow: false      // "Loading…" only for folders that take a while (a network share)
    Timer { interval: 400; running: !fm.ready; onTriggered: root.slow = true }

    // column widths as set (window) and as they fit (like Finder / Dolphin: only Name stretches with the window):
    // in a narrow pane Kind gives way first, then Date; Name keeps 120 and takes the rest
    readonly property int wantDate: hub.win?.colDate ?? 190
    readonly property int colSize: hub.win?.colSize ?? 90
    readonly property int wantKind: hub.win?.colKind ?? 180
    function fit(room, want) { const w = Math.min(want, room); return w < 60 ? 0 : w }
    // (search results: Where matters more than the date, so Date gives way first)
    readonly property int colDate: searching ? fit(width - 64 - 120 - colSize - colKind, wantDate) : fit(width - 64 - 120 - colSize, wantDate)
    readonly property int colKind: searching ? fit(width - 64 - 120 - colSize, wantKind) : fit(width - 64 - 120 - colSize - colDate, wantKind)
    readonly property int nameWidth: Math.max(120, width - 48 - colDate - colSize - colKind - 16)

    // ---------- column headings (list) ----------
    Item {
        id: head
        visible: root.mode === "list"
        width: parent.width; height: visible ? 28 : 0
        component Heading: Item {
            id: h
            property string field
            property string label
            property bool alignRight: false
            height: 28
            readonly property bool on: field === root.hub.win.sortField
            visible: width > 0
            Text {
                anchors { fill: parent; leftMargin: 8; rightMargin: 12 }
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: h.alignRight ? Text.AlignRight : Text.AlignLeft
                text: h.label; elide: Text.ElideRight
                color: h.on ? Theme.text : Theme.muted
                font.family: Theme.font; font.pixelSize: 12; font.bold: h.on
            }
            Text {
                visible: h.on
                anchors { right: parent.right; rightMargin: h.alignRight ? -2 : 10; verticalCenter: parent.verticalCenter }
                text: root.hub.win.sortReversed ? "⌄" : "⌃"; color: Theme.muted
                font.family: Theme.font; font.pixelSize: 11
            }
            Rectangle { anchors { left: parent.left; verticalCenter: parent.verticalCenter } width: 1; height: 14; color: Theme.hairline; visible: h.x > 40 }
            MouseArea { anchors.fill: parent; onClicked: root.hub.win.sortBy(h.field) }
        }
        Row {
            x: 40
            Heading { field: "name"; label: "Name"; width: root.nameWidth + 8 }
            Heading { field: "time"; label: "Date Modified"; width: root.colDate }
            Heading { field: "size"; label: "Size"; width: root.colSize; alignRight: true }
            Heading { field: "type"; label: root.searching ? "Where" : "Kind"; width: root.colKind }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
        // column borders: drag one and the two columns beside it trade width (Name takes whatever is left)
        component Border: Grip {
            property string leftCol: ""       // hub property of the column left of the border ("" = Name)
            property string rightCol: ""      // ... and right of it
            property int l0
            property int r0
            height: 28; z: 2
            onStarted: { l0 = leftCol ? root.hub.win[leftCol] : 0; r0 = root.hub.win[rightCol] }
            onMoved: (dx) => {
                const d = Math.max(-(leftCol ? l0 - 60 : root.nameWidth - 120), Math.min(r0 - 60, dx))
                if (leftCol) root.hub.win[leftCol] = l0 + d
                root.hub.win[rightCol] = r0 - d
            }
        }
        Border { x: 48 + root.nameWidth - 4; rightCol: "colDate"; visible: root.colDate > 0 }
        Border { x: 48 + root.nameWidth + root.colDate - 4; leftCol: "colDate"; rightCol: "colSize"; visible: root.colDate > 0 }
        Border { x: 48 + root.nameWidth + root.colDate + root.colSize - 4; leftCol: "colSize"; rightCol: "colKind"; visible: root.colKind > 0 }
    }

    GridView {
        id: grid
        objectName: "grid"
        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom }
        anchors.topMargin: root.mode === "grid" ? 12 : root.mode === "list" ? 4 : 6
        anchors.leftMargin: root.mode === "grid" ? 12 : 0; anchors.rightMargin: anchors.leftMargin
        clip: true
        focus: true
        keyNavigationEnabled: false
        acceptedButtons: Qt.NoButton   // wheel / touchpad scroll; a mouse drag selects (a wobbly click must not become a scroll)
        boundsBehavior: Flickable.StopAtBounds
        readonly property int perRow: Math.max(1, Math.floor(width / 116))
        cellWidth: root.mode === "grid" ? Math.floor(width / perRow) : width
        cellHeight: root.mode === "grid" ? 118 : root.mode === "list" ? 26 : 24
        model: fm
        bottomMargin: 12
        delegate: Item {
            id: d
            required property int index
            required property string fileName
            required property string filePath
            required property string fileSuffix
            required property bool fileIsDir
            required property var fileSize
            required property var fileModified
            readonly property string kind: Fs.kind(filePath, fileIsDir)
            readonly property bool picked: root.sel.indexOf(filePath) >= 0
            readonly property bool hot: picked && root.lit             // accent-filled selection
            readonly property string ext: fileIsDir ? "" : fileSuffix.split(".").pop()
            readonly property var look: fileIsDir ? root.hub.win.look(filePath) : ({ emblem: "", color: "" })
            readonly property string vcs: root.git[fileName] || ""
            objectName: "item:" + filePath
            width: grid.cellWidth; height: grid.cellHeight
            opacity: Fs.offline.indexOf(filePath) >= 0 ? 0.4 : 1    // a network share whose server is down

            // ----- list + compact rows -----
            Rectangle {   // stripes
                visible: root.mode === "list" && d.index % 2 === 1
                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                radius: 5; color: Theme.stripe
            }
            Rectangle {   // a drop would go into this folder
                visible: dropZone.target === d.filePath
                anchors.fill: parent; anchors.leftMargin: root.mode === "grid" ? 14 : 8; anchors.rightMargin: anchors.leftMargin
                radius: 5; z: 1
                color: Qt.alpha(Theme.coral, 0.15); border.width: 2; border.color: Theme.coral
            }
            Rectangle {   // selection
                visible: root.mode !== "grid" && d.picked
                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                radius: 5; color: d.hot ? Theme.coral : Theme.fill2
            }
            Item {
                visible: root.mode !== "grid"
                anchors.fill: parent
                FileIcon {
                    id: small
                    x: root.mode === "list" ? 20 : 16
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.mode === "list" ? 18 : 16; height: width
                    path: d.filePath; kind: d.kind; suffix: d.ext
                    emblem: d.look.emblem; tint: d.look.color
                }
                Text {
                    id: rowName
                    x: small.x + small.width + 8
                    width: (root.mode === "list" ? root.nameWidth : parent.width - x - 30) - (d.vcs ? 18 : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    text: d.fileName; elide: Text.ElideMiddle
                    color: d.hot ? Theme.onAccent : Theme.text
                    font.family: Theme.font; font.pixelSize: Theme.fontSize
                }
                Text {   // git
                    objectName: "git:" + d.fileName
                    visible: d.vcs !== ""
                    x: rowName.x + Math.min(rowName.contentWidth, rowName.width) + 6
                    anchors.verticalCenter: parent.verticalCenter
                    text: d.vcs; color: root.gitColor(d.vcs, d.hot)
                    font.family: Theme.font; font.pixelSize: 11; font.bold: true
                }
                Text {   // compact: chevron on folders
                    visible: root.mode === "compact" && d.fileIsDir
                    anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                    text: Theme.g("chevron"); color: d.hot ? Theme.onAccent : Theme.muted
                    font.family: Theme.font; font.pixelSize: 13
                }
                Row {
                    visible: root.mode === "list"
                    x: 48 + root.nameWidth
                    height: parent.height
                    Text {
                        visible: width > 0
                        width: root.colDate; height: parent.height; verticalAlignment: Text.AlignVCenter; leftPadding: 8
                        text: Theme.when(d.fileModified); elide: Text.ElideRight
                        color: d.hot ? Theme.onAccent : Theme.muted; font.family: Theme.font; font.pixelSize: 12
                    }
                    Text {
                        width: root.colSize; height: parent.height; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignRight; rightPadding: 12
                        text: d.fileIsDir ? "--" : Fs.size(d.fileSize)
                        color: d.hot ? Theme.onAccent : Theme.muted; font.family: Theme.font; font.pixelSize: 12
                    }
                    Text {
                        visible: width > 0
                        width: root.colKind; height: parent.height; verticalAlignment: Text.AlignVCenter; leftPadding: 8
                        text: root.searching ? root.where(d.filePath) : Fs.describe(d.filePath, d.fileIsDir); elide: Text.ElideMiddle
                        color: d.hot ? Theme.onAccent : Theme.muted; font.family: Theme.font; font.pixelSize: 12
                    }
                }
            }

            // ----- icon tile -----
            Item {
                visible: root.mode === "grid"
                anchors.fill: parent
                Rectangle {   // grey backdrop behind a selected icon
                    visible: d.picked
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 2; width: 76; height: 72; radius: 6
                    color: Theme.fill2
                }
                FileIcon {
                    id: bigIcon
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 6; width: 64; height: 64
                    path: d.filePath; kind: d.kind; suffix: d.ext
                    emblem: d.look.emblem; tint: d.look.color
                }
                Rectangle {   // git: a small square key on the icon's corner
                    visible: d.vcs !== ""
                    x: bigIcon.x + bigIcon.width - 10; y: bigIcon.y + bigIcon.height - 16
                    width: 16; height: 16; radius: 3
                    color: Theme.surface; border.width: 1; border.color: root.gitColor(d.vcs, false)
                    Text { anchors.centerIn: parent; text: d.vcs; color: root.gitColor(d.vcs, false); font.family: Theme.font; font.pixelSize: 10; font.bold: true }
                }
                Rectangle {   // name pill
                    anchors { horizontalCenter: parent.horizontalCenter; top: bigIcon.bottom; topMargin: 6 }
                    width: Math.min(parent.width - 8, name.paintedWidth + 12); height: name.paintedHeight + 4
                    radius: 4
                    color: d.hot ? Theme.coral : d.picked ? Theme.fill2 : "transparent"
                    Text {
                        id: name
                        anchors.centerIn: parent
                        width: grid.cellWidth - 20
                        horizontalAlignment: Text.AlignHCenter
                        text: d.fileName
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere; maximumLineCount: 2; elide: Text.ElideMiddle
                        color: d.hot ? Theme.onAccent : Theme.text
                        font.family: Theme.font; font.pixelSize: 12
                    }
                }
            }
        }

        // ---------- drop: files from Kaze or another app, onto a folder in the list, else into this folder ----------
        DropArea {
            id: dropZone
            parent: grid
            anchors.fill: parent
            property string target: ""   // the folder under the pointer ("" = this folder)
            keys: ["text/uri-list"]
            onPositionChanged: (d) => {
                const i = grid.indexAt(d.x + grid.contentX, d.y + grid.contentY), t = i >= 0 && root.isDirAt(i) ? root.pathAt(i) : ""
                if (t !== target) { target = t; spring.restart() }
            }
            onExited: { target = ""; spring.stop() }
            onDropped: (d) => {
                const dest = target || (root.searching ? "" : root.folder)
                target = ""; spring.stop()
                if (!dest || !d.hasUrls) return
                d.accept(Qt.CopyAction)   // Kaze does the copy / move itself; the source must not delete anything
                const w = dropZone.mapToItem(null, d.x, d.y)
                root.hub.win.drop(d.urls, dest, w.x, w.y)
            }
            // spring-loaded folders: holding a drag over a folder opens it, so you can drop deeper down
            Timer { id: spring; interval: 900; onTriggered: if (dropZone.containsDrag && dropZone.target) { const t = dropZone.target; dropZone.target = ""; root.hub.go(t) } }
        }
        Rectangle {   // dropping into this folder itself: an accent outline around the view
            parent: grid
            anchors.fill: parent; anchors.margins: 2
            visible: dropZone.containsDrag && dropZone.target === "" && !root.searching
            color: "transparent"; radius: 6
            border.width: 2; border.color: Qt.alpha(Theme.coral, 0.7)
        }

        // ---------- mouse: click / ctrl / shift, double-click, right-click, drag on empty space = select a box ----------
        Rectangle {
            id: band
            parent: grid.contentItem
            visible: false
            color: Qt.alpha(Theme.coral, 0.15)
            border.width: 1; border.color: Qt.alpha(Theme.coral, 0.7)
            radius: 2
        }
        MouseArea {
            id: mouse
            parent: grid
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            property point p0
            property bool pressedEmpty: false
            property int pressedAt: -1       // the item a press started on: moving from it drags it (and the rest of the selection)
            property bool dragged: false
            property point w0                // where the press was, in the window (a view that shifts under a still mouse is no drag)
            property var base: []
            function at(m) { return grid.indexAt(m.x + grid.contentX, m.y + grid.contentY) }
            function cell(i) {
                if (root.mode !== "grid") return Qt.rect(0, i * grid.cellHeight, grid.width, grid.cellHeight)
                return Qt.rect((i % grid.perRow) * grid.cellWidth + 20, Math.floor(i / grid.perRow) * grid.cellHeight, grid.cellWidth - 40, grid.cellHeight - 10)
            }
            onPressed: (m) => {
                root.forceActiveFocus()
                pressedEmpty = m.button === Qt.LeftButton && at(m) < 0
                pressedAt = m.button === Qt.LeftButton ? at(m) : -1
                dragged = false
                w0 = mapToItem(null, m.x, m.y)
                p0 = Qt.point(m.x + grid.contentX, m.y + grid.contentY)
                base = m.modifiers & (Qt.ControlModifier | Qt.ShiftModifier) ? root.sel : []
            }
            onPositionChanged: (m) => {
                const x = m.x + grid.contentX, y = m.y + grid.contentY
                const w = mapToItem(null, m.x, m.y)
                if (pressedAt >= 0 && !dragged && (m.buttons & Qt.LeftButton) && Math.hypot(w.x - w0.x, w.y - w0.y) >= Qt.styleHints.startDragDistance) {   // drag the files
                    dragged = true
                    const p = root.pathAt(pressedAt)
                    if (root.sel.indexOf(p) < 0) root.hub.click(root, pressedAt, 0, true)   // select it (without opening it)
                    const L = root.sel.indexOf(p) >= 0 ? root.sel.slice() : [p]
                    pressedAt = -1
                    Fs.drag(L)   // until it is dropped (here, on another pane / folder / the sidebar, or in another app)
                    return
                }
                if (!pressedEmpty) return
                if (!band.visible && Math.abs(x - p0.x) + Math.abs(y - p0.y) < 6) return
                band.x = Math.min(x, p0.x); band.y = Math.min(y, p0.y)
                band.width = Math.abs(x - p0.x); band.height = Math.abs(y - p0.y)
                band.visible = true
                const out = base.slice()
                for (let i = 0; i < fm.count; i++) {
                    const c = cell(i)
                    if (c.x < band.x + band.width && c.x + c.width > band.x && c.y < band.y + band.height && c.y + c.height > band.y) {
                        const p = root.pathAt(i)
                        if (out.indexOf(p) < 0) out.push(p)
                    }
                }
                root.hub.setSelection(root, out)
            }
            onReleased: { pressedEmpty = false; pressedAt = -1 }
            onClicked: (m) => {
                if (dragged) { dragged = false; return }
                if (band.visible) { band.visible = false; return }
                const i = at(m)
                if (m.button === Qt.RightButton) {
                    if (i >= 0 && root.sel.indexOf(root.pathAt(i)) < 0) root.hub.click(root, i, 0, true)
                    else if (i < 0) root.hub.click(root, -1, 0)
                    const w = mapToItem(null, m.x, m.y)
                    root.hub.itemMenu(root, i, w.x, w.y)
                } else root.hub.click(root, i, m.modifiers)
            }
            onCanceled: { band.visible = false; pressedAt = -1 }
            onDoubleClicked: (m) => { const i = at(m); if (i >= 0 && m.button === Qt.LeftButton) root.hub.activate(root, i) }
        }
    }

    Text {
        anchors.centerIn: grid
        visible: (fm.ready && fm.count === 0 && !fm.error) || (root.slow && !fm.ready)
        text: !fm.ready ? (root.searching ? "Searching…" : Fs.busy && Fs.onNetwork(root.folder) ? "Waiting for the server (it is busy with a copy)…" : "Loading…") : root.mode === "compact" ? "" : root.searching ? "Nothing found" : "Empty folder"
        color: Theme.dim; font.family: Theme.font; font.pixelSize: 13
    }

    // ---------- keyboard: arrows / Home / End / PgUp / PgDn move, Enter opens, a letter jumps to a name ----------
    Keys.onPressed: (e) => {
        const n = fm.count
        if (root.mode === "compact" && (e.key === Qt.Key_Left || e.key === Qt.Key_Right)) {   // also from an empty folder
            if (e.key === Qt.Key_Left) root.hub.goLeft(); else root.hub.goRight()
            e.accepted = true; return
        }
        if (!n) return
        const i = indexOf(root.cur)
        const cols = root.mode === "grid" ? grid.perRow : 1
        const page = Math.max(1, Math.floor(grid.height / grid.cellHeight)) * cols
        let to = -1
        switch (e.key) {
        case Qt.Key_Down:     to = i < 0 ? 0 : Math.min(n - 1, i + cols); break
        case Qt.Key_Up:       to = i < 0 ? 0 : Math.max(0, i - cols); break
        case Qt.Key_Right:    if (root.mode === "grid") to = Math.min(n - 1, i + 1); break
        case Qt.Key_Left:     if (root.mode === "grid") to = Math.max(0, i - 1); break
        case Qt.Key_Home:     to = 0; break
        case Qt.Key_End:      to = n - 1; break
        case Qt.Key_PageDown: to = Math.min(n - 1, Math.max(0, i) + page); break
        case Qt.Key_PageUp:   to = Math.max(0, i - page); break
        case Qt.Key_Return:
        case Qt.Key_Enter:    if (i >= 0) root.hub.activate(root, i); e.accepted = true; return
        default:
            if (/^[\w.\-]$/.test(e.text) && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
                const t = e.text.toLowerCase()
                for (let k = 1; k <= n; k++) {
                    const j = (Math.max(i, 0) + k) % n
                    if (fm.get(j, "fileName").toLowerCase().startsWith(t)) { to = j; break }
                }
            }
        }
        if (to >= 0) { root.hub.cursor(root, to, e.modifiers & Qt.ShiftModifier); e.accepted = true }
    }
}
