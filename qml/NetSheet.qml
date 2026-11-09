// NetSheet.qml -- Network locations: the SMB shares in /etc/fstab, listed with their state (connected / connects
// when opened / server not answering), and a form to add or change one: server (with the ones announcing themselves
// nearby), share, the folder in your home, sign-in (user + password, or guest), when it connects, when it lets go,
// SMB version, read only. Saving tries the share first and goes through pkexec (tools/kaze-share): the system asks
// for your password. The password you type for the share goes to the helper only, never to a file you can read.
import QtQuick

Item {
    id: root
    visible: false
    property var win
    property var list: []
    property var servers: []
    property bool editing: false
    property var was: null              // the share being changed (null = a new one)
    property bool busy: false
    property string error: ""
    property string removing: ""        // path asking "remove?"
    signal closed()

    function refresh() { list = Fs.shares() }
    function show(path) {               // path: open that share's form; "" = the list (or the form when there are none)
        refresh(); error = ""; removing = ""; busy = false
        visible = true
        Fs.findServers()
        const s = list.find(x => x.path === path)
        if (s) edit(s); else if (!list.length) edit(null); else editing = false
        forceActiveFocus()
    }
    function close() { visible = false; editing = false; closed() }
    function back() { if (busy) return; if (editing && list.length) { editing = false; error = ""; root.forceActiveFocus() } else close() }

    function edit(s) {
        was = s; error = ""
        server.text = s ? s.server : ""
        share.text = s ? s.share : ""
        folder.text = s ? s.name : ""
        folderTouched = !!s
        user.text = ""; pass.text = ""; domain.text = ""
        signIn = s && s.guest ? 1 : 0
        connectAt = s && s.boot ? 1 : 0
        idle = s ? (s.boot ? 600 : s.idle) : 600
        vers = s ? s.vers : ""
        readOnly = s ? s.ro : false
        check = true
        editing = true
        server.focusIn()
        if (s) Fs.knock(s.server)
    }
    // the form
    property bool folderTouched: false
    property int signIn: 0              // 0 user, 1 guest
    property int connectAt: 0           // 0 when opened, 1 at startup
    property int idle: 600
    property string vers: ""
    property bool readOnly: false
    property bool check: true
    property string answering: ""       // "", "yes", "no", "…"
    readonly property bool keepLogin: !!was && was.signedIn && !was.guest && signIn === 0 && user.text === "" && pass.text === ""
    readonly property var idles: [[300, "5 min"], [600, "10 min"], [1800, "30 min"], [0, "Never"]]
    readonly property var versions: [["", "Automatic"], ["3.1.1", "3.1.1"], ["3.0", "3.0"], ["2.1", "2.1"], ["1.0", "1.0"]]

    function save() {
        if (busy) return
        const h = server.text.trim().replace(/^smb:\/\//, "").replace(/^\/\//, "")
        let sh = share.text.trim(), srv = h
        if (h.includes("/")) { srv = h.split("/")[0]; if (!sh) sh = h.split("/").slice(1).join("/") }   // "nas/media" in one go
        const f = folder.text.trim() || sh
        if (!srv) { error = "Type the server's name or address"; return }
        if (!sh) { error = "Type the name of the share"; return }
        if (!f || f.includes("/") || f === "." || f === "..") { error = "Not a valid folder name"; return }
        const path = Fs.home + "/" + f
        if ((!was || was.path !== path) && root.list.some(x => x.path === path)) { error = "Another location already uses ~/" + f; return }
        if (signIn === 0 && !keepLogin && !user.text.trim()) { error = "Type your user name for this server (or choose Guest)"; return }
        error = ""; busy = true
        Fs.saveShare({ old: was ? was.path : "", server: srv, share: sh, path: path,
                       user: user.text.trim(), password: pass.text, domain: domain.text.trim(),
                       guest: signIn === 1, keep: keepLogin, vers: vers, ro: readOnly,
                       boot: connectAt === 1, idle: idle, check: check })
    }

    Connections {
        target: Fs
        function onShareDone(ok, message) {
            if (!root.visible) { if (!ok && message) root.win.flash(message, true); return }
            root.busy = false
            if (ok) { pass.text = ""; root.refresh(); root.editing = false; root.removing = ""; root.error = ""; if (message) root.win.flash(message); root.forceActiveFocus() }
            else root.error = message
        }
        function onServersFound(s) { root.servers = s }
        function onKnocked(host, up) { if (host === root.serverHost()) root.answering = up ? "yes" : "no" }
        function onOfflineChanged() { if (root.visible) root.refresh() }
        function onDrivesChanged() { if (root.visible && !root.editing) root.refresh() }
    }
    function serverHost() { return server.text.trim().replace(/^smb:\/\//, "").replace(/^\/\//, "").split("/")[0] }
    Timer { id: knockLater; interval: 600; onTriggered: { root.answering = root.serverHost() ? "…" : ""; Fs.knock(root.serverHost()) } }

    Keys.onEscapePressed: back()

    // ---------- pieces ----------
    component Label: Text {
        width: 110; horizontalAlignment: Text.AlignRight
        color: Theme.dim; font.family: Theme.font; font.pixelSize: 12
    }
    component Field: Rectangle {
        id: fld
        property alias text: ti.text
        property alias input: ti
        property string hint: ""
        property bool secret: false
        signal accepted()
        width: 260; height: 30; radius: 6
        color: Theme.bg
        border.width: ti.activeFocus ? 2 : 1; border.color: ti.activeFocus ? Qt.alpha(Theme.coral, 0.6) : Theme.hairline
        function focusIn() { ti.forceActiveFocus() }
        TextInput {
            id: ti
            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
            verticalAlignment: TextInput.AlignVCenter
            clip: true; activeFocusOnTab: true
            echoMode: fld.secret ? TextInput.Password : TextInput.Normal
            color: Theme.text; selectionColor: Theme.coral; selectedTextColor: Theme.onAccent
            font.family: Theme.font; font.pixelSize: 13
            Keys.onReturnPressed: root.save()
            Keys.onEnterPressed: root.save()
            Keys.onEscapePressed: root.back()
            Text {
                visible: !ti.text && !ti.activeFocus || !ti.text && fld.hint.length > 0 && ti.activeFocus
                anchors.verticalCenter: parent.verticalCenter
                text: fld.hint; color: Theme.dim; font: ti.font
            }
        }
    }
    component Led: Rectangle {
        property color lit: Theme.coral
        property bool glow: true
        width: 6; height: 6; radius: 3; color: lit
        Rectangle { visible: parent.glow; anchors.centerIn: parent; width: 12; height: 12; radius: 6; z: -1; color: Qt.alpha(parent.lit, 0.3) }
    }

    // ---------- the sheet ----------
    Rectangle { anchors.fill: parent; color: Qt.alpha(Theme.shadow, 0.3) }
    MouseArea { anchors.fill: parent; onPressed: if (!root.busy) root.close() }

    Rectangle {
        id: card
        objectName: "netSheet"
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(20, Math.min(70, parent.height * 0.08))
        width: Math.min(parent.width - 40, 560)
        height: Math.min(parent.height - y - 20, body.height + 40)
        color: Theme.surface; radius: 10
        border.width: 1; border.color: Theme.hairline
        MouseArea { anchors.fill: parent }
        Flickable {
            anchors { fill: parent; margins: 20 }
            contentHeight: body.height; clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: body
                width: parent.width
                spacing: 14

                // ----- heading -----
                Row {
                    spacing: 12
                    Text { text: Theme.g("network"); color: Theme.coral; font.family: Theme.font; font.pixelSize: 26; anchors.verticalCenter: parent.verticalCenter }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3
                        Text {
                            text: !root.editing ? "Network locations" : root.was ? "Change “" + root.was.name + "”" : "Add a network location"
                            color: Theme.text; font.family: Theme.font; font.pixelSize: 14; font.bold: true
                        }
                        Text {
                            width: body.width - 50; wrapMode: Text.Wrap
                            text: !root.editing ? "Shared folders on other computers (SMB / Windows sharing). Each one is a folder in your home that connects when you open it."
                                                : "A shared folder on another computer, as a folder in your home."
                            color: Theme.muted; font.family: Theme.font; font.pixelSize: 12
                        }
                    }
                }

                // ----- the list -----
                Column {
                    visible: !root.editing
                    width: parent.width
                    spacing: 0
                    Repeater {
                        model: root.list
                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            required property int index
                            objectName: "share:" + modelData.name
                            readonly property bool fixShown: modelData.needsFix && root.removing !== modelData.path
                            width: body.width; height: root.removing === modelData.path || fixShown ? 88 : 58
                            radius: 6
                            color: rma.containsMouse ? Theme.fill : "transparent"
                            MouseArea { id: rma; anchors.fill: parent; hoverEnabled: true; onDoubleClicked: { root.win.pane.open(row.modelData.path); root.close() } }
                            Rectangle { visible: row.index > 0; width: parent.width - 20; x: 10; height: 1; color: Theme.hairline }
                            Text {
                                x: 12; y: 14
                                text: Theme.g("network"); color: row.modelData.offline ? Theme.dim : Theme.coral
                                font.family: Theme.font; font.pixelSize: 20
                            }
                            Column {
                                x: 44; y: 11; width: parent.width - x - keys.width - 16
                                spacing: 4
                                Text { width: parent.width; elide: Text.ElideRight; text: row.modelData.name; color: Theme.text; font.family: Theme.font; font.pixelSize: 13; font.bold: true }
                                Row {
                                    spacing: 8
                                    Led {
                                        anchors.verticalCenter: parent.verticalCenter
                                        lit: row.modelData.offline ? Theme.amber : row.modelData.mounted ? Theme.coral : Theme.dim
                                        glow: row.modelData.offline || row.modelData.mounted
                                    }
                                    Text {
                                        width: Math.min(implicitWidth, row.width - 44 - keys.width - 30); elide: Text.ElideRight
                                        text: (row.modelData.offline ? "Not answering" : row.modelData.mounted ? "Connected" : row.modelData.boot ? "Not connected" : "Connects when opened")
                                              + "  ·  //" + row.modelData.server + "/" + row.modelData.share + (row.modelData.ro ? "  ·  read only" : "")
                                        color: row.modelData.offline ? Theme.amber : Theme.muted; font.family: Theme.font; font.pixelSize: 11
                                    }
                                }
                            }
                            Row {
                                id: keys
                                anchors { right: parent.right; rightMargin: 10; top: parent.top; topMargin: 15 }
                                spacing: 4
                                Btn { label: "Open"; width: 60; enabled: !row.modelData.offline; onHit: { root.win.pane.open(row.modelData.path); root.close() } }
                                Btn { label: "Disconnect"; visible: row.modelData.mounted; onHit: Fs.disconnectShare(row.modelData.path) }
                                Btn { objectName: "edit:" + row.modelData.name; label: "Change"; width: 70; onHit: root.edit(row.modelData) }
                                Btn { objectName: "remove:" + row.modelData.name; label: "Remove"; width: 70; onHit: root.removing = row.modelData.path }
                            }
                            Row {   // without noserverino, Unraid-style servers answer "stale file handle": one key adds it
                                visible: row.fixShown
                                x: 44; y: 54
                                spacing: 8
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: row.width - 44 - fixKey.width - 30; elide: Text.ElideRight
                                    text: Fs.busy ? "Can fail with “stale file handle”. Fix it once the copy is done."
                                                  : "Can fail with “stale file handle” (Unraid and similar servers)."
                                    color: Theme.amber; font.family: Theme.font; font.pixelSize: 11
                                }
                                Btn {
                                    id: fixKey
                                    objectName: "fix:" + row.modelData.name
                                    label: "Fix"; width: 60; primary: true
                                    enabled: !root.busy && !Fs.busy   // reconnecting under a running copy would not take
                                    onHit: { root.busy = true; Fs.fixShare(row.modelData.path) }
                                }
                            }
                            Row {   // remove? (inline, no second dialog)
                                visible: root.removing === row.modelData.path
                                x: 44; y: 54
                                spacing: 8
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: row.width - 44 - 180; elide: Text.ElideRight
                                    text: "Remove it? Nothing on the server is touched."
                                    color: Theme.amber; font.family: Theme.font; font.pixelSize: 11
                                }
                                Btn { label: "Keep"; onHit: root.removing = "" }
                                Btn { objectName: "confirmRemove"; label: "Remove"; primary: true; enabled: !root.busy; onHit: { root.busy = true; Fs.removeShare(row.modelData.path) } }
                            }
                        }
                    }
                    Text {
                        visible: !root.list.length
                        text: "No network locations yet."
                        color: Theme.muted; font.family: Theme.font; font.pixelSize: 12
                    }
                }

                // ----- the form -----
                Column {
                    id: form
                    visible: root.editing
                    width: parent.width
                    spacing: 10

                    Row {
                        spacing: 12
                        Label { text: "Server"; anchors.verticalCenter: parent.verticalCenter }
                        Field {
                            id: server; objectName: "field:server"
                            hint: "name or address, e.g. 192.168.0.10"
                            input.onTextEdited: { root.answering = ""; knockLater.restart() }
                        }
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            visible: root.answering !== ""
                            Led { anchors.verticalCenter: parent.verticalCenter; lit: root.answering === "yes" ? Theme.coral : root.answering === "no" ? Theme.amber : Theme.dim; glow: root.answering !== "…" }
                            Text {
                                text: root.answering === "yes" ? "answering" : root.answering === "no" ? "not answering" : "checking…"
                                color: root.answering === "no" ? Theme.amber : Theme.muted; font.family: Theme.font; font.pixelSize: 11
                            }
                        }
                    }
                    Flow {   // nearby servers
                        visible: root.servers.length > 0
                        x: 122; width: parent.width - x
                        spacing: 4
                        Text { text: "Nearby:"; height: 24; verticalAlignment: Text.AlignVCenter; color: Theme.dim; font.family: Theme.font; font.pixelSize: 11; rightPadding: 4 }
                        Repeater {
                            model: root.servers
                            delegate: Rectangle {
                                required property var modelData
                                width: nt.implicitWidth + 16; height: 24; radius: 2
                                color: nma.containsMouse ? Theme.hover : Theme.raised
                                Text { id: nt; anchors.centerIn: parent; text: parent.modelData.name + "  " + parent.modelData.address; color: Theme.text; font.family: Theme.font; font.pixelSize: 11 }
                                MouseArea { id: nma; anchors.fill: parent; hoverEnabled: true; onClicked: { server.text = parent.modelData.address; knockLater.restart(); share.focusIn() } }
                            }
                        }
                    }
                    Row {
                        spacing: 12
                        Label { text: "Shared folder"; anchors.verticalCenter: parent.verticalCenter }
                        Field {
                            id: share; objectName: "field:share"
                            hint: "its name on the server"
                            input.onTextEdited: if (!root.folderTouched) folder.text = share.text.trim().split("/").pop()
                        }
                    }
                    Row {
                        spacing: 12
                        Label { text: "Opens at"; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: "~/"; anchors.verticalCenter: parent.verticalCenter; color: Theme.muted; font.family: Theme.font; font.pixelSize: 13 }
                        Field { id: folder; objectName: "field:folder"; width: 238; hint: "a folder in your home"; input.onTextEdited: root.folderTouched = true }
                    }
                    Text {   // what the two mean: the share lives on the server, its files show up in this folder here
                        x: 122; width: parent.width - x; elide: Text.ElideMiddle
                        visible: root.serverHost() !== "" && share.text.trim() !== ""
                        text: "//" + root.serverHost() + "/" + share.text.trim() + "  →  ~/" + folder.text.trim()
                              + "   (its files appear in that folder on this computer)"
                        color: Theme.dim; font.family: Theme.font; font.pixelSize: 11
                    }

                    Rectangle { width: parent.width; height: 1; color: Theme.hairline }
                    Row {
                        spacing: 12
                        Label { text: "Sign in"; anchors.verticalCenter: parent.verticalCenter }
                        Choice { options: ["As a user", "As a guest"]; current: root.signIn; onPicked: (i) => root.signIn = i }
                    }
                    Row {
                        visible: root.signIn === 0
                        spacing: 12
                        Label { text: "User"; anchors.verticalCenter: parent.verticalCenter }
                        Field { id: user; objectName: "field:user"; hint: root.was && root.was.signedIn && !root.was.guest ? "unchanged" : "" }
                    }
                    Row {
                        visible: root.signIn === 0
                        spacing: 12
                        Label { text: "Password"; anchors.verticalCenter: parent.verticalCenter }
                        Field { id: pass; objectName: "field:password"; secret: !showPass.on; hint: root.was && root.was.signedIn && !root.was.guest ? "unchanged" : "" }
                        Text {
                            id: showPass
                            property bool on: false
                            anchors.verticalCenter: parent.verticalCenter
                            text: Theme.g(on ? "eyeOff" : "eye"); color: spm.containsMouse ? Theme.text : Theme.muted
                            font.family: Theme.font; font.pixelSize: 16
                            MouseArea { id: spm; anchors { fill: parent; margins: -6 } hoverEnabled: true; onClicked: showPass.on = !showPass.on }
                        }
                    }
                    Row {
                        visible: root.signIn === 0
                        spacing: 12
                        Label { text: "Domain"; anchors.verticalCenter: parent.verticalCenter }
                        Field { id: domain; width: 160; hint: "usually empty" }
                    }
                    Text {
                        visible: root.signIn === 0
                        x: 122; width: parent.width - x; wrapMode: Text.Wrap
                        text: root.keepLogin ? "The saved user name and password stay. Type new ones to replace them."
                                             : "Kept in a file only the system can read (/etc/samba/credentials)."
                        color: Theme.dim; font.family: Theme.font; font.pixelSize: 11
                    }

                    Rectangle { width: parent.width; height: 1; color: Theme.hairline }
                    Row {
                        spacing: 12
                        Label { text: "Connect"; anchors.verticalCenter: parent.verticalCenter }
                        Choice { options: ["When opened", "At startup"]; current: root.connectAt; onPicked: (i) => root.connectAt = i }
                    }
                    Row {
                        visible: root.connectAt === 0
                        spacing: 12
                        Label { text: "Let go after"; anchors.verticalCenter: parent.verticalCenter }
                        Choice {
                            options: root.idles.map(x => x[1])
                            current: Math.max(0, root.idles.findIndex(x => x[0] === root.idle))
                            onPicked: (i) => root.idle = root.idles[i][0]
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "unused"; color: Theme.dim; font.family: Theme.font; font.pixelSize: 11 }
                    }
                    Row {
                        spacing: 12
                        Label { text: "SMB version"; anchors.verticalCenter: parent.verticalCenter }
                        Choice {
                            options: root.versions.map(x => x[1])
                            current: Math.max(0, root.versions.findIndex(x => x[0] === root.vers))
                            onPicked: (i) => root.vers = root.versions[i][0]
                        }
                    }
                    Row {
                        spacing: 12
                        Label { text: ""; anchors.verticalCenter: parent.verticalCenter }
                        Column {
                            spacing: 6
                            Switch { label: "Read only"; checked: root.readOnly; onToggled: root.readOnly = !root.readOnly }
                            Switch { label: "Try connecting before saving"; checked: root.check; onToggled: root.check = !root.check }
                        }
                    }
                }

                // ----- message + buttons -----
                Text {
                    objectName: "netError"
                    visible: root.error !== "" || root.busy
                    width: parent.width; wrapMode: Text.Wrap
                    text: root.busy ? (root.editing && root.check ? "Connecting to the server… (the system may ask for your password)" : "Waiting for the system… (it may ask for your password)") : root.error
                    color: root.busy ? Theme.muted : Theme.amber; font.family: Theme.font; font.pixelSize: 12
                }
                Item {
                    width: parent.width; height: 28
                    Btn {
                        visible: !root.editing
                        objectName: "addShare"
                        label: "Add a location"
                        onHit: root.edit(null)
                    }
                    Row {
                        anchors.right: parent.right
                        spacing: 8
                        Btn { label: root.editing && root.list.length ? "Back" : root.editing ? "Cancel" : "Done"; enabled: !root.busy; onHit: root.back() }
                        Btn { visible: root.editing; objectName: "saveShare"; label: root.was ? "Save" : "Add"; primary: true; enabled: !root.busy; onHit: root.save() }
                    }
                }
            }
        }
    }
}
