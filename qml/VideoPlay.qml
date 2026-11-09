// VideoPlay.qml -- a video playing in the preview: the picture, then a play / pause key, an LED bar (click or drag to
// jump) and the time. Made only when the play key is pressed (Preview.qml), so browsing past videos loads no player;
// the file is read by Qt's FFmpeg backend on its own threads (a video on a share does not hold up the window).
import QtQuick
import QtMultimedia

Item {
    id: root
    objectName: "videoPlayer"
    property string path
    readonly property alias player: mp
    function toggle() { if (mp.playbackState === MediaPlayer.PlayingState) mp.pause(); else mp.play() }
    function clock(ms) {
        const s = Math.max(0, Math.floor(ms / 1000)), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60
        return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(s % 60).padStart(2, "0")
    }

    MediaPlayer {
        id: mp
        source: Fs.url(root.path)
        videoOutput: out
        audioOutput: AudioOutput {}
        Component.onCompleted: play()
    }
    VideoOutput {
        id: out
        objectName: "videoOut"
        anchors { left: parent.left; right: parent.right; top: parent.top; bottom: bar.top; bottomMargin: 8 }
        MouseArea { anchors.fill: parent; onClicked: root.toggle() }
    }
    Text {   // a file Qt can't play: say so (the frame and details stay in the panel)
        anchors.centerIn: out
        width: out.width - 20; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
        visible: mp.error !== MediaPlayer.NoError
        text: "Can’t play this video: " + mp.errorString
        color: Theme.amber; font.family: Theme.font; font.pixelSize: 12
    }
    Row {
        id: bar
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 24; spacing: 8
        Key {
            id: playKey
            objectName: "videoPlayPause"
            anchors.verticalCenter: parent.verticalCenter
            icon: Theme.g(mp.playbackState === MediaPlayer.PlayingState ? "pause" : "play"); size: 18
            onClicked: root.toggle()
        }
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - playKey.width - time.width - 2 * parent.spacing; height: 20
            LedBar {
                id: seek
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width; segH: 10
                frac: mp.duration > 0 ? mp.position / mp.duration : 0
            }
            MouseArea {
                objectName: "videoSeek"
                anchors.fill: parent
                function jump(x) { if (mp.seekable && mp.duration > 0) mp.position = Math.max(0, Math.min(1, x / width)) * mp.duration }
                onPressed: (e) => jump(e.x)
                onPositionChanged: (e) => { if (pressed) jump(e.x) }
            }
        }
        Text {
            id: time
            anchors.verticalCenter: parent.verticalCenter
            text: root.clock(mp.position) + " / " + root.clock(mp.duration)
            color: Theme.muted; font.family: Theme.font; font.pixelSize: 11
            font.features: { "calt": 0, "liga": 0 }
        }
    }
}
