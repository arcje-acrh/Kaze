// Preview.qml -- what a file looks like. Big (Quick Look): PDFs and Office files as ALL their pages, scrollable
// (Office -> PDF via Fs.toPdf / OnlyOffice's converter; pages rendered on demand by Fs.page). Small (column view):
// the first page / a video frame (Fs.preview). Images as they are, text and code in the mono font, else the big icon.
import QtQuick

Item {
    id: root
    property string path
    property bool big: false
    property var look: ({})                 // a folder's colour + emblem
    readonly property bool dir: path !== "" && Fs.isDir(path)
    readonly property string kind: path ? Fs.kind(path, dir) : ""
    readonly property bool office: kind === "doc" || kind === "sheet" || kind === "slides"
    readonly property bool paged: big && (kind === "pdf" || office)
    readonly property bool thumbed: kind === "raw" || kind === "book" || (kind === "model" && Fs.modelPreview)   // a picture of it

    property string thumb: ""
    property bool failed: false             // no preview could be made: the icon, without "Making a preview…"
    property string pdf: ""
    property int pages: 0
    // what to load is decided after the change has settled: inside onPathChanged `kind` may still be the previous
    // item's (a folder), and a file then never asked for its text / picture
    onPathChanged: { thumb = ""; pdf = ""; pages = 0; body = ""; html = ""; failed = false; playing = false; Qt.callLater(load) }
    property bool playing: false            // a video: the play key was pressed (VideoPlay.qml replaces the frame)
    Component.onCompleted: load()
    function load() {
        if (!path || body || thumb || pdf) return
        // text, code, and files the name says nothing about (.bashrc, LICENSE, nginx.conf): readText gives "" for binaries
        if (kind === "text" || kind === "code" || kind === "file") Fs.askText(path)
        if (kind === "code") Fs.askCode(path)   // the plain text first, the coloured copy replaces it a moment later
        if (paged) setPdf(Fs.toPdf(path, kind))
        else if (kind === "pdf" || kind === "video" || office || thumbed) thumb = Fs.preview(path, kind)
    }
    function setPdf(p) { pdf = p; pages = 0; if (p) Fs.askPages(p) }
    Connections {
        target: Fs
        function onPreviewReady(p, img) { if (p === root.path) root.thumb = img }
        function onPreviewFailed(p) { if (p === root.path) root.failed = true }
        function onPdfReady(p, out) { if (p === root.path && root.paged) root.setPdf(out) }
        function onPagesReady(p, n) { if (p === root.pdf) root.pages = n }
        function onTextReady(p, t) { if (p === root.path) root.body = t }
        function onCodeReady(p, h) { if (p === root.path) root.html = h }
    }

    property string body: ""
    property string html: ""                // code coloured by source-highlight (theme colours)
    readonly property bool markdown: /\.(md|markdown)$/i.test(path)   // rendered (headings, lists, code), not shown as source
    // Qt 6.12 crashes drawing some Markdown tables (the render thread, in QSGInternalTextNode::addGlyphs; Kaze's own
    // README did it): tables are shown as they are written, in a code block (mono, so the columns still line up).
    // ponytail: only "| a | b |" tables; one without the leading pipe would still go to Qt's table layout.
    function tablesAsText(t) {
        const out = []
        let table = false, fence = false
        for (const l of t.split("\n")) {
            if (/^\s*(```|~~~)/.test(l)) fence = !fence
            const row = !fence && /^\s*\|/.test(l)
            if (row !== table) { out.push("```"); table = row }
            out.push(l)
        }
        if (table) out.push("```")
        return out.join("\n")
    }

    // ----- every page of a document -----
    ListView {
        id: doc
        anchors.fill: parent
        visible: root.pages > 0
        clip: true
        spacing: 14
        model: root.pages
        cacheBuffer: 1200
        boundsBehavior: Flickable.StopAtBounds
        readonly property int pageWidth: Math.min(width, 900)
        delegate: Item {
            id: pg
            required property int index
            width: doc.width
            height: im.status === Image.Ready ? doc.pageWidth * im.implicitHeight / im.implicitWidth : doc.pageWidth * 1.3
            property string src: Fs.page(root.pdf, index + 1, Math.round(doc.pageWidth * 1.5))
            Connections {
                target: pg.src ? null : Fs
                function onPageReady(p, n, img) { if (p === root.pdf && n === pg.index + 1) pg.src = img }
            }
            Rectangle {   // the paper while it renders
                anchors.horizontalCenter: parent.horizontalCenter
                width: doc.pageWidth; height: parent.height
                color: im.status === Image.Ready ? "transparent" : Theme.fill
                border.width: 1; border.color: Theme.hairline
                Image {
                    id: im
                    anchors.fill: parent; anchors.margins: 1
                    source: pg.src ? Fs.url(pg.src) : ""
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                }
            }
        }
        Rectangle {   // page counter
            anchors { right: parent.right; bottom: parent.bottom; margins: 10 }
            visible: root.pages > 1
            width: pc.implicitWidth + 16; height: 22; radius: 11
            color: Qt.alpha(Theme.surface, 0.9); border.width: 1; border.color: Theme.hairline
            Text {
                id: pc; anchors.centerIn: parent
                text: "Page " + (Math.max(0, doc.indexAt(10, doc.contentY + doc.height / 2)) + 1) + " of " + root.pages
                color: Theme.muted; font.family: Theme.font; font.pixelSize: 11
            }
        }
    }

    // ----- one picture: image, first page, video frame -----
    Image {
        id: img
        anchors.centerIn: parent
        width: Math.min(parent.width, implicitWidth); height: Math.min(parent.height, implicitHeight)
        visible: !doc.visible && status === Image.Ready && !root.playing
        source: root.kind === "image" ? Fs.imageUrl(root.path) : root.thumb ? Fs.imageUrl(root.thumb) : ""
        sourceSize: Qt.size(2048, 2048)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
    }

    // ----- a video: a play key on its frame; pressed, the player takes the frame's place -----
    Rectangle {
        objectName: "videoPlay"
        visible: root.kind === "video" && !root.playing && root.path !== "" && !Fs.inArchive(root.path)
        anchors.centerIn: img.visible ? img : parent
        width: 44; height: 44; radius: 4
        color: pm.containsMouse ? Theme.hover : Qt.alpha(Theme.raised, 0.92)
        border.width: 1; border.color: Theme.hairline
        Text { anchors.centerIn: parent; anchors.horizontalCenterOffset: 2; text: Theme.g("play"); color: Theme.coral; font.family: Theme.font; font.pixelSize: 24 }
        MouseArea { id: pm; anchors.fill: parent; hoverEnabled: true; onClicked: root.playing = true }
    }
    Loader {
        anchors.fill: parent
        active: root.playing
        sourceComponent: VideoPlay { path: root.path }
    }

    Rectangle {
        anchors.fill: parent
        visible: root.body !== ""
        color: Theme.bg; radius: 6
        border.width: 1; border.color: Theme.hairline
        Flickable {
            anchors { fill: parent; margins: 14 }
            clip: true
            contentWidth: width; contentHeight: code.height
            boundsBehavior: Flickable.StopAtBounds
            interactive: root.big
            Text {
                id: code
                width: parent.width
                text: root.html ? root.html : root.markdown ? root.tablesAsText(root.big ? root.body : root.body.slice(0, 4000)) : root.big ? root.body : root.body.slice(0, 4000)
                textFormat: root.html ? Text.RichText : root.markdown ? Text.MarkdownText : Text.PlainText
                wrapMode: root.markdown ? Text.Wrap : Text.WrapAnywhere
                color: Theme.text
                font.family: root.markdown ? Theme.font : Theme.mono; font.pixelSize: root.big ? 13 : root.markdown ? 11 : 10
            }
        }
    }

    // ----- a font: its name and samples, drawn with it -----
    Instantiator { id: faceMaker; active: root.kind === "font" && Fs.kind(root.path, false) === "font" && !Fs.onNetwork(root.path); delegate: FontLoader { source: Fs.url(root.path) } }
    readonly property bool faceReady: !!faceMaker.object && faceMaker.object.status === FontLoader.Ready
    readonly property font face: faceReady ? faceMaker.object.font : Qt.font({ family: Theme.font })
    Rectangle {
        anchors.fill: parent
        visible: root.kind === "font" && root.faceReady
        color: Theme.bg; radius: 6
        border.width: 1; border.color: Theme.hairline
        clip: true
        Column {
            anchors { fill: parent; margins: root.big ? 28 : 14 }
            spacing: root.big ? 14 : 8
            Text { width: parent.width; text: root.face.family + (root.face.styleName ? " " + root.face.styleName : ""); elide: Text.ElideRight; color: Theme.muted; font.family: Theme.font; font.pixelSize: root.big ? 13 : 11 }
            Text { width: parent.width; text: "Aa"; color: Theme.text; font.family: root.face.family; font.styleName: root.face.styleName; font.pixelSize: root.big ? 120 : Math.min(64, parent.height * 0.3) }
            Text { width: parent.width; text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 !?&@#%(){}"; wrapMode: Text.WrapAnywhere; color: Theme.text; font.family: root.face.family; font.styleName: root.face.styleName; font.pixelSize: root.big ? 26 : 13 }
            Repeater {
                model: root.big ? [14, 20, 32, 48] : [12, 18]
                delegate: Text {
                    required property int modelData
                    width: parent.width; elide: Text.ElideRight
                    text: "The quick brown fox jumps over the lazy dog"
                    color: Theme.text; font.family: root.face.family; font.styleName: root.face.styleName; font.pixelSize: modelData
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        visible: !doc.visible && !img.visible && !root.playing && root.body === "" && root.path !== "" && !(root.kind === "font" && root.faceReady)
        spacing: 14
        FileIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(root.width, root.height - 60, root.big ? 256 : 128); height: width
            path: parent.visible ? root.path : ""
            kind: root.kind
            emblem: root.look.emblem || ""; tint: root.look.color || ""
            suffix: root.dir ? "" : root.path.split("/").pop().split(".").slice(1).pop() || ""
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.big && !root.failed && (root.office || root.kind === "pdf" || root.kind === "video" || root.thumbed)
            text: root.office && !Fs.officePreview ? "Open OnlyOffice once to turn on previews of Office files" : "Making a preview…"
            color: Theme.muted; font.family: Theme.font; font.pixelSize: 12
        }
    }
}
