// Jobs.qml -- copy / move / zip / extract progress, inside the window (no second window): a round button at the
// bottom-right shows the overall progress as a ring while anything runs; click it for the list -- each job with an
// LED bar, bytes (or items, for trash / delete), speed, time left, a pause key and a stop key. When the last job
// ends the button shows a check and goes away; a job that failed stays in the list (amber) until dismissed.
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property var win
    readonly property var jobs: Fs.jobs
    readonly property var run: jobs.length && jobs[0].running ? jobs[0] : null
    readonly property int failed: jobs.filter(j => j.failed).length
    readonly property bool active: jobs.length > failed
    // overall: bytes (or items) of the running job; unknown total = how many of its items are done; else -1
    readonly property real frac: run && run.total > 0 ? Math.min(1, run.done / run.total) : run && run.steps > 1 ? (run.step - 1) / run.steps : -1
    property bool finished: false      // the check, briefly, after the last job
    property bool open: false
    readonly property bool shown: jobs.length > 0 || finished
    property bool lastOk: false
    onActiveChanged: if (!active) { if (!failed) open = false; finished = lastOk && !failed; lastOk = false; doneTimer.restart() } else finished = false
    onFailedChanged: if (!jobs.length) open = false
    Connections {
        target: Fs
        function onJobDone(verb, name, how) {
            root.lastOk = how === "done"
            if (how === "stopped" && root.win) root.win.flash("Stopped " + verb.toLowerCase() + " “" + name + "”")
        }
    }
    Timer { id: doneTimer; interval: 2200; onTriggered: root.finished = false }

    function bytes(b) { return Fs.size(Math.round(b)) }
    function time(s) {
        if (s < 0) return ""
        if (s < 60) return Math.max(1, Math.ceil(s)) + " s left"
        if (s < 3600) return Math.round(s / 60) + " min left"
        return Math.floor(s / 3600) + " h " + Math.round(s % 3600 / 60) + " min left"
    }
    function title(j) { return j.verb === "Moving to Trash" ? "Moving “" + j.name + "” to the Trash" : j.verb + " “" + j.name + "”" }
    function line(j) {
        if (j.failed) return j.error
        if (!j.running) return "Waiting"
        if (j.paused) return "Paused  ·  " + (j.items ? j.done + " of " + j.total : bytes(j.done) + (j.total > 0 ? " of " + bytes(j.total) : ""))
        if (j.items) return j.done + " of " + j.total + (j.total === 1 ? " item" : " items")
        const parts = [j.total > 0 ? bytes(j.done) + " of " + bytes(j.total) : j.done > 0 ? bytes(j.done) : "Starting…"]
        if (j.speed > 0) parts.push(bytes(j.speed) + "/s")
        if (j.eta >= 0 && j.speed > 0) parts.push(time(j.eta))
        return parts.join("  ·  ")
    }

    // a click outside the open list closes it
    MouseArea { anchors.fill: parent; enabled: root.open; onPressed: root.open = false }

    // ----- the list, growing up from the button -----
    Rectangle {
        id: list
        objectName: "jobList"
        visible: root.open
        anchors { right: btn.right; bottom: btn.top; bottomMargin: 10 }
        width: 360; height: Math.min(col.height + 16, root.height - 120)
        color: Theme.surface; radius: 10
        border.width: 1; border.color: Theme.hairline
        MouseArea { anchors.fill: parent }   // clicks inside stay inside
        Flickable {
            anchors { fill: parent; margins: 8 }
            contentHeight: col.height; clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: col
                width: parent.width
                Repeater {
                    model: root.jobs
                    delegate: Item {
                        id: job
                        required property var modelData
                        required property int index
                        width: col.width; height: info.height + 20
                        Rectangle { visible: job.index > 0; width: parent.width - 16; x: 8; height: 1; color: Theme.hairline }
                        Column {
                            id: info
                            x: 10; y: 10; width: parent.width - 20 - (stop.visible ? 30 : 0) - (pauseKey.visible ? 28 : 0)
                            spacing: 5
                            Text {
                                width: parent.width; elide: Text.ElideMiddle
                                text: (job.modelData.failed ? Theme.g("alert") + "  " : "") + root.title(job.modelData)
                                color: job.modelData.failed ? Theme.amber : Theme.text; font.family: Theme.font; font.pixelSize: 12; font.bold: true
                            }
                            Text {
                                width: parent.width; elide: Text.ElideMiddle
                                text: (["Copying", "Moving", "Linking"].indexOf(job.modelData.verb) >= 0 ? "to " : job.modelData.verb === "Moving to Trash" ? "from " : "in ") + root.win.name(job.modelData.where)
                                      + (job.modelData.now ? "  ·  " + job.modelData.step + " of " + job.modelData.steps + ": " + job.modelData.now : "")
                                color: Theme.muted; font.family: Theme.font; font.pixelSize: 11
                            }
                            LedBar {
                                width: parent.width; segH: 8
                                visible: job.modelData.running
                                off: job.modelData.paused
                                frac: job.modelData.total > 0 ? job.modelData.done / job.modelData.total : job.modelData.steps > 1 ? (job.modelData.step - 1) / job.modelData.steps : 0
                                // unknown total: a lit block runs along the bar
                                Timer { running: parent.visible && job.modelData.total <= 0 && job.modelData.steps <= 1 && !job.modelData.paused; repeat: true; interval: 90; onTriggered: parent.mark = (parent.mark + 0.04) % 1 }
                            }
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                text: root.line(job.modelData)
                                wrapMode: job.modelData.failed ? Text.Wrap : Text.NoWrap
                                color: job.modelData.failed ? Theme.muted : Theme.dim; font.family: Theme.font; font.pixelSize: 11
                                font.features: { "calt": 0, "liga": 0 }
                            }
                        }
                        Rectangle {   // pause / go on: a square key
                            id: pauseKey
                            objectName: "pause:" + job.modelData.name
                            visible: job.modelData.running
                            anchors { right: stop.left; rightMargin: 4; top: parent.top; topMargin: 10 }
                            width: 24; height: 24; radius: 4
                            color: pm.containsMouse ? Theme.fill2 : Theme.fill
                            Text { anchors.centerIn: parent; text: Theme.g(job.modelData.paused ? "play" : "pause"); color: job.modelData.paused ? Theme.coral : Theme.muted; font.family: Theme.font; font.pixelSize: 13 }
                            MouseArea { id: pm; anchors.fill: parent; hoverEnabled: true; onClicked: Fs.pause(job.modelData.id, !job.modelData.paused) }
                        }
                        Rectangle {   // stop (a running move finishes the item it is on) / dismiss a failed one: a square key
                            id: stop
                            objectName: (job.modelData.failed ? "dismiss:" : "stop:") + job.modelData.name
                            visible: true
                            anchors { right: parent.right; rightMargin: 8; top: parent.top; topMargin: 10 }
                            width: 24; height: 24; radius: 4
                            color: sm.containsMouse ? Theme.fill2 : Theme.fill
                            Text { anchors.centerIn: parent; text: Theme.g("close"); color: sm.containsMouse ? Theme.amber : Theme.muted; font.family: Theme.font; font.pixelSize: 13 }
                            MouseArea { id: sm; anchors.fill: parent; hoverEnabled: true; onClicked: job.modelData.failed ? Fs.dismiss(job.modelData.id) : Fs.cancel(job.modelData.id) }
                        }
                    }
                }
            }
        }
    }

    // ----- the button: a ring of progress around the percentage -----
    Rectangle {
        id: btn
        objectName: "jobs"
        anchors { right: parent.right; bottom: parent.bottom }
        width: 46; height: 46; radius: 23
        visible: root.shown
        color: bm.containsMouse || root.open ? Theme.raised : Theme.surface
        border.width: 1; border.color: Theme.hairline
        Rectangle { anchors.fill: parent; anchors.margins: -3; radius: width / 2; z: -1; color: Qt.alpha(Theme.shadow, 0.18) }
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {   // track
                strokeColor: Theme.raised; strokeWidth: 3; fillColor: "transparent"
                PathAngleArc { centerX: 23; centerY: 23; radiusX: 18; radiusY: 18; startAngle: 0; sweepAngle: 360 }
            }
            ShapePath {   // done part; unknown = a quarter arc that turns
                strokeColor: root.run && root.run.paused ? Theme.dim : Theme.coral; strokeWidth: 3; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: 23; centerY: 23; radiusX: 18; radiusY: 18
                    startAngle: root.frac >= 0 || root.finished ? -90 : spin.angle
                    sweepAngle: root.finished ? 360 : !root.active ? 0 : root.frac >= 0 ? Math.max(4, 360 * root.frac) : 90
                }
            }
        }
        QtObject { id: spin; property real angle: 0 }
        NumberAnimation { target: spin; property: "angle"; from: 0; to: 360; duration: 1100; loops: Animation.Infinite; running: root.active && root.frac < 0 && !root.finished }
        Text {
            anchors.centerIn: parent
            text: root.finished ? Theme.g("check") : !root.active && root.failed ? Theme.g("alert") : root.frac >= 0 ? Math.floor(root.frac * 100) + "" : root.jobs.length > 1 ? root.jobs.length + "" : "…"
            color: root.finished ? Theme.coral : !root.active && root.failed ? Theme.amber : Theme.text
            font.family: Theme.font; font.pixelSize: root.finished || !root.active ? 18 : 12; font.bold: true
        }
        Rectangle {   // more waiting: a small count in the corner
            visible: root.jobs.length > 1 && root.frac >= 0 && root.active
            anchors { right: parent.right; top: parent.top; margins: -2 }
            width: 16; height: 16; radius: 8; color: Theme.amber
            Text { anchors.centerIn: parent; text: root.jobs.length; color: Theme.onAccent; font.family: Theme.font; font.pixelSize: 9; font.bold: true }
        }
        MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true; onClicked: if (root.jobs.length) root.open = !root.open }
    }
}
