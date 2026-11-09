// Theme.qml -- colours + fonts. They come from the Udiksa shell's ~/.config/quickshell/colors.json and fonts.json
// (Fs watches them: a theme change re-colours Kaze live). The values here are only the fallback (Graphite,
// Udiksa's neutral theme) for when those files do not exist. Shapes and spacing follow macOS Finder.
pragma Singleton
import QtQuick

QtObject {
    readonly property var c: Fs.colors
    function pick(k, f) { return c[k] ? c[k] : f }
    readonly property color bg:      pick("bg",      "#1b1c1f")
    readonly property color surface: pick("surface", "#25262a")
    readonly property color raised:  pick("raised",  "#3b3c41")
    readonly property color hover:   pick("hover",   "#484a4f")
    readonly property color text:    pick("text",    "#d4d5d9")
    readonly property color muted:   pick("muted",   "#96989f")
    readonly property color dim:     pick("dim",     "#5a5c62")
    readonly property color coral:   pick("accent",  "#b9bcc4")   // main accent
    readonly property color amber:   pick("accent2", "#d0d2d7")   // lighter accent: attention
    readonly property color warn:    pick("warn",    "#d0d2d7")
    readonly property color shadow:  pick("shadow",  "#000000")
    readonly property bool light: c.mode === "light"

    // Finder-style tints, all derived from the theme
    readonly property color hairline: Qt.alpha(text, 0.09)
    readonly property color stripe:   Qt.alpha(text, 0.035)
    readonly property color fill:     Qt.alpha(text, 0.08)     // hover / pressed / unfocused selection
    readonly property color fill2:    Qt.alpha(text, 0.14)
    readonly property color onAccent: bg                       // text on an accent fill
    readonly property color page:     light ? surface : text   // the paper of document icons

    readonly property string font: Fs.fonts.ui ? Fs.fonts.ui : "Iosevka Nerd Font"
    readonly property string mono: Fs.fonts.mono ? Fs.fonts.mono : "Iosevka Nerd Font"
    readonly property int fontSize: 13

    // Nerd Font (Material Design) glyphs, by name
    readonly property var glyphs: ({
        folder: 0xF024B, file: 0xF0214, image: 0xF021F, video: 0xF022B, audio: 0xF0223, pdf: 0xF0226,
        text: 0xF0219, code: 0xF022E, doc: 0xF022C, sheet: 0xF021B, slides: 0xF0227, archive: 0xF003C, font: 0xF06D6,
        home: 0xF02DC, desktop: 0xF01C4, documents: 0xF0219, downloads: 0xF01DA, music: 0xF0387, pictures: 0xF024F,
        videos: 0xF0567, drive: 0xF02CA, usb: 0xF0553, network: 0xF06F3, trash: 0xF0A79, bookmark: 0xF00C0,
        back: 0xF0141, forward: 0xF0142, list: 0xF0279, grid: 0xF056E, columns: 0xF056D, more: 0xF01D8,
        split: 0xEB56, eye: 0xF0208, eyeOff: 0xF0209, eject: 0xF01EA, close: 0xF0156, chevron: 0xF0142,
        // emblems you can put on a folder (Properties > Look)
        star: 0xF04CE, heart: 0xF02D1, code: 0xF0169, book: 0xF05DA, work: 0xF00D6, game: 0xF0297, cloud: 0xF015F,
        lock: 0xF033E, school: 0xF0474, camera: 0xF0100, flash: 0xF0241, git: 0xF02A2, palette: 0xF03D8, money: 0xF0114,
        person: 0xF0004, info: 0xF02FD, search: 0xF0349, check: 0xF012C, plus: 0xF0415, pause: 0xF03E4, play: 0xF040A, alert: 0xF0026
    })
    readonly property var emblemNames: ["star", "heart", "work", "code", "git", "book", "school", "money", "person", "camera",
                                        "music", "pictures", "videos", "game", "palette", "cloud", "lock", "flash", "documents", "downloads"]
    // folder colours you can choose: theme colours only, so they follow the theme
    readonly property var tints: ["accent", "accent2", "muted", "text"]
    function tint(name) { return name === "accent2" ? amber : name === "muted" ? muted : name === "text" ? text : coral }
    function g(name) { return String.fromCodePoint(glyphs[name] || glyphs.file) }

    // "Today at 15:19", "Yesterday at 09:02", "3 Oct 2026 at 19:24"
    function when(d) {
        const t = new Date(d), now = new Date()
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
        const hm = Qt.formatTime(t, "HH:mm")
        if (t.getTime() >= today) return "Today at " + hm
        if (t.getTime() >= today - 86400000) return "Yesterday at " + hm
        return Qt.formatDate(t, "d MMM yyyy") + " at " + hm
    }
}
