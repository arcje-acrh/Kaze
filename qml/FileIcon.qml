// FileIcon.qml -- Finder-style icons, drawn (no icon theme needed, follows the theme colours):
// folders = accent folder with an emblem for special folders; files = a page with a folded corner, the kind's glyph
// and the extension; images (always) and pdf / video (when big) = a real thumbnail.
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property string path
    property string kind: "file"
    property string suffix: ""
    property string emblem: ""          // glyph name on a folder (Desktop, Downloads, ... or chosen in Properties > Look)
    property string tint: ""            // folder colour: a Theme.tints name ("" = accent)
    readonly property real s: Math.min(width, height)
    readonly property bool big: s >= 40
    readonly property bool wantsPreview: big && (kind === "pdf" || kind === "video" || kind === "raw" || kind === "book" || (kind === "model" && Fs.modelPreview) || (Fs.officePreview && (kind === "doc" || kind === "sheet" || kind === "slides")))

    property string thumb: ""
    function load() {
        if (kind === "image" || wantsPreview) { const t = Fs.preview(path, kind); thumb = t ? Fs.imageUrl(t) : "" }
        else thumb = ""
    }
    onPathChanged: Qt.callLater(load)   // after `kind` (set by the same delegate) has caught up
    onKindChanged: Qt.callLater(load)
    onBigChanged: Qt.callLater(load)
    Component.onCompleted: load()
    Connections {
        target: root.wantsPreview || root.kind === "image" ? Fs : null
        function onPreviewReady(p, img) { if (p === root.path) root.thumb = Fs.imageUrl(img) }
    }

    readonly property bool showThumb: pic.status === Image.Ready

    // ----- thumbnail (with a thin frame, like Finder) -----
    Rectangle {
        visible: root.showThumb
        anchors.centerIn: pic
        width: pic.paintedWidth + 2; height: pic.paintedHeight + 2
        color: "transparent"; border.width: 1; border.color: Theme.hairline
        radius: root.big ? 3 : 1
    }
    Image {
        id: pic
        anchors.fill: parent
        anchors.margins: root.big ? root.s * 0.04 : 1
        source: root.thumb
        sourceSize: Qt.size(Math.max(64, root.s * 2), Math.max(64, root.s * 2))
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        visible: root.showThumb
    }

    // ----- folder -----
    Item {
        visible: root.kind === "folder" && !root.showThumb
        width: root.s; height: root.s
        anchors.centerIn: parent
        readonly property color body: Theme.tint(root.tint)
        readonly property color back: Qt.darker(body, 1.28)
        Rectangle { x: parent.width * 0.06; y: parent.height * 0.16; width: parent.width * 0.36; height: parent.height * 0.14; radius: parent.width * 0.04; color: parent.back }
        Rectangle { x: parent.width * 0.06; y: parent.height * 0.22; width: parent.width * 0.88; height: parent.height * 0.62; radius: parent.width * 0.06; color: parent.back }
        Rectangle {
            id: front
            x: parent.width * 0.06; y: parent.height * 0.32; width: parent.width * 0.88; height: parent.height * 0.52
            radius: parent.width * 0.06
            color: parent.body
            Rectangle { x: parent.radius; width: parent.width - 2 * parent.radius; height: Math.max(1, root.s * 0.015); color: Qt.lighter(parent.parent.body, 1.15) }
            Text {   // the emblem: a deep shade of the folder's own colour, so it stands out in any theme (even a grey one)
                visible: root.emblem !== "" && root.s >= 14
                anchors.centerIn: parent; anchors.verticalCenterOffset: root.s * 0.02
                text: root.emblem ? Theme.g(root.emblem) : ""
                color: Qt.darker(parent.parent.body, 2.1)
                font.family: Theme.font; font.pixelSize: root.s * (root.s < 28 ? 0.42 : 0.3)
            }
        }
    }

    // ----- document page -----
    Item {
        id: doc
        visible: root.kind !== "folder" && !root.showThumb
        width: root.s * 0.74; height: root.s * 0.92
        anchors.centerIn: parent
        readonly property real f: width * 0.28
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: Theme.page
                strokeColor: Qt.alpha(Theme.shadow, 0.25); strokeWidth: 1
                startX: 0.5; startY: 0.5
                PathLine { x: doc.width - doc.f; y: 0.5 }
                PathLine { x: doc.width - 0.5; y: doc.f }
                PathLine { x: doc.width - 0.5; y: doc.height - 0.5 }
                PathLine { x: 0.5; y: doc.height - 0.5 }
                PathLine { x: 0.5; y: 0.5 }
            }
            ShapePath {   // the folded corner
                fillColor: Qt.darker(Theme.page, 1.18)
                strokeColor: Qt.alpha(Theme.shadow, 0.25); strokeWidth: 1
                startX: doc.width - doc.f; startY: 0.5
                PathLine { x: doc.width - doc.f; y: doc.f }
                PathLine { x: doc.width - 0.5; y: doc.f }
                PathLine { x: doc.width - doc.f; y: 0.5 }
            }
        }
        Instantiator {   // a big font icon: "Aa" in that font (made only for fonts: an empty FontLoader complains)
            id: faceMaker
            active: root.big && root.kind === "font" && Fs.kind(root.path, false) === "font" && !Fs.onNetwork(root.path)   // kind can lag a path change
            delegate: FontLoader { source: Fs.url(root.path) }
        }
        Text {
            visible: root.s >= 22
            anchors.centerIn: parent; anchors.verticalCenterOffset: root.big ? -root.s * 0.06 : root.s * 0.04
            readonly property var face: faceMaker.object
            readonly property bool sample: !!face && face.status === FontLoader.Ready
            text: sample ? "Aa" : Theme.g(root.kind)
            color: Theme.light ? Theme.muted : Theme.raised
            font.family: sample ? face.font.family : Theme.font; font.styleName: sample ? face.font.styleName : ""
            font.pixelSize: root.s * (root.big ? 0.3 : 0.4)
        }
        Text {
            visible: root.big && root.suffix !== ""
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: root.s * 0.1 }
            width: parent.width - 6; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
            text: root.suffix.toUpperCase()
            color: Theme.light ? Theme.muted : Theme.raised
            font.family: Theme.font; font.pixelSize: Math.max(8, root.s * 0.13); font.bold: true
        }
    }
}
