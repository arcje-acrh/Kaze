// Pane.qml -- one folder in the window: its own folder (`dir`), selection (`sel`), keyboard cursor (`cur`), history,
// view (icons / list / columns) and path bar. The window shows one, or two side by side (split view). The views
// (Items / Columns) call back into the pane (click / activate / cursor / menu / left / right); shared settings
// (sort, hidden files, widths) live on the window (`win`).
import QtQuick

FocusScope {
    id: pane
    property var win
    property var other                       // the pane next to this one (split view)
    property string dir: Fs.home
    property string base: dir                // column view starts here: the folder last opened from the sidebar
    property var sel: []
    property string cur: ""
    property string anchorPath: ""
    property var back: []
    property var fwd: []
    property bool pickFirst: false
    property string view: "list"
    property string query: ""                // search: results (this folder and below) replace the view; cleared on moving
    property bool everywhere: false          // search the whole computer (plocate) instead; back off when the search ends
    onQueryChanged: if (!query) everywhere = false
    readonly property bool active: win.pane === pane
    readonly property bool inTrash: dir === Fs.trashDir || dir.startsWith(Fs.trashDir + "/")
    onActiveFocusChanged: if (activeFocus) win.pane = pane

    // ---------- navigation ----------
    function offlineShare(p) { return Fs.offline.find(s => p === s || p.startsWith(s + "/")) || "" }
    function go(p, noHistory) {
        const s = offlineShare(p)
        if (s) { win.flash(win.name(s) + " is offline: its server isn’t answering", true); Fs.probe(); return }
        if (p !== dir && !noHistory) { back = back.concat([dir]); fwd = [] }
        dir = p; sel = []; cur = ""; anchorPath = ""
        refocus()
    }
    function under(p, b) { return p === b || p.startsWith(b === "/" ? "/" : b + "/") }

    // every folder change goes through here or go(), so Back / Forward know about it (column clicks, ← / → included)
    function moveTo(p) { if (p === dir) return; back = back.concat([dir]); fwd = []; dir = p; sel = []; cur = ""; anchorPath = "" }
    function open(p) { go(p); if (dir === p) base = p }   // from the sidebar: the tree starts at p
    // Back / Forward: the folder you came from is highlighted again when it is inside the one you land in
    function returnTo(p) {
        const old = dir; go(p, true)
        if (dir === p && old !== p && under(old, p)) select((p === "/" ? "" : p) + "/" + old.slice(p === "/" ? 1 : p.length + 1).split("/")[0])
    }
    function goBack() { if (back.length) { const p = back[back.length - 1]; fwd = [dir].concat(fwd); back = back.slice(0, -1); returnTo(p) } }
    function goForward() { if (fwd.length) { const p = fwd[0]; back = back.concat([dir]); fwd = fwd.slice(1); returnTo(p) } }
    // one folder up; from the top of an opened archive: to the folder the archive is in
    function upOf(p) { const a = Fs.archiveOf(p); return a && !Fs.archiveOf(Fs.parent(p)) ? Fs.parent(a) : Fs.parent(p) }
    function up() { if (dir === "/") return; const old = Fs.archiveOf(dir) && !Fs.archiveOf(Fs.parent(dir)) ? Fs.archiveOf(dir) : dir; go(upOf(dir)); select(old) }
    function select(p) { sel = [p]; cur = p; anchorPath = p }
    function refocus() { if (body.item) body.item.forceActiveFocus() }
    function goTo() {
        win.ask("Go to folder", dir, -1, t => {
            t = t.trim().replace(/^~(?=\/|$)/, Fs.home)
            if (Fs.isDir(t)) { go(t); return "" }
            if (Fs.exists(t)) { go(Fs.parent(t)); select(t); return "" }
            return "No such folder"
        })
    }

    // ---------- called by the views ----------
    // forMenu = a right-click: select only (a folder must not open under the menu)
    function click(v, i, mods, forMenu) {
        if (v.folder !== dir) moveTo(v.folder)
        if (i < 0) { if (!(mods & Qt.ControlModifier)) sel = []; return }
        const p = v.pathAt(i)
        if (mods & Qt.ShiftModifier) range(v, i)
        else if (mods & Qt.ControlModifier) { sel = sel.indexOf(p) >= 0 ? sel.filter(x => x !== p) : sel.concat([p]); cur = p; anchorPath = p }
        else if (view === "columns" && !query && !forMenu && v.isDirAt(i) && !offlineShare(p)) moveTo(p)   // column view: one click opens a folder
        else select(p)
    }
    function range(v, i) {
        const a = Math.max(0, v.indexOf(anchorPath)), out = []
        for (let k = Math.min(a, i); k <= Math.max(a, i); k++) out.push(v.pathAt(k))
        sel = out; cur = v.pathAt(i)
    }
    function setSelection(v, L) {
        if (v.folder !== dir) moveTo(v.folder)
        sel = L; cur = L.length ? L[L.length - 1] : ""
    }
    function cursor(v, i, shift) { if (v.folder !== dir) click(v, i, 0); else if (shift) range(v, i); else select(v.pathAt(i)) }
    function activate(v, i) {
        const p = v.pathAt(i)
        if (v.isDirAt(i)) go(p)
        else if (inTrash) win.flash("Put it back first (right-click › Put back)", true)
        else if (Fs.kind(p, false) === "archive") win.browse(p)   // opens like a folder (Open With… for an app)
        else Fs.open(p)
    }
    function goLeft() { if (dir === "/") return; const old = dir; moveTo(Fs.parent(dir)); select(old) }
    function goRight() {
        if (!cur || !Fs.isDir(cur)) return
        moveTo(cur); pickFirst = true
        Qt.callLater(() => { const v = shown(); if (v) loaded(v) })   // its column may be loaded already
    }
    function loaded(v) { if (pickFirst && v.folder === dir && v.count) { pickFirst = false; cursor(v, 0, false) } }

    // ---------- actions ----------
    // what an action works on: the selection, else the highlight, else (column view) the folder opened by one click --
    // it is the highlighted row in the parent column (not when it is the top of the tree, which has no row)
    function picked() { return sel.length ? sel : cur ? [cur] : view === "columns" && !query && dir !== base && dir !== "/" ? [dir] : [] }
    function many(L) { return L.length === 1 ? "“" + L[0].split("/").pop() + "”" : L.length + " items" }
    function openPicked() {
        const L = picked(), d = L.find(p => Fs.isDir(p))
        if (d) go(d)
        else if (L.length === 1 && Fs.kind(L[0], false) === "archive") win.browse(L[0])
        else if (!inTrash) L.forEach(p => Fs.open(p))
    }
    function copy(cut) {
        const L = picked(); if (!L.length) return
        Fs.setClipboard(L, cut)
        win.flash((cut ? "Cut " : "Copied ") + many(L))
    }
    function paste(into) {
        const to = into || dir, c = Fs.clipboard()
        if (!c.paths.length) { win.flash("Nothing to paste", true); return }
        if (c.cut) { Fs.move(c.paths, to); Fs.setText("") } else Fs.copy(c.paths, to)
    }
    function compress() { const L = picked(); if (!L.length || inTrash) return; Fs.compress(L, Fs.parent(L[0])); win.flash("Compressing " + many(L) + "…") }
    function copyName() { const L = picked(); Fs.setText(L.map(p => p.split("/").pop()).join("\n")); win.flash("Copied the name") }
    function newFile() {
        if (inTrash) return
        win.ask("New file", "untitled.txt", 8, t => { const e = Fs.mkfile(dir, t); if (!e) select(dir + "/" + t); return e })
    }
    // split view: send the selection to the folder open in the other pane
    function toOther(move) {
        const L = picked(); if (!L.length || !win.split || inTrash) return
        if (move) Fs.move(L, other.dir); else Fs.copy(L, other.dir)
        win.flash((move ? "Moving " : "Copying ") + many(L) + " to “" + win.name(other.dir) + "”")
    }
    function trash() {
        const L = picked(); if (!L.length) return
        if (inTrash) { deleteForever(); return }
        if (L.indexOf(dir) >= 0) moveTo(Fs.parent(dir))   // column view: the open folder itself goes -> step out of it
        if (Fs.trash(L)) { sel = []; win.flash("Moving " + many(L) + " to the Trash  ·  Ctrl+Z puts it back") }
    }
    function deleteForever() {
        const L = picked(); if (!L.length) return
        win.confirm("Delete " + many(L) + " permanently?", "This can’t be undone.", "Delete", () => {
            if (L.indexOf(dir) >= 0) moveTo(Fs.parent(dir))
            Fs.remove(L); sel = []
        })
    }
    function rename() {
        if (!cur || inTrash) return
        const n = cur.split("/").pop(), dot = Fs.isDir(cur) || n.startsWith(".") ? -1 : n.indexOf(".")
        const p = cur
        win.ask("Rename", n, dot, t => { const e = Fs.rename(p, t); if (!e) select(Fs.parent(p) + "/" + t); return e })
    }
    function newFolder() {
        if (inTrash) return
        win.ask("New folder", "untitled folder", -1, t => { const e = Fs.mkdir(dir, t); if (!e) select(dir + "/" + t); return e })
    }
    function shown() { return !body.item ? null : view === "columns" && !query ? body.item.current : body.item }   // the Items of `dir`
    function selectAll() { const v = shown(); if (!v) return; const out = []; for (let k = 0; k < v.count; k++) out.push(v.pathAt(k)); sel = out }
    function copyPath() { const L = picked(); Fs.setText((L.length ? L : [dir]).join("\n")); win.flash("Copied the path") }

    function folderMenu() {
        return [
            { text: "New Folder", key: "Ctrl+Shift+N", run: newFolder },
            { text: "New File…", run: newFile },
            { sep: true },
            { text: "Paste", key: "Ctrl+V", run: () => paste() },
            { text: "Select All", key: "Ctrl+A", run: selectAll },
            { sep: true },
            { text: "Copy Path", key: "Ctrl+Shift+C", run: copyPath },
            { text: "Open in Terminal", key: "F4", run: () => Fs.terminal(dir) },
            { text: "Add to Sidebar", run: () => Fs.bookmark(dir) },
            { text: "Go to Folder…", key: "Ctrl+L", run: goTo },
            { text: "Show Details", key: "Ctrl+I", run: () => inspect(dir) },
            { text: "Properties…", run: () => win.properties(dir) },
            { sep: true },
            { text: win.split ? "Close Split View" : "Split View", key: "F3", run: win.toggleSplit },
            { text: win.hidden ? "Hide Hidden Files" : "Show Hidden Files", key: "Ctrl+H", run: () => win.hidden = !win.hidden }]
    }
    // show the details of p: column view = highlight it (its folder's details: step out to the parent); else the side panel
    function inspect(p) {
        if (view === "columns") { if (p === dir) goLeft(); else select(p) }
        else { win.details = true; if (p === dir) sel = []; else select(p) }
    }
    function openWith(L, x, y) {
        const apps = Fs.appsFor(L[0])
        if (!apps.length) { win.flash("No app opens this kind of file", true); return }
        win.showMenu(apps.map(a => ({ text: a.name, key: a.default ? "default" : "", run: () => Fs.openWith(a.desktop, L) })), x, y)
    }
    function itemMenu(v, i, x, y) {
        const L = i >= 0 ? picked() : [], one = L.length === 1 ? L[0] : ""
        const isDir = one !== "" && Fs.isDir(one), anyDir = L.some(p => Fs.isDir(p))
        const isArchive = one !== "" && !isDir && Fs.kind(one, false) === "archive"
        const name = one ? "“" + one.split("/").pop() + "”" : L.length + " items"
        let m
        if (inTrash) m = (i >= 0 ? [{ text: "Put Back", run: () => { Fs.restore(L); sel = [] } }, { text: "Copy Path", run: copyPath }, { sep: true },
                                    { text: "Delete Permanently", key: "Delete", warn: true, run: deleteForever }, { sep: true }] : [])
                         .concat([{ text: "Empty Trash", warn: true, run: () => Fs.emptyTrash() }])
        else if (i >= 0) m = [
            { text: "Open", key: "Enter", run: openPicked }]
            .concat(!anyDir ? [{ text: "Open With…", run: () => openWith(L, x, y) }] : [])
            .concat(isDir ? [{ text: "Open in Terminal", run: () => Fs.terminal(one) }] : [])
            .concat([
            { sep: true },
            { text: "Cut", key: "Ctrl+X", run: () => copy(true) },
            { text: "Copy", key: "Ctrl+C", run: () => copy(false) },
            { text: isDir ? "Paste Into Folder" : "Paste", key: isDir ? "" : "Ctrl+V", run: () => paste(isDir ? one : "") },
            { sep: true },
            { text: "Rename", key: "F2", run: rename },
            { text: "Compress " + name, run: compress }])
            .concat(isArchive ? [{ text: "Extract Here", run: () => { Fs.extract(one); win.flash("Extracting " + name + "…") } }] : [])
            .concat(isDir ? [{ text: "Disk Usage…", run: () => win.usageOf(one) }] : [])
            .concat([
            { sep: true },
            { text: "Copy Path", key: "Ctrl+Shift+C", run: copyPath },
            { text: "Copy Name", run: copyName }])
            .concat(isDir ? [{ text: "Add to Sidebar", run: () => Fs.bookmark(one) }] : [])
            .concat(win.split ? [{ sep: true }, { text: "Copy to Other Pane", key: "F5", run: () => toOther(false) }, { text: "Move to Other Pane", key: "F6", run: () => toOther(true) }] : [])
            .concat([{ sep: true }, { text: "Show Details", key: "Ctrl+I", run: () => inspect(cur) }, { text: "Properties…", run: () => win.properties(one || cur) }])
            .concat(isDir ? [{ text: "Change Look…", run: () => win.changeLook(one) }] : [])
            .concat([{ sep: true }, { text: "Move to Trash", key: "Delete", run: trash }, { text: "Delete Permanently…", key: "Shift+Delete", warn: true, run: deleteForever }])
        else m = folderMenu()
        win.showMenu(m, x, y)
    }

    // ---------- free space (asked off the UI thread: statvfs on a dead network share would hang) ----------
    property string freeText: ""
    onDirChanged: { if (!under(dir, base)) base = dir; freeText = ""; query = ""; Fs.askFree(dir) }
    Component.onCompleted: Fs.askFree(dir)
    Connections { target: Fs; function onFreeReady(d, f) { if (d === pane.dir) pane.freeText = f } }

    // ---------- the view ----------
    Loader {
        id: body
        anchors { left: parent.left; right: side.left; top: parent.top; bottom: foot.top }
        sourceComponent: pane.view === "columns" && !pane.query ? columnsView : itemsView
        onLoaded: if (pane.active && !win.typingSearch) item.forceActiveFocus()
    }
    Loader {   // list / icon view: details of the selection (or of this folder) on the right -- Ctrl+I
        id: side
        active: pane.query ? win.details || pane.view === "columns" : win.details && pane.view !== "columns"
        anchors { right: parent.right; top: parent.top; bottom: foot.top }
        width: active ? Math.min(320, pane.width * 0.4) : 0
        sourceComponent: Item {
            Rectangle { width: 1; height: parent.height; color: Theme.hairline }
            Details { anchors { fill: parent; leftMargin: 1 } win: pane.win; path: pane.sel.length ? pane.cur : pane.dir }
        }
    }
    Component { id: itemsView; Items { hub: pane; folder: pane.dir; query: pane.query; mode: pane.query ? "list" : pane.view; sel: pane.sel; cur: pane.cur } }
    Component { id: columnsView; Columns { hub: pane } }

    // ---------- path bar + status ----------
    Item {
        id: foot
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 28
        opacity: pane.active || !win.split ? 1 : 0.55
        Rectangle { width: parent.width; height: 1; color: Theme.hairline }
        Rectangle {   // the active pane of a split gets an accent line
            visible: win.split && pane.active
            width: parent.width; height: 2; color: Theme.coral
        }
        Item {   // path bar: click a folder (icon or name) to open it; a long path keeps its end in view
            id: crumbs
            anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
            width: parent.width - status.width - 30; height: 22
            clip: true
            Row {
                x: Math.min(0, crumbs.width - width)
                height: parent.height
                Repeater {
                    model: {
                        const out = []
                        for (let p = pane.dir; ; p = pane.upOf(p)) { out.unshift(p); if (p === "/" || p === Fs.home) break }
                        return out
                    }
                    delegate: Row {
                        required property var modelData
                        required property int index
                        height: parent.height
                        Text { visible: index > 0; width: 14; horizontalAlignment: Text.AlignHCenter; text: "›"; color: Theme.dim; font.family: Theme.font; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                        Rectangle {
                            objectName: "crumb:" + modelData
                            width: crumb.width + 10; height: parent.height; radius: 5
                            color: cz.containsDrag ? Qt.alpha(Theme.coral, 0.18) : cm.pressed ? Theme.fill2 : cm.containsMouse ? Theme.fill : "transparent"
                            border.width: cz.containsDrag ? 1 : 0; border.color: Theme.coral
                            DropArea {   // files dropped on a folder of the path go into it
                                id: cz; anchors.fill: parent; keys: ["text/uri-list"]
                                onDropped: (d) => { if (!d.hasUrls) return; d.accept(Qt.CopyAction); const w = cz.mapToItem(null, d.x, d.y); win.drop(d.urls, modelData, w.x, w.y) }
                            }
                            Row {
                                id: crumb
                                x: 5; spacing: 4; anchors.verticalCenter: parent.verticalCenter
                                FileIcon { width: 14; height: 14; kind: "folder"; anchors.verticalCenter: parent.verticalCenter }
                                Text {
                                    text: win.name(modelData)
                                    color: cm.containsMouse ? Theme.text : Theme.muted
                                    font.family: Theme.font; font.pixelSize: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                            MouseArea { id: cm; anchors.fill: parent; hoverEnabled: true; onClicked: pane.go(modelData) }
                        }
                    }
                }
            }
        }
        Text {
            id: status
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            text: {
                if (win.message && pane.active) return win.message
                const v = pane.shown(), n = v ? v.count : 0
                if (pane.query) return (v && !v.ready ? "Searching… " : "") + n + (n === 1 ? " match" : " matches") + (pane.everywhere ? " everywhere" : " in “" + win.name(pane.dir) + "”")
                const s = pane.sel.length > 1 ? pane.sel.length + " of " + n + " selected" : n + (n === 1 ? " item" : " items")
                return pane.freeText ? s + ", " + pane.freeText.replace(" free", " available") : s
            }
            color: win.message && pane.active && win.messageBad ? Theme.amber : win.message && pane.active ? Theme.text : Theme.muted
            font.family: Theme.font; font.pixelSize: 12
        }
    }
}
