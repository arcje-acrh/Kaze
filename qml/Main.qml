// Main.qml -- the Kaze window, laid out like macOS Finder: see-through sidebar, toolbar (back / forward, folder name,
// view switch, split, actions), one folder pane or two side by side (split view: F3), and the overlays (Quick Look,
// menu, sheet). Settings shared by both panes live here (sort, hidden files, widths); `pane` = the active pane,
// which the toolbar, sidebar and keys act on.
import QtQuick
import QtQuick.Window
import QtCore

Window {
    id: win
    width: 1280; height: 800
    visible: true
    color: Fs.seeThrough ? "transparent" : Theme.surface   // sidebar glass only where it gets blurred
    title: "Kaze · " + name(pane.dir)

    property Pane pane: p1
    readonly property bool typingSearch: search.activeFocus   // a view that loads meanwhile must not take the keys
    property string view: "list"           // default view of a new pane: grid | list | columns
    property bool hidden: false
    property string sortField: "name"      // name | time | size | type
    property bool sortReversed: false
    property bool split: false
    property bool details: false           // list / icon view: details panel on the right (Ctrl+I)
    property real splitRatio: 0.5
    // ZOOM (Finder / Dolphin / Files keep content one size and let you zoom; here "automatic" also picks the step from
    // the window, so full screen is not a few small things in a big empty window). Steps, not a smooth factor, so
    // nothing wobbles while the window is being resized. zoomSet 0 = automatic; Ctrl +/- / Ctrl+scroll set it, Ctrl+0 back.
    readonly property var zoomSteps: [0.9, 1, 1.1, 1.25, 1.4, 1.6]
    property real zoomSet: 0
    // automatic: half of how much bigger than 1150x720 the window is, rounded down to a step (1005x606 -> 100 %, 2048x1240 -> 125 %)
    readonly property real zoomAuto: { const r = 1 + 0.5 * (Math.min(width / 1150, height / 720) - 1); return zoomSteps.filter(s => s >= 1 && s <= r + 0.001).pop() || 1 }
    readonly property real zoom: zoomSet || zoomAuto
    function zoomBy(d) {
        const i = zoomSteps.indexOf(zoom), j = Math.max(0, Math.min(zoomSteps.length - 1, (i < 0 ? 1 : i) + d))
        zoomSet = zoomSteps[j]; flash("Zoom " + Math.round(zoomSet * 100) + " %")
    }
    function zoomAutomatic() { zoomSet = 0; flash("Zoom: automatic (" + Math.round(zoomAuto * 100) + " % for this window size)") }
    // widths (drag to resize, remembered). Sidebar: one width like Finder / Dolphin (it grows with the zoom, not the
    // window), solid, along the left edge; F9 hides it (Dolphin's key), and it tucks away by itself in a very narrow window
    property int sideWidth: 210
    property bool sideShown: true
    property string hiddenPlaces: ""     // sidebar places removed by the user (paths, one per line)
    readonly property bool sideOn: sideShown && ui.width >= 700
    property int colDate: 190
    property int colSize: 90
    property int colKind: 180
    // special folders get their emblem on the folder icon (path -> glyph name)
    readonly property var emblems: { const m = {}; for (const p of Fs.places()) if (p.icon !== "home") m[p.path] = p.icon; return m }

    // a folder's look: what the user chose (Properties > Look), else the special-folder emblem
    function look(p) {
        const l = Fs.looks[p], e = l && l.emblem ? l.emblem : (emblems[p] || "")
        return { emblem: e === "none" ? "" : e, color: l ? l.color : "" }
    }
    function changeLook(p) { lookSheet.show(p) }
    function netLocations(p) { net.show(p || "") }
    function name(p) { return p === Fs.home ? "Home" : p === "/" ? "System" : p === Fs.trashDir ? "Trash" : p.split("/").pop() }
    function sortBy(f) { if (sortField === f) sortReversed = !sortReversed; else { sortField = f; sortReversed = false } }
    function toggleSplit() {
        if (!split) { p2.view = pane.view; p2.go(pane.dir, true); split = true; p2.forceActiveFocus() }
        else { split = false; if (pane === p2) { pane = p1; p1.refocus() } }
    }
    function setView(v) { pane.view = v; view = v; pane.refocus() }
    function quickLook() { if (pane.cur) look.visible = true }
    function ask(title, text, selectTo, done) { prompt.ask(title, text, selectTo, done) }
    function showMenu(items, x, y) { menu.show(items, x / zoom, y / zoom) }   // x, y: window (scene) coordinates
    function confirm(title, text, ok, done, no) { prompt.confirm(title, text, ok, done, no) }
    function undo() { const m = Fs.undo(); flash(m || "Nothing to undo") }
    function usageOf(d) { usage.show(d) }
    function properties(p) { if (p) props.show(p) }
    Component.onCompleted: if (Fs.startProps) Qt.callLater(() => properties(Fs.startProps))   // kaze --properties <path>
    property string opening: ""     // the archive being opened like a folder (its view comes back in onArchiveReady)
    function browse(a) { opening = a; Fs.browse(a) }
    // files dropped on `dest` (x, y: window coordinates). Alt held = ask: move / copy / link
    function drop(urls, dest, x, y) {
        if (!Fs.altHeld()) { const m = Fs.dropFiles(urls, dest); if (m) flash(m); return }
        const L = urls.map(u => Fs.path(u)).filter(p => p && p !== dest)
        if (!L.length) return
        showMenu([{ text: "Move Here", run: () => Fs.move(L, dest) }, { text: "Copy Here", run: () => Fs.copy(L, dest) },
                  { text: "Link Here", run: () => Fs.link(L, dest) }, { sep: true }, { text: "Cancel", run: () => {} }], x, y)
    }

    Settings {
        location: Fs.url(Fs.home + "/.config/kaze/kaze.conf")
        property alias view: win.view
        property alias hidden: win.hidden
        property alias sortField: win.sortField
        property alias sortReversed: win.sortReversed
        property alias split: win.split
        property alias details: win.details
        property alias splitRatio: win.splitRatio
        property alias sideWidth: win.sideWidth
        property alias sideShown: win.sideShown
        property alias zoomSet: win.zoomSet
        property alias hiddenPlaces: win.hiddenPlaces
        property alias colDate: win.colDate
        property alias colSize: win.colSize
        property alias colKind: win.colKind
    }

    // ---------- messages ----------
    // closing while copies / deletes run: the window goes, Kaze stays until they are done (a desktop notice says how
    // each one ended), then quits. A question that comes up meanwhile (names taken) brings the window back.
    property bool leaving: false
    onClosing: (close) => { if (Fs.busy) { close.accepted = false; leaving = true; visible = false } }
    function comeBack() { if (leaving) { leaving = false; visible = true; raise(); requestActivate() } }
    property string message: ""
    property bool messageBad: false
    function flash(m, bad) { message = m; messageBad = !!bad; msgTimer.restart() }
    Timer { id: msgTimer; interval: 4000; onTriggered: win.message = "" }
    Connections {
        target: Fs
        function onError(m) { win.flash(m || "Something went wrong", true) }
        function onNotice(m) { win.flash(m) }
        function onMounted(p) { win.pane.open(p) }
        function onCaseClash(id, pairs, dest) {
            win.comeBack()
            win.confirm((pairs.length === 1 ? "1 name clashes" : pairs.length + (pairs.length > 50 ? "+" : "") + " names clash") + " on “" + win.name(dest) + "”",
                        "This network share ignores upper and lower case, so these can’t both be there; the second of each pair won’t be copied:\n\n"
                        + pairs.slice(0, 6).join("\n") + (pairs.length > 6 ? "\n… and " + (pairs.length - 6) + " more" : ""),
                        "Copy Anyway", () => Fs.clashAnswer(id, true), () => Fs.clashAnswer(id, false))
        }
        function onConflicts(id, items, verb, dest) { win.comeBack(); conflictSheet.show(id, items, verb, dest) }
        function onJobDone(verb, name, how) { if (win.leaving) Fs.notify((how === "done" ? "Finished " : how === "failed" ? "Could not finish " : "Stopped ") + verb.toLowerCase() + " “" + name + "”") }
        function onBusyChanged() { if (win.leaving && !Fs.busy) Qt.quit() }
        function onConfirmDelete(paths) {
            win.confirm("Delete " + (paths.length === 1 ? "“" + paths[0].split("/").pop() + "”" : paths.length + " items") + " permanently?",
                        "A network share has no Trash: this can’t be undone.", "Delete", () => Fs.remove(paths))
        }
        function onArchiveReady(a, d) { if (a === win.opening) { win.opening = ""; win.pane.go(d) } }
    }

    // ---------- keys (window-wide; off while a sheet or menu is open) ----------
    component Bind: Shortcut { enabled: !prompt.visible && !menu.visible && !lookSheet.visible && !net.visible && !conflictSheet.visible && !usage.visible && !props.visible && !search.activeFocus; context: Qt.WindowShortcut }
    Bind { sequences: ["Ctrl++", "Ctrl+=", "Ctrl+Shift+="]; onActivated: win.zoomBy(1) }
    Bind { sequence: "Ctrl+-"; onActivated: win.zoomBy(-1) }
    Bind { sequence: "Ctrl+0"; onActivated: win.zoomAutomatic() }
    Bind { sequence: "F9"; onActivated: win.sideShown = !win.sideShown }
    Bind { sequences: ["Ctrl+F", "/"]; onActivated: search.forceActiveFocus() }
    Bind { sequence: "Space"; onActivated: { if (look.visible) look.visible = false; else win.quickLook() } }
    Bind { sequence: "Escape"; enabled: !prompt.visible && !menu.visible && !net.visible && !conflictSheet.visible && !usage.visible && !props.visible && !search.activeFocus; onActivated: { if (lookSheet.visible) lookSheet.close(); else if (jobs.open) jobs.open = false; else if (look.visible) look.visible = false; else if (win.pane.query) { search.text = ""; win.pane.query = "" } else win.pane.sel = [] } }
    Bind { sequence: "Ctrl+I"; onActivated: win.details = !win.details }
    Bind { sequences: ["Backspace", "Alt+Up"]; onActivated: win.pane.up() }
    Bind { sequences: ["Alt+Left", "Back"]; onActivated: win.pane.goBack() }
    Bind { sequences: ["Alt+Right", "Forward"]; onActivated: win.pane.goForward() }
    Bind { sequence: "Alt+Home"; onActivated: win.pane.go(Fs.home) }
    Bind { sequences: ["Ctrl+L", "Ctrl+Shift+G"]; onActivated: win.pane.goTo() }
    Bind { sequence: "Ctrl+H"; onActivated: win.hidden = !win.hidden }
    Bind { sequence: "F2"; onActivated: win.pane.rename() }
    Bind { sequence: "F3"; onActivated: win.toggleSplit() }
    Bind { sequence: "F4"; onActivated: Fs.terminal(win.pane.dir) }
    Bind { sequence: "F5"; onActivated: win.pane.toOther(false) }
    Bind { sequence: "F6"; onActivated: win.pane.toOther(true) }
    Bind { sequence: "Tab"; enabled: win.split && !prompt.visible && !menu.visible; onActivated: win.pane.other.refocus() }
    Bind { sequence: "Delete"; onActivated: win.pane.trash() }
    Bind { sequence: "Shift+Delete"; onActivated: win.pane.deleteForever() }
    Bind { sequence: "Ctrl+Z"; onActivated: win.undo() }
    Bind { sequence: "Ctrl+C"; onActivated: win.pane.copy(false) }
    Bind { sequence: "Ctrl+X"; onActivated: win.pane.copy(true) }
    Bind { sequence: "Ctrl+V"; onActivated: win.pane.paste() }
    Bind { sequence: "Ctrl+A"; onActivated: win.pane.selectAll() }
    Bind { sequence: "Ctrl+Shift+N"; onActivated: win.pane.newFolder() }
    Bind { sequence: "Ctrl+Shift+C"; onActivated: win.pane.copyPath() }
    Bind { sequence: "Ctrl+1"; onActivated: win.setView("grid") }
    Bind { sequence: "Ctrl+2"; onActivated: win.setView("list") }
    Bind { sequence: "Ctrl+3"; onActivated: win.setView("columns") }
    Bind { sequences: ["Ctrl+W", "Ctrl+Q"]; onActivated: win.close() }

    // ---------- everything visible, zoomed as one: text, icons, rows, sidebar, toolbar and preview grow together
    // (like zooming a web page) instead of only the boxes getting wider. `ui` is laid out in unzoomed units. ----------
    Item {
        id: ui
        width: win.width / win.zoom; height: win.height / win.zoom
        scale: win.zoom; transformOrigin: Item.TopLeft

        // ---------- layout ----------
        Sidebar {
            id: side
            visible: win.sideOn
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: win.sideWidth
            hub: win
        }
        Grip {
            visible: win.sideOn
            anchors { horizontalCenter: side.right; top: parent.top; bottom: parent.bottom }
            z: 5
            property int w0
            onStarted: w0 = win.sideWidth
            onMoved: (dx) => win.sideWidth = Math.max(160, Math.min(300, w0 + dx))
        }

        Rectangle {
            id: main
            anchors { left: win.sideOn ? side.right : parent.left; right: parent.right; top: parent.top; bottom: parent.bottom }
            color: Theme.bg

            // ----- toolbar (acts on the active pane) -----
            Item {
                id: bar
                width: parent.width; height: 52
                Row {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    spacing: 2
                    Key { icon: Theme.g("back"); size: 20; enabled: win.pane.back.length > 0; onClicked: win.pane.goBack() }
                    Key { icon: Theme.g("forward"); size: 20; enabled: win.pane.fwd.length > 0; onClicked: win.pane.goForward() }
                    Item { width: 10; height: 1 }
                    // the folder name is the search box: click it (or Ctrl+F, /) and type -- this folder and all below it
                    Rectangle {
                        id: find
                        objectName: "search"
                        readonly property bool open: search.activeFocus || search.text !== ""
                        anchors.verticalCenter: parent.verticalCenter
                        // typing: a wide field; left with a search showing: a small chip with the words (× / Esc end it)
                        width: Math.min(bar.width - 470 - (scope.visible ? scope.width + 8 : 0), search.activeFocus ? 420 : search.text ? Math.min(240, search.contentWidth + 70) : nameText.implicitWidth + 40); height: 30; radius: 7
                        color: open ? Theme.fill : fm.containsMouse ? Qt.alpha(Theme.fill, 0.6) : "transparent"
                        border.width: search.activeFocus ? 1 : 0; border.color: Qt.alpha(Theme.coral, 0.6)
                        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        MouseArea { id: fm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.IBeamCursor; onClicked: search.forceActiveFocus() }
                        Text {
                            id: nameText
                            visible: !find.open
                            anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                            width: Math.min(implicitWidth, find.width - 40); elide: Text.ElideRight
                            text: win.name(win.pane.dir); color: Theme.text
                            font.family: Theme.font; font.pixelSize: 15; font.bold: true
                        }
                        Text {
                            anchors { left: find.open ? parent.left : nameText.right; leftMargin: 9; verticalCenter: parent.verticalCenter }
                            text: Theme.g("search"); color: find.open ? Theme.muted : fm.containsMouse ? Theme.muted : Theme.dim
                            font.family: Theme.font; font.pixelSize: 15
                        }
                        TextInput {
                            id: search
                            visible: find.open
                            anchors { left: parent.left; leftMargin: 32; right: clear.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                            color: Theme.text; selectionColor: Theme.coral; selectedTextColor: Theme.onAccent
                            font.family: Theme.font; font.pixelSize: 13
                            clip: true
                            onTextChanged: typing.restart()
                            Timer { id: typing; interval: 220; onTriggered: win.pane.query = search.text.trim() }
                            Keys.onEscapePressed: { search.text = ""; win.pane.query = ""; win.pane.refocus() }
                            Keys.onPressed: (e) => {
                                if (e.key === Qt.Key_Tab) { win.pane.everywhere = !win.pane.everywhere; e.accepted = true; return }
                                if (e.key === Qt.Key_Down || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {   // into the results
                                    typing.stop(); win.pane.query = search.text.trim(); win.pane.refocus()
                                    Qt.callLater(() => { const v = win.pane.shown(); if (v && v.count && !win.pane.cur) win.pane.cursor(v, 0, false) })
                                    e.accepted = true
                                }
                            }
                            Text {
                                visible: !search.text
                                text: win.pane.everywhere ? "Search everywhere" : "Search in " + win.name(win.pane.dir); color: Theme.dim
                                width: parent.width; elide: Text.ElideRight
                                font: search.font
                            }
                        }
                        Text {
                            id: clear
                            visible: search.text !== ""
                            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                            text: Theme.g("close"); color: cl.containsMouse ? Theme.text : Theme.muted
                            font.family: Theme.font; font.pixelSize: 13
                            MouseArea { id: cl; anchors { fill: parent; margins: -6 } hoverEnabled: true; onClicked: { search.text = ""; win.pane.query = ""; win.pane.refocus() } }
                        }
                        Connections {   // moving somewhere (or the other pane) ends / shows that pane's search
                            target: win
                            function onPaneChanged() { search.text = win.pane.query }
                        }
                        Connections {
                            target: win.pane
                            function onQueryChanged() { if (win.pane.query === "" && !search.activeFocus) search.text = "" }
                        }
                    }
                    Item { width: 8; height: 1; visible: scope.visible }
                    // where to search: this folder and below, or the whole computer (Tab in the box switches)
                    Choice {
                        id: scope
                        objectName: "scope"
                        visible: find.open
                        anchors.verticalCenter: parent.verticalCenter
                        options: ["Here", "Everywhere"]
                        current: win.pane.everywhere ? 1 : 0
                        onPicked: (i) => { win.pane.everywhere = i === 1; if (search.text.trim()) { typing.stop(); win.pane.query = search.text.trim() }; search.forceActiveFocus() }
                    }
                }
                Row {
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    spacing: 8
                    Rectangle {   // segmented view switch
                        width: seg.width + 4; height: 28; radius: 7
                        color: Theme.fill
                        Row {
                            id: seg
                            x: 2; anchors.verticalCenter: parent.verticalCenter
                            Repeater {
                                model: ["grid", "list", "columns"]
                                delegate: Rectangle {
                                    required property string modelData
                                    width: 36; height: 24; radius: 5
                                    color: win.pane.view === modelData ? Theme.fill2 : "transparent"
                                    Text { anchors.centerIn: parent; text: Theme.g(parent.modelData); color: win.pane.view === parent.modelData ? Theme.text : Theme.muted; font.family: Theme.font; font.pixelSize: 16 }
                                    MouseArea { anchors.fill: parent; onClicked: win.setView(parent.modelData) }
                                }
                            }
                        }
                    }
                    Key { visible: win.pane.view !== "columns"; icon: Theme.g("info"); size: 18; on: win.details; onClicked: win.details = !win.details }
                    Key { icon: Theme.g("split"); size: 17; on: win.split; onClicked: win.toggleSplit() }
                    Key {
                        icon: Theme.g("more"); size: 18
                        onClicked: {
                            const p = mapToItem(null, 0, height + 4)
                            win.showMenu([{ text: Fs.undoText ? "Undo " + Fs.undoText : "Nothing to Undo", key: "Ctrl+Z", run: win.undo }, { sep: true }]
                                         .concat(win.pane.folderMenu()).concat([{ sep: true },
                                         { text: "Disk Usage…", run: () => win.usageOf(win.pane.dir) },
                                         { text: "Zoom In", key: "Ctrl++", run: () => win.zoomBy(1) },
                                         { text: "Zoom Out", key: "Ctrl+-", run: () => win.zoomBy(-1) },
                                         { text: "Automatic Zoom" + (win.zoomSet ? "" : " ✓"), key: "Ctrl+0", run: win.zoomAutomatic },
                                         { text: win.sideShown ? "Hide Sidebar" : "Show Sidebar", key: "F9", run: () => win.sideShown = !win.sideShown },
                                         { text: "Network Locations…", run: () => win.netLocations("") },
                                         { sep: true }, { text: "Clear Preview Cache", warn: true, run: Fs.clearPreviews }]), p.x - 220 * win.zoom, p.y)
                        }
                    }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
            }

            // ----- one or two panes -----
            Item {
                id: panes
                anchors { left: parent.left; right: parent.right; top: bar.bottom; bottom: parent.bottom }
                Pane {
                    id: p1
                    objectName: "pane1"
                    win: win; other: p2
                    width: win.split ? Math.round(panes.width * win.splitRatio) : panes.width
                    height: panes.height
                    dir: Fs.startDir
                    sel: Fs.startSelect ? [Fs.startSelect] : []
                    cur: Fs.startSelect
                    anchorPath: Fs.startSelect
                    view: win.view
                    focus: true
                }
                Rectangle { visible: win.split; x: p1.width; width: 1; height: panes.height; color: Theme.hairline }
                Grip {
                    visible: win.split
                    x: p1.width - width / 2; height: panes.height; z: 5
                    property real r0
                    onStarted: r0 = win.splitRatio
                    onMoved: (dx) => win.splitRatio = Math.max(0.2, Math.min(0.8, r0 + dx / panes.width))
                }
                Pane {
                    id: p2
                    objectName: "pane2"
                    win: win; other: p1
                    visible: win.split
                    x: p1.width + 1
                    width: panes.width - p1.width - 1
                    height: panes.height
                    view: win.view
                    Component.onCompleted: if (win.split) dir = p1.dir   // split view remembered from last time
                }
            }
        }

        MouseArea {   // the mouse's side buttons: back / forward (other buttons pass through to what is underneath)
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.BackButton | Qt.ForwardButton
            onPressed: (m) => {
                if (m.button !== Qt.LeftButton && m.button !== Qt.RightButton) return
                m.accepted = false   // the click goes on to what is underneath; only, a click outside the search box leaves it
                const p = find.mapFromItem(this, m.x, m.y)
                if (search.activeFocus && !(p.x >= 0 && p.y >= 0 && p.x < find.width && p.y < find.height)) win.pane.refocus()
            }
            onClicked: (m) => { if (m.button === Qt.BackButton) win.pane.goBack(); else win.pane.goForward() }
            onWheel: (w) => {   // Ctrl+scroll = zoom; any other scroll goes on to the view underneath
                if (!(w.modifiers & Qt.ControlModifier)) { w.accepted = false; return }
                const d = w.angleDelta.y || w.angleDelta.x
                if (d) win.zoomBy(d > 0 ? 1 : -1)
            }
        }

        // ---------- overlays ----------
        Jobs {   // copy / move progress: a round button above the bottom-right corner, its list opens upward
            id: jobs; win: win
            anchors { fill: main; rightMargin: 18; bottomMargin: 28 + 16 }
        }
        QuickLook { id: look; anchors.fill: parent; path: win.pane.cur }
        LookSheet { id: lookSheet; win: win; anchors.fill: parent; onClosed: win.pane.refocus() }
        NetSheet { id: net; win: win; anchors.fill: parent; onClosed: win.pane.refocus() }
        Props { id: props; win: win; anchors.fill: parent; onClosed: win.pane.refocus() }
        Menu { id: menu; anchors.fill: parent; onClosed: win.pane.refocus() }
        Usage { id: usage; win: win; anchors.fill: parent; onClosed: win.pane.refocus() }
        Conflicts { id: conflictSheet; anchors.fill: parent; onClosed: win.pane.refocus() }
        Prompt { id: prompt; anchors.fill: parent; onClosed: win.pane.refocus() }
    }
}
