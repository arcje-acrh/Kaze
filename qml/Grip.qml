// Grip.qml -- a drag handle for resizing (sidebar edge, list column borders, column-view columns).
// onStarted: remember the width; onMoved(dx): dx = distance dragged since the press. A line shows on hover.
import QtQuick
import QtQuick.Window

MouseArea {
    id: g
    signal started()
    signal moved(real dx)
    property real x0
    width: 8
    hoverEnabled: true
    preventStealing: true
    cursorShape: Qt.SplitHCursor
    readonly property real zoom: Window.window?.zoom ?? 1      // dx in unzoomed units (the window content is zoomed)
    onPressed: (m) => { x0 = mapToItem(null, m.x, 0).x; started() }
    onPositionChanged: (m) => { if (pressed) moved((mapToItem(null, m.x, 0).x - x0) / zoom) }
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 2; height: parent.height; radius: 1
        color: Theme.coral
        opacity: g.pressed ? 0.8 : g.containsMouse ? 0.4 : 0
    }
}
