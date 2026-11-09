// Sidebar.qml -- the sidebar along the window's left edge (solid surface, hairline on the right), sections Favourites (home, XDG folders,
// GTK bookmarks = the same pins Nautilus and file dialogs show), Locations (drives: click an unmounted one to mount it,
// eject = unmount + power off; Trash) and Network. Refreshes on Fs.drivesChanged (no polling).
import QtQuick

Rectangle {
    id: root
    property var hub
    color: Theme.surface
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.hairline }
    readonly property var allPlaces: Fs.places()
    readonly property var hidden: hub.hiddenPlaces ? hub.hiddenPlaces.split("\n") : []
    readonly property var places: allPlaces.filter(p => hidden.indexOf(p.path) < 0)
    // right-click on any row: these first, then what belongs to that kind of row
    function menu(path, extra, x, y) {
        const w = root.hub
        root.hub.showMenu([{ text: "Open", run: () => w.pane.open(path) }]
            .concat(w.split ? [{ text: "Open in Other Pane", run: () => w.pane.other.open(path) }] : [])
            .concat([{ text: "Open in Terminal", run: () => Fs.terminal(path) },
                     { text: "Copy Path", run: () => { Fs.setText(path); w.flash("Copied the path") } }])
            .concat(extra.length ? [{ sep: true }].concat(extra) : []), x, y)
    }
    function drop(d, path, area) {
        if (!d.hasUrls || !path) return
        d.accept(Qt.CopyAction)
        const w = area.mapToItem(null, d.x, d.y)
        root.hub.drop(d.urls, path, w.x, w.y)
    }
    property var marks: Fs.bookmarks()
    property var drives: Fs.drives()
    Timer { id: later; interval: 300; onTriggered: { root.marks = Fs.bookmarks(); root.drives = Fs.drives() } }
    Connections { target: Fs; function onDrivesChanged() { later.restart() } }

    component Heading: Text {
        width: parent.width
        topPadding: 18; bottomPadding: 6; leftPadding: 10
        color: Theme.muted; font.family: Theme.font; font.pixelSize: 11; font.bold: true
    }
    component Place: Rectangle {
        id: p
        property string icon
        property string name
        property string path
        property string action: ""       // glyph of a small action on the right (eject)
        property bool dim: false
        readonly property bool on: path !== "" && root.hub.pane.dir === path
        signal clicked()
        signal actionClicked()
        signal menu(real x, real y)
        objectName: "place:" + name
        width: parent.width; height: 30; radius: 7
        color: dz.containsDrag ? Qt.alpha(Theme.coral, 0.18) : on ? Theme.fill2 : m.pressed ? Theme.fill : "transparent"
        border.width: dz.containsDrag ? 2 : 0; border.color: Theme.coral
        DropArea { id: dz; anchors.fill: parent; enabled: p.path !== "" && !p.dim; keys: ["text/uri-list"]; onDropped: (d) => root.drop(d, p.path, dz) }   // files dropped here go into it
        Text {
            id: ic
            x: 10; width: 20; anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: Theme.g(p.icon); color: p.dim ? Theme.dim : Theme.coral
            font.family: Theme.font; font.pixelSize: 16
        }
        Text {
            x: 38; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - x - (act.visible ? 30 : 8)
            text: p.name; elide: Text.ElideRight
            color: p.dim ? Theme.muted : Theme.text
            font.family: Theme.font; font.pixelSize: 13
        }
        MouseArea {
            id: m; anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPressed: (e) => { if (e.button === Qt.RightButton) { const w = mapToItem(null, e.x, e.y); p.menu(w.x, w.y) } else p.clicked() }
        }
        Text {
            id: act
            visible: p.action !== ""
            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
            text: p.action ? Theme.g(p.action) : ""; color: am.containsMouse ? Theme.text : Theme.muted
            font.family: Theme.font; font.pixelSize: 14
            MouseArea { id: am; anchors { fill: parent; margins: -6 } hoverEnabled: true; onClicked: p.actionClicked() }
        }
    }

    Flickable {
        anchors { fill: parent; margins: 8; topMargin: 2; rightMargin: 9 }
        contentHeight: col.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        acceptedButtons: Qt.NoButton
        Column {
            id: col
            width: parent.width
            spacing: 1
            Heading {
                text: "Favourites"
                color: fz.containsDrag ? Theme.coral : Theme.muted
                DropArea {   // a folder dropped on the heading is pinned to the sidebar
                    id: fz; anchors.fill: parent; keys: ["text/uri-list"]
                    onDropped: (d) => { d.accept(Qt.LinkAction); d.urls.forEach(u => { const p = Fs.path(u); if (Fs.isDir(p)) Fs.bookmark(p) }) }
                }
                MouseArea {
                    anchors.fill: parent; acceptedButtons: Qt.RightButton
                    enabled: root.hidden.length > 0
                    onPressed: (e) => { const w = mapToItem(null, e.x, e.y); root.hub.showMenu([{ text: "Show Hidden Places (" + root.hidden.length + ")", run: () => root.hub.hiddenPlaces = "" }], w.x, w.y) }
                }
            }
            Repeater {
                model: root.places
                delegate: Place {
                    required property var modelData
                    icon: modelData.icon; name: modelData.name; path: modelData.path
                    onClicked: root.hub.pane.open(path)
                    onMenu: (x, y) => root.menu(path, path === Fs.home ? [] : [{ text: "Remove from Sidebar", run: () => root.hub.hiddenPlaces = root.hidden.concat([path]).join("\n") }], x, y)
                }
            }
            Repeater {
                model: root.marks
                delegate: Place {
                    required property var modelData
                    icon: "folder"; name: modelData.name; path: modelData.path
                    onClicked: root.hub.pane.open(path)
                    onMenu: (x, y) => root.menu(path, [{ text: "Remove from Sidebar", run: () => Fs.unbookmark(path) }], x, y)
                }
            }

            Heading { text: "Locations" }
            Repeater {
                model: root.drives.filter(d => !d.network)
                delegate: Place {
                    required property var modelData
                    icon: modelData.removable ? "usb" : "drive"; name: modelData.name; path: modelData.path
                    dim: !modelData.path
                    action: modelData.removable && modelData.path ? "eject" : ""
                    onClicked: modelData.path ? root.hub.pane.open(path) : Fs.mount(modelData.dev)
                    onActionClicked: { if (root.hub.pane.dir.startsWith(path)) root.hub.pane.go(Fs.home); Fs.eject(modelData.dev, modelData.disk) }
                    onMenu: (x, y) => {
                        if (!path) root.hub.showMenu([{ text: "Mount", run: () => Fs.mount(modelData.dev) }], x, y)
                        else root.menu(path, modelData.removable ? [{ text: "Eject", run: () => actionClicked() }] : [], x, y)
                    }
                }
            }
            Place {
                icon: "trash"; name: "Trash"; path: Fs.trashDir
                onClicked: root.hub.pane.open(path)
                onMenu: (x, y) => root.hub.showMenu([{ text: "Open", run: () => root.hub.pane.open(Fs.trashDir) },
                                                     { sep: true }, { text: "Empty Trash", warn: true, run: () => Fs.emptyTrash() }], x, y)
            }

            Heading {
                text: "Network"
                Text {   // + : network locations (add / change / remove shares)
                    objectName: "netAdd"
                    anchors { right: parent.right; rightMargin: 10; bottom: parent.bottom; bottomMargin: 4 }
                    text: Theme.g("plus"); color: nm.containsMouse ? Theme.text : Theme.dim
                    font.family: Theme.font; font.pixelSize: 14
                    MouseArea { id: nm; anchors { fill: parent; margins: -6 } hoverEnabled: true; onClicked: root.hub.netLocations("") }
                }
            }
            Repeater {
                model: root.drives.filter(d => d.network)
                delegate: Place {
                    required property var modelData
                    icon: "network"; name: modelData.name; path: modelData.path
                    dim: Fs.offline.indexOf(path) >= 0
                    onClicked: root.hub.pane.open(path)   // go() refuses an offline share with a note in the status bar
                    onMenu: (x, y) => root.menu(path, [{ text: "Disconnect", run: () => Fs.disconnectShare(path) },
                                                       { text: "Change…", run: () => root.hub.netLocations(path) },
                                                       { text: "Network Locations…", run: () => root.hub.netLocations("") }], x, y)
                }
            }
        }
    }
}
