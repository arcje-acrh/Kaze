// fs.h -- everything Kaze asks the system for, as one QML singleton `Fs`: the Udiksa theme files,
// places / drives, file kinds and info, file operations (a queue of cp / mv, never overwriting),
// the trash, the clipboard (Nautilus-compatible) and pdf / video preview images.
#pragma once
#include <QClipboard>
#include <QBuffer>
#include <QQuickImageProvider>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <dirent.h>
#include <thread>
#include <deque>
#include <condition_variable>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QMimeData>
#include <QMimeDatabase>
#include <QPointer>
#include <QProcess>
#include <QRegularExpression>
#include <QQmlEngine>
#include <QSet>
#include <QSettings>
#include <QSocketNotifier>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QThread>
#include <QThreadPool>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>
#include <QImageReader>
#include <QSaveFile>
#include <QDrag>
#include <QPainter>
#include <QPainterPath>
#include <fcntl.h>
#include <sys/stat.h>
#include <signal.h>
#include <atomic>
#include <filesystem>
#include <memory>
#include "folder.h"

// Pictures on network shares, read on Qt's image thread: a file:// Image makes Qt look for "name@2x.jpg" next to
// the file on the UI thread first, which waits seconds on a share busy with a copy. image://kaze/<path> skips that.
class NetImages : public QQuickImageProvider {
public:
    NetImages() : QQuickImageProvider(QQuickImageProvider::Image, QQmlImageProviderBase::ForceAsynchronousImageLoading) {}
    QImage requestImage(const QString &id, QSize *size, const QSize &want) override {
        QImageReader r(QUrl::fromPercentEncoding(id.toUtf8()));
        r.setAutoTransform(true);
        const QSize sz = r.size();
        if (want.isValid() && sz.isValid() && (sz.width() > want.width() || sz.height() > want.height()))
            r.setScaledSize(sz.scaled(want.width() > 0 ? want.width() : sz.width(), want.height() > 0 ? want.height() : sz.height(), Qt::KeepAspectRatio));
        const QImage img = r.read();
        if (size) *size = img.size();
        return img;
    }
};

class Fs : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantMap colors MEMBER m_colors NOTIFY themeChanged)
    Q_PROPERTY(QVariantMap fonts MEMBER m_fonts NOTIFY themeChanged)
    Q_PROPERTY(QString home READ home CONSTANT)
    // see-through sidebar only where the compositor blurs behind it; elsewhere it would show the bare wallpaper
    // ponytail: Hyprland only (KDE blur, niri, SwayFX get the solid sidebar); KAZE_SEE_THROUGH=1/0 overrides
    Q_PROPERTY(bool seeThrough READ seeThrough CONSTANT)
    Q_PROPERTY(QString trashDir READ trashDir CONSTANT)
    Q_PROPERTY(QString startDir MEMBER startDir CONSTANT)
    Q_PROPERTY(QString startSelect MEMBER startSelect CONSTANT)
    Q_PROPERTY(QString startProps MEMBER startProps CONSTANT)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QVariantList jobs READ jobs NOTIFY jobsChanged)   // copy / move / zip / extract: running first, then waiting
    Q_PROPERTY(bool officePreview READ officePreview CONSTANT)
    Q_PROPERTY(bool modelPreview READ modelPreview CONSTANT)                 // 3D pictures need f3d
    Q_PROPERTY(QString undoText READ undoText NOTIFY undoChanged)           // what Ctrl+Z would undo ("" = nothing)
    Q_PROPERTY(QStringList offline MEMBER m_offline NOTIFY offlineChanged)
    Q_PROPERTY(QVariantMap looks MEMBER m_looks NOTIFY looksChanged)          // folder path -> { color, emblem } chosen by the user   // network shares whose server is not answering

    struct Act;
    struct Item;
    struct Step;
    struct Job;   // copy / move / zip / extract jobs (defined with the queue below)
public:
    static inline QString startDir, startSelect, startProps;   // set by main() from the command line (startProps: --properties)

    Fs() {
        // theme: the shell's colour + font files; watch the folder too (editors and the themer replace files)
        m_themeDir = QDir::homePath() + "/.config/quickshell";
        loadTheme();
        connect(&m_watch, &QFileSystemWatcher::fileChanged, this, &Fs::loadTheme);
        connect(&m_watch, &QFileSystemWatcher::directoryChanged, this, [this](const QString &d) {
            if (d == m_themeDir) loadTheme(); else emit drivesChanged();   // /dev/disk/by-uuid = a disk came or went
        });
        m_watch.addPath("/dev/disk/by-uuid");
        // mounts: /proc/self/mounts signals a change as an "exceptional condition"
        int fd = ::open("/proc/self/mounts", O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            auto *n = new QSocketNotifier(fd, QSocketNotifier::Exception, this);
            connect(n, &QSocketNotifier::activated, this, [this] { emit drivesChanged(); });
        }
        probe();
        connect(&m_probeTimer, &QTimer::timeout, this, &Fs::probe);
        m_probeTimer.start(30000);
        loadLooks();
        m_imgPool.setMaxThreadCount(std::max(2, QThread::idealThreadCount() / 2));
        // a share busy with a copy holds a worker for seconds per call: room for those + local folders meanwhile
        QThreadPool::globalInstance()->setMaxThreadCount(std::max(32, QThread::idealThreadCount() * 2));
        QThreadPool::globalInstance()->start([] {
            prune();
            for (const QFileInfo &f : QDir(archiveRoot()).entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot))   // opened archives: a day
                if (f.lastModified() < QDateTime::currentDateTime().addDays(-1)) QDir(f.filePath()).removeRecursively();
        });
        connect(&m_proc, &QProcess::finished, this, [this](int code, QProcess::ExitStatus st) {
            stepEnded(code == 0 && st == QProcess::NormalExit, QString::fromUtf8(m_proc.readAllStandardError()).trimmed());
        });
        connect(&m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError e) {
            if (e == QProcess::FailedToStart) stepEnded(false, m_proc.program() + ": " + m_proc.errorString());
        });
        m_tick.setInterval(700);
        connect(&m_tick, &QTimer::timeout, this, &Fs::measure);
    }

    QString home() const { return QDir::homePath(); }
    QString trashDir() const { return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/Trash/files"; }
    bool busy() const { return m_run.id || !m_jobs.isEmpty() || !m_plans.isEmpty() || !m_ask.isEmpty(); }
    // bytes under p (a file: its size), staying on p's own drive like du -x; `stop` ends the walk early
    // bytes (and files / folders) in p, this drive only. On a share each folder is a round trip to the server
    // (a NAS: 4421 items 35 s one at a time), so there 16 folders are read at once (5.5 s there);
    // locally one is enough. `tick` (optional) gets the counts so far about twice a second, on the calling thread.
    static qint64 bytesIn(const QString &p, const std::atomic_bool *stop = nullptr, qint64 *files = nullptr, qint64 *dirs = nullptr,
                          const std::function<void(qint64, qint64, qint64)> &tick = {}) {
        struct stat top{};
        if (::lstat(QFile::encodeName(p).constData(), &top)) return 0;
        if (!S_ISDIR(top.st_mode)) { if (files) ++*files; return top.st_size; }
        std::atomic<qint64> bytes = 0, nf = 0, nd = 0;
        std::mutex m;
        std::condition_variable cv;
        std::deque<std::string> todo{QFile::encodeName(p).toStdString()};
        int busy = 0;
        auto worker = [&] {
            std::unique_lock lock(m);
            for (;;) {
                cv.wait(lock, [&] { return !todo.empty() || busy == 0 || (stop && *stop); });
                if (todo.empty() || (stop && *stop)) { cv.notify_all(); return; }
                const std::string d = std::move(todo.front()); todo.pop_front();
                ++busy;
                lock.unlock();
                std::vector<std::string> sub;
                if (DIR *dp = ::opendir(d.c_str())) {
                    while (const dirent *de = ::readdir(dp)) {
                        if (stop && *stop) break;
                        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
                        const std::string f = d + "/" + de->d_name;
                        struct stat st{};
                        if (::lstat(f.c_str(), &st)) continue;
                        if (S_ISDIR(st.st_mode)) { ++nd; if (st.st_dev == top.st_dev) sub.push_back(f); }
                        else { ++nf; bytes += st.st_size; }
                    }
                    ::closedir(dp);
                }
                lock.lock();
                for (auto &s : sub) todo.push_back(std::move(s));
                --busy;
                cv.notify_all();
            }
        };
        const int n = Folder::onNetwork(p) ? 16 : 1;
        std::vector<std::thread> pool;
        for (int i = 0; i < n; ++i) pool.emplace_back(worker);
        {
            std::unique_lock lock(m);
            while (!cv.wait_for(lock, std::chrono::milliseconds(500), [&] { return (todo.empty() && busy == 0) || (stop && *stop); }))
                if (tick) { lock.unlock(); tick(bytes, nf, nd); lock.lock(); }
            cv.notify_all();
        }
        for (auto &t : pool) t.join();
        if (files) *files += nf;
        if (dirs) *dirs += nd;
        return bytes;
    }

    // ---------- names, kinds, info ----------
    Q_INVOKABLE QUrl url(const QString &p) const { return QUrl::fromLocalFile(p); }
    // for Image sources: a file on a share goes through NetImages (no wait on the UI thread)
    Q_INVOKABLE QUrl imageUrl(const QString &p) const {
        return p.isEmpty() ? QUrl() : Folder::onNetwork(p) ? QUrl("image://kaze/" + QString::fromLatin1(QUrl::toPercentEncoding(p))) : QUrl::fromLocalFile(p);
    }
    Q_INVOKABLE QString path(const QUrl &u) const { return u.toLocalFile(); }
    Q_INVOKABLE QString parent(const QString &p) const { return p == "/" ? p : QFileInfo(p).absolutePath(); }
    // what is known about p, without ever waiting on a network share (there: what the last folder read saw; its
    // mount point is a folder; else unknown)
    static std::optional<Folder::Known> look(const QString &p) {
        if (Folder::onNetwork(p)) {
            if (auto k = Folder::known(p)) return k;
            if (Folder::mountOf(p) == p || Folder::netMounts().contains(p)) return Folder::Known{true, 0, {}};
            return std::nullopt;
        }
        const QFileInfo f(p);
        if (!f.exists()) return std::nullopt;
        return Folder::Known{f.isDir(), f.size(), f.lastModified()};
    }
    Q_INVOKABLE bool isDir(const QString &p) const { const auto k = look(p); return k && k->dir; }
    Q_INVOKABLE bool exists(const QString &p) const { return look(p).has_value(); }
    Q_INVOKABLE bool onNetwork(const QString &p) const { return Folder::onNetwork(p); }
    Q_INVOKABLE static QString size(qint64 b) { return b < 1000 ? QString::number(b) + " B" : QLocale().formattedDataSize(b, 1, QLocale::DataSizeSIFormat); }
    static QString free(const QString &dir) {
        QStorageInfo s(dir);
        return s.isValid() ? size(s.bytesAvailable()) + " free" : QString();
    }

    // icon / preview category: folder image video audio pdf text code doc sheet slides archive font file
    Q_INVOKABLE static QString kind(const QString &p, bool dir = false) {
        if (dir) return "folder";
        const QMimeType m = QMimeDatabase().mimeTypeForFile(p, QMimeDatabase::MatchExtension);
        const QString n = m.name();
        static const QStringList raw = {"cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "kdc", "mrw"};
        if (raw.contains(QFileInfo(p).suffix().toLower())) return "raw";
        if (n == "application/epub+zip") return "book";
        if (n.startsWith("model/")) return "model";
        if (n.startsWith("image/")) return "image";
        if (n.startsWith("video/")) return "video";
        if (n.startsWith("audio/")) return "audio";
        if (n == "application/pdf") return "pdf";
        if (n.startsWith("font/") || n.contains("font-")) return "font";
        if (n.contains("wordprocessing") || n.contains("msword") || n.contains("opendocument.text") || n == "application/rtf") return "doc";
        if (n.contains("spreadsheet") || n.contains("ms-excel") || n == "text/csv") return "sheet";
        if (n.contains("presentation") || n.contains("ms-powerpoint")) return "slides";
        static const QStringList arc = {"zip", "tar", "rar", "7z", "compress", "archive", "xz", "bzip", "zstd", "gzip", "lz", "cpio", "iso9660", "debian", "rpm"};
        for (const auto &a : arc) if (n.contains(a)) return "archive";
        if (n == "text/plain" || n == "text/markdown") return "text";
        if (m.inherits("text/plain") || n == "application/json" || n.contains("shellscript")) return "code";
        return "file";
    }

    // Finder's "Kind" column: "Folder", "PDF document", "PNG image", ...
    Q_INVOKABLE QString describe(const QString &p, bool dir = false) const {
        return dir ? QStringLiteral("Folder") : m_mime.mimeTypeForFile(p, QMimeDatabase::MatchExtension).comment();
    }

    // ---------- slow questions, answered on a worker thread ----------
    // Anything that may read a disk -- listing a folder, statvfs, reading a file -- can block for a long time on a
    // network share whose server is down (an automount waits ~6 s per try). The UI only ever asks through these,
    // so the window never freezes; answers come back as signals with the path they belong to.
    // ponytail: on quit Qt waits for a probe still stuck on a dead share (up to the mount timeout).
    Q_INVOKABLE void askInfo(const QString &p) { bg(p, [p] { const QVariantMap m = info(p); return [p, m](Fs *fs) { emit fs->infoReady(p, m); }; }); }
    Q_INVOKABLE void askFree(const QString &dir) { bg("free:" + dir, [dir] { const QString f = free(dir); return [dir, f](Fs *fs) { emit fs->freeReady(dir, f); }; }); }
    // code in colour: GNU source-highlight (ships with gdb; optional: without it the text stays plain) -> HTML with
    // <font color> runs, coloured from the theme (style file written on every theme change). Files over 128 KB stay plain.
    Q_INVOKABLE void askCode(const QString &p) {
        if (p.isEmpty() || QFileInfo(p).size() > 128 * 1024 || QStandardPaths::findExecutable("source-highlight").isEmpty()) return;
        if (!QFileInfo::exists(m_codeStyle)) writeCodeStyle();   // Clear Preview Cache empties ~/.cache/kaze
        const QString style = m_codeStyle;
        bg("code:" + p, [p, style] {
            QProcess pr;
            pr.start("source-highlight", {"-f", "html", "--failsafe", "--style-file=" + style, "-i", p, "-o", "STDOUT"});
            QString html;
            if (pr.waitForFinished(3000) && pr.exitCode() == 0) {
                html = QString::fromUtf8(pr.readAllStandardOutput());
                const int at = html.indexOf("<pre>");
                html = at < 0 ? QString() : html.mid(at).remove("<tt>").remove("</tt>").replace("<pre>", "<div style=\"white-space:pre-wrap\">").replace("</pre>", "</div>");   // <pre>/<tt> force a generic fixed font; the view sets the theme's mono one
                if (!html.contains("<font")) html.clear();   // a language it does not know: plain is the same, cheaper
            }
            return [p, html](Fs *fs) { emit fs->codeReady(p, html); };
        });
    }
    // facts from inside the file: picture size + camera (exiv2), video / audio length, size, codecs, tags (ffprobe),
    // PDF pages / page size / title (pdfinfo). A list of [label, value]; programs that are missing are skipped.
    Q_INVOKABLE void askMedia(const QString &p, const QString &kind) {
        if (p.isEmpty() || !(kind == "image" || kind == "video" || kind == "audio" || kind == "pdf")) return;
        bg("media:" + p, [p, kind] { const QVariantList rows = media(p, kind); return [p, rows](Fs *fs) { emit fs->mediaReady(p, rows); }; });
    }
    // git: each name in `dir` -> M (changed, or a folder with changes inside) | A (added) | U (untracked) | ! (conflict)
    Q_INVOKABLE void askGit(const QString &dir) {
        if (dir.isEmpty() || Folder::onNetwork(dir) || inArchive(dir)) return;
        bg("git:" + dir, [dir] {
            QVariantMap m;
            const QString prefix = run("git", {"-C", dir, "rev-parse", "--show-prefix"}).trimmed();
            const QString out = prefix.isEmpty() && run("git", {"-C", dir, "rev-parse", "--is-inside-work-tree"}).trimmed() != "true"
                                    ? QString() : run("git", {"-C", dir, "status", "--porcelain=v1", "-z", "--branch", "--", "."});
            QString branch;
            static const QString rank = "UAM!";
            const QStringList L = out.split(QChar(0), Qt::SkipEmptyParts);
            for (int i = 0; i < L.size(); ++i) {
                const QString e = L[i];
                if (e.startsWith("## ")) { branch = e.mid(3).section("...", 0, 0); continue; }
                if (e.size() < 4) continue;
                const QString xy = e.left(2), path = e.mid(3);   // relative to the repository's top
                if (xy[0] == 'R' || xy[0] == 'C') ++i;           // the old name follows
                if (!path.startsWith(prefix)) continue;
                const QString rest = path.mid(prefix.size()), name = rest.section('/', 0, 0);
                const bool inside = rest.indexOf('/') >= 0 && rest.indexOf('/') < rest.size() - 1;
                QString s = xy == "??" ? "U" : xy.contains('U') || xy == "AA" || xy == "DD" ? "!" : xy[0] == 'A' && !inside ? "A" : "M";
                if (inside && s != "!") s = "M";
                if (xy.contains('D') && !inside) continue;       // gone: nothing to mark
                if (!m.contains(name) || rank.indexOf(s) > rank.indexOf(m[name].toString())) m[name] = s;
            }
            return [dir, m, branch](Fs *fs) { emit fs->gitReady(dir, m, branch); };
        });
    }
    // disk usage: each item in `dir` with its bytes (folders: everything below, on its own drive), biggest first
    Q_INVOKABLE void askUsage(const QString &dir) {
        bg("usage:" + dir, [dir] {
            QVariantList rows;
            double total = 0;
            struct stat top{};
            ::stat(QFile::encodeName(dir).constData(), &top);
            for (const QFileInfo &f : QDir(dir).entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System)) {
                struct stat st{};
                const bool other = !::lstat(QFile::encodeName(f.filePath()).constData(), &st) && S_ISDIR(st.st_mode) && st.st_dev != top.st_dev;
                const qint64 b = other ? 0 : bytesIn(f.filePath());
                total += b;
                rows << QVariantMap{{"name", f.fileName()}, {"path", f.filePath()}, {"dir", f.isDir() && !f.isSymLink()}, {"bytes", double(b)},
                                    {"size", other ? QString("another drive") : size(b)}};
            }
            std::sort(rows.begin(), rows.end(), [](const QVariant &a, const QVariant &b) { return a.toMap()["bytes"].toDouble() > b.toMap()["bytes"].toDouble(); });
            return [dir, rows, total](Fs *fs) { emit fs->usageReady(dir, rows, total); };
        });
    }
    // permissions: `mode` = the 9 rwx bits; `deep` = a folder and everything in it (x only on folders and files that had it)
    Q_INVOKABLE void chmod(const QStringList &paths, int mode, bool deep) {
        if (paths.isEmpty()) return;
        Job j;
        j.verb = "Changing permissions of"; j.name = many(paths); j.where = parent(paths[0]); j.items = true;
        QString sym;
        for (int c = 0; c < 3; ++c) {
            const int b = mode >> (6 - 3 * c) & 7;
            sym += QString(c ? "," : "") + "ugo"[c] + "=" + (b & 4 ? "r" : "") + (b & 2 ? "w" : "") + (b & 1 ? "X" : "");
        }
        for (const QString &p : paths) {
            if (deep) { j.steps << Step{p, {}, "chmod", {"-R", sym, "--", p}}; j.noUndo = true; continue; }
            Step s{p};
            s.work = [p, mode](Act *u) -> QString {
                struct stat st{};
                const QByteArray f = QFile::encodeName(p);
                if (::stat(f.constData(), &st) || ::chmod(f.constData(), (st.st_mode & ~0777) | mode)) return "Could not change “" + QFileInfo(p).fileName() + "”: " + QString::fromUtf8(strerror(errno));
                *u = {"mode", p, QString::number(st.st_mode & 07777, 8)};
                return {};
            };
            j.steps << s;
        }
        add(j);
    }
    // owner: "user", "user:group" or ":group"; asks for the password (pkexec) only when your own rights are not enough
    Q_INVOKABLE void chown(const QStringList &paths, const QString &owner, bool deep) {
        if (paths.isEmpty() || owner.isEmpty() || owner.contains(QRegularExpression("[^A-Za-z0-9._:-]"))) { emit error("Not a valid owner"); return; }
        Job j;
        j.verb = "Changing owner of"; j.name = many(paths); j.where = parent(paths[0]); j.items = true; j.noUndo = true;
        QStringList a{"-c", "chown \"$@\" 2>/dev/null || pkexec chown \"$@\"", "sh"};
        if (deep) a << "-R";
        j.steps << Step{paths[0], {}, "sh", a + QStringList{owner, "--"} + paths};
        add(j);
    }
    static QString run(const QString &prog, const QStringList &args) {
        if (QStandardPaths::findExecutable(prog).isEmpty()) return {};
        QProcess pr;
        pr.start(prog, args);
        if (!pr.waitForFinished(5000)) { pr.kill(); pr.waitForFinished(500); return {}; }
        return QString::fromUtf8(pr.readAllStandardOutput());
    }
    static QString duration(double s) {
        const int t = int(s + 0.5), h = t / 3600, m = t / 60 % 60, sec = t % 60;
        return h ? QString("%1:%2:%3").arg(h).arg(m, 2, 10, QChar('0')).arg(sec, 2, 10, QChar('0')) : QString("%1:%2").arg(m).arg(sec, 2, 10, QChar('0'));
    }
    static QVariantList media(const QString &p, const QString &kind) {
        QVariantList r;
        auto add = [&](const QString &label, const QString &v) { if (!v.trimmed().isEmpty()) r << QVariant(QStringList{label, v.trimmed()}); };
        if (kind == "image") {
            QImageReader ir(p);
            const QSize sz = ir.size();
            if (sz.isValid()) add("Dimensions", QString("%1 × %2").arg(sz.width()).arg(sz.height()));
            QMap<QString, QString> e;
            for (const QString &line : run("exiv2", {"-q", "-Pkt", "-g", "Exif.Image.Make", "-g", "Exif.Image.Model", "-g", "Exif.Photo.DateTimeOriginal",
                                                    "-g", "Exif.Photo.FNumber", "-g", "Exif.Photo.ExposureTime", "-g", "Exif.Photo.ISOSpeedRatings",
                                                    "-g", "Exif.Photo.FocalLength", "-g", "Exif.Photo.LensModel", p}).split('\n')) {
                const int sp = line.indexOf(' ');
                if (sp > 0) e[line.left(sp)] = line.mid(sp).trimmed();
            }
            QString cam = e.value("Exif.Image.Model");
            const QString make = e.value("Exif.Image.Make");
            if (!make.isEmpty() && !cam.startsWith(make.section(' ', 0, 0), Qt::CaseInsensitive)) cam = make + " " + cam;
            add("Camera", cam);
            add("Lens", e.value("Exif.Photo.LensModel"));
            add("Exposure", QStringList{e.value("Exif.Photo.FNumber"), e.value("Exif.Photo.ExposureTime"),
                                        e.value("Exif.Photo.ISOSpeedRatings").isEmpty() ? QString() : "ISO " + e.value("Exif.Photo.ISOSpeedRatings"),
                                        e.value("Exif.Photo.FocalLength")}.filter(QRegularExpression("\\S")).join("  ·  "));
            const QDateTime taken = QDateTime::fromString(e.value("Exif.Photo.DateTimeOriginal"), "yyyy:MM:dd HH:mm:ss");
            if (taken.isValid()) add("Taken", QLocale().toString(taken, "d MMM yyyy, HH:mm"));
        } else if (kind == "video" || kind == "audio") {
            const QJsonObject o = QJsonDocument::fromJson(run("ffprobe", {"-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", p}).toUtf8()).object();
            const QJsonObject fmt = o["format"].toObject(), tags = fmt["tags"].toObject();
            const double secs = fmt["duration"].toString().toDouble();
            if (secs > 0) add("Duration", duration(secs));
            for (const QJsonValue &v : o["streams"].toArray()) {
                const QJsonObject s = v.toObject();
                if (s["codec_type"] == "video" && s["disposition"].toObject()["attached_pic"].toInt() == 0) {
                    const QStringList fr = s["avg_frame_rate"].toString().split('/');
                    const double fps = fr.size() == 2 && fr[1].toDouble() > 0 ? fr[0].toDouble() / fr[1].toDouble() : 0;
                    add("Video", QString("%1 × %2").arg(s["width"].toInt()).arg(s["height"].toInt()) + (fps > 0 ? QString(", %1 fps").arg(QString::number(fps, 'f', fps == int(fps) ? 0 : 2)) : "")
                                 + "  ·  " + s["codec_name"].toString().toUpper());
                } else if (s["codec_type"] == "audio") {
                    const int ch = s["channels"].toInt();
                    add("Audio", s["codec_name"].toString().toUpper() + QString(", %1 kHz").arg(s["sample_rate"].toString().toDouble() / 1000, 0, 'g', 3)
                                 + (ch == 1 ? ", mono" : ch == 2 ? ", stereo" : ch ? QString(", %1 channels").arg(ch) : ""));
                    break;
                }
            }
            const int kbps = fmt["bit_rate"].toString().toInt() / 1000;
            if (kbps > 0) add("Bit rate", QString("%1 kbit/s").arg(kbps));
            auto tag = [&](const char *k) { for (auto it = tags.begin(); it != tags.end(); ++it) if (it.key().compare(k, Qt::CaseInsensitive) == 0) return it.value().toString(); return QString(); };
            add("Title", tag("title")); add("Artist", tag("artist")); add("Album", tag("album")); add("Year", tag("date").left(4));
        } else if (kind == "pdf") {
            QMap<QString, QString> m;
            for (const QString &line : run("pdfinfo", {p}).split('\n')) { const int c = line.indexOf(':'); if (c > 0) m[line.left(c)] = line.mid(c + 1).trimmed(); }
            add("Pages", m.value("Pages"));
            const QString ps = m.value("Page size");
            static const QRegularExpression dims("([\\d.]+) x ([\\d.]+) pts(?: \\((\\w+)\\))?");
            const auto d = dims.match(ps);
            if (d.hasMatch()) add("Page size", (d.captured(3).isEmpty() ? QString() : d.captured(3) + ", ")
                                   + QString("%1 × %2 mm").arg(qRound(d.captured(1).toDouble() * 25.4 / 72)).arg(qRound(d.captured(2).toDouble() * 25.4 / 72)));
            add("Title", m.value("Title")); add("Author", m.value("Author")); add("Made with", m.value("Creator"));
        }
        return r;
    }
    Q_INVOKABLE void askText(const QString &p) {
        if (p.isEmpty()) return;
        bg("text:" + p, [p] { const QString t = readText(p); return [p, t](Fs *fs) { emit fs->textReady(p, t); }; }); }
    Q_INVOKABLE void askPages(const QString &pdf) {
        auto *pr = new QProcess(this);
        connect(pr, &QProcess::finished, this, [this, pr, pdf] {
            const auto m = QRegularExpression("^Pages:\\s+(\\d+)", QRegularExpression::MultilineOption).match(QString::fromUtf8(pr->readAllStandardOutput()));
            emit pagesReady(pdf, m.hasMatch() ? m.captured(1).toInt() : 0);
            pr->deleteLater();
        });
        pr->start("pdfinfo", {pdf});
    }

    static QVariantMap info(const QString &p) {
        const QFileInfo f(p);
        const QMimeType m = QMimeDatabase().mimeTypeForFile(p);
        QVariantMap r{{"name", f.fileName()}, {"path", p}, {"dir", f.isDir()},
                      {"type", f.isDir() ? QStringLiteral("Folder") : m.comment()}, {"mime", f.isDir() ? QString("inode/directory") : m.name()},
                      {"modified", QLocale().toString(f.lastModified(), "d MMM yyyy, HH:mm")},
                      {"created", f.birthTime().isValid() ? QLocale().toString(f.birthTime(), "d MMM yyyy, HH:mm") : QString()},
                      {"opened", QLocale().toString(f.lastRead(), "d MMM yyyy, HH:mm")},
                      {"where", QString(f.absolutePath()).replace(QRegularExpression("^" + QRegularExpression::escape(QDir::homePath())), "~")},
                      {"owner", f.owner()}, {"group", f.group()}, {"link", f.isSymLink() ? f.symLinkTarget() : QString()}};
        if (f.isDir()) r["size"] = QString::number(QDir(p).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden).size()) + " items";
        else r["size"] = size(f.size()) + (f.size() >= 1000 ? " (" + QLocale().toString(f.size()) + " bytes)" : QString());
        QString perm;
        const auto P = f.permissions();
        for (auto [rd, wr, ex] : {std::tuple{QFile::ReadOwner, QFile::WriteOwner, QFile::ExeOwner},
                                  {QFile::ReadGroup, QFile::WriteGroup, QFile::ExeGroup}, {QFile::ReadOther, QFile::WriteOther, QFile::ExeOther}})
            perm += QString(P & rd ? "r" : "-") + (P & wr ? "w" : "-") + (P & ex ? "x" : "-");
        r["perms"] = perm;
        int oct = 0;
        for (int i = 0; i < 9; ++i) if (perm[i] != '-') oct |= 1 << (8 - i);
        r["octal"] = QString::number(oct, 8);
        return r;
    }

    // first 256 KiB of a text file; empty string for binaries
    static QString readText(const QString &p) {
        QFile f(p);
        if (!f.open(QIODevice::ReadOnly)) return {};
        const QByteArray b = f.read(256 * 1024);
        return b.contains('\0') ? QString() : QString::fromUtf8(b);
    }

    // ---------- places, drives ----------
    Q_INVOKABLE QVariantList places() const {
        QVariantList r{QVariantMap{{"name", "Home"}, {"path", home()}, {"icon", "home"}}};
        const std::pair<QStandardPaths::StandardLocation, const char *> L[] = {
            {QStandardPaths::DesktopLocation, "desktop"}, {QStandardPaths::DocumentsLocation, "documents"},
            {QStandardPaths::DownloadLocation, "downloads"}, {QStandardPaths::MusicLocation, "music"},
            {QStandardPaths::PicturesLocation, "pictures"}, {QStandardPaths::MoviesLocation, "videos"}};
        for (auto [loc, icon] : L) {
            const QString p = QStandardPaths::writableLocation(loc);
            if (p != home() && QFileInfo(p).isDir()) r << QVariantMap{{"name", QFileInfo(p).fileName()}, {"path", p}, {"icon", icon}};
        }
        return r;
    }

    // GTK bookmarks: the same pins Nautilus and the GTK file dialogs show ("file:///path Optional name")
    Q_INVOKABLE QVariantList bookmarks() const {
        QVariantList r;
        QFile f(home() + "/.config/gtk-3.0/bookmarks");
        if (!f.open(QIODevice::ReadOnly)) return r;
        for (const QByteArray &line : f.readAll().split('\n')) {
            const int sp = line.indexOf(' ');
            const QUrl u(QString::fromUtf8(sp < 0 ? line : line.left(sp)));
            if (!u.isLocalFile()) continue;
            const QString p = u.toLocalFile();
            r << QVariantMap{{"name", sp < 0 ? QFileInfo(p).fileName() : QString::fromUtf8(line.mid(sp + 1))}, {"path", p}};
        }
        return r;
    }
    Q_INVOKABLE void bookmark(const QString &p) {
        for (const auto &b : bookmarks()) if (b.toMap()["path"] == p) return;
        QDir().mkpath(home() + "/.config/gtk-3.0");
        QFile f(home() + "/.config/gtk-3.0/bookmarks");
        if (f.open(QIODevice::Append)) { f.write(QUrl::fromLocalFile(p).toEncoded() + "\n"); emit drivesChanged(); }
    }
    Q_INVOKABLE void unbookmark(const QString &p) {
        QFile f(home() + "/.config/gtk-3.0/bookmarks");
        if (!f.open(QIODevice::ReadOnly)) return;
        QByteArrayList keep;
        for (const QByteArray &line : f.readAll().split('\n'))
            if (!line.isEmpty() && QUrl(QString::fromUtf8(line.split(' ').first())).toLocalFile() != p) keep << line;
        f.close();
        if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) { f.write(keep.join('\n') + "\n"); emit drivesChanged(); }
    }

    // block devices from lsblk: mounted ones in the usual places + unmounted ones udisks would offer (it skips
    // what udev marks UDISKS_IGNORE: EFI, recovery, Udiksa's hidden Windows partitions) + network mounts from
    // /proc/self/mounts. Never stat()s a mount: an offline network share would freeze the UI.
    Q_INVOKABLE QVariantList drives() const {
        QVariantList r;
        QProcess p;
        p.start("lsblk", {"-J", "-b", "-o", "PATH,LABEL,MOUNTPOINTS,HOTPLUG,FSTYPE,SIZE,PKNAME,MAJ:MIN"});
        p.waitForFinished(2000);
        std::function<void(const QJsonArray &)> walk = [&](const QJsonArray &a) {
            for (const auto &v : a) {
                const QJsonObject d = v.toObject();
                walk(d["children"].toArray());
                const QString fs = d["fstype"].toString();
                if (fs.isEmpty() || fs == "swap" || fs == "crypto_LUKS" || fs == "LVM2_member") continue;
                QString mp;   // the one mount point worth showing ("/" wins over btrfs sub-volume mounts)
                for (const auto &m : d["mountpoints"].toArray()) {
                    const QString x = m.toString();
                    if (x == "/" || ((x.startsWith("/run/media/") || x.startsWith("/media/") || x.startsWith("/mnt") || x.startsWith(home() + "/")) && mp != "/")) mp = x;
                }
                const bool mounted = !d["mountpoints"].toArray().isEmpty() && !d["mountpoints"].toArray().first().isNull();
                if (mounted ? mp.isEmpty() : udevIgnored(d["maj:min"].toString())) continue;
                const QString sz = size(d["size"].toVariant().toLongLong());
                QString name = mp == "/" ? QStringLiteral("System") : d["label"].toString();
                if (name.isEmpty()) name = sz + " drive";
                r << QVariantMap{{"name", name}, {"path", mp}, {"dev", d["path"].toString()}, {"disk", d["pkname"].toString()},
                                 {"removable", d["hotplug"].toBool()}, {"network", false}, {"note", sz}};
            }
        };
        walk(QJsonDocument::fromJson(p.readAllStandardOutput())["blockdevices"].toArray());
        QFile m("/proc/self/mounts");
        QSet<QString> seen;
        if (m.open(QIODevice::ReadOnly))
            for (const QByteArray &line : m.readAll().split('\n')) {
                const auto f = line.split(' ');
                if (f.size() < 3) continue;
                const QString type = f[2], mp = QString::fromUtf8(f[1]).replace("\\040", " ");
                static const QStringList net = {"cifs", "smb3", "nfs", "nfs4", "fuse.sshfs", "fuse.rclone"};
                if (!(net.contains(type) || (type == "autofs" && mp.startsWith(home() + "/"))) || seen.contains(mp)) continue;
                seen << mp;
                r << QVariantMap{{"name", QFileInfo(mp).fileName()}, {"path", mp}, {"dev", QString()}, {"disk", QString()},
                                 {"removable", false}, {"network", true}, {"note", type == "autofs" ? QStringLiteral("share") : type}};
            }
        return r;
    }
    Q_INVOKABLE void mount(const QString &dev) {
        auto *p = new QProcess(this);
        connect(p, &QProcess::finished, this, [this, p](int code) {
            const QString out = QString::fromUtf8(p->readAllStandardOutput());
            if (code) emit error(QString::fromUtf8(p->readAllStandardError()).trimmed());
            else if (const int at = out.indexOf(" at "); at > 0) emit mounted(out.mid(at + 4).trimmed());
            p->deleteLater();
        });
        p->start("udisksctl", {"mount", "-b", dev});
    }
    // unmount, then power the disk off so it is safe to pull out
    Q_INVOKABLE void eject(const QString &dev, const QString &disk) {
        auto *p = new QProcess(this);
        connect(p, &QProcess::finished, this, [this, p](int code) {
            if (code) emit error(QString::fromUtf8(p->readAllStandardError()).trimmed());
            else emit notice("Safe to remove");
            p->deleteLater();
        });
        p->start("sh", {"-c", "udisksctl unmount -b \"$1\" && { [ -z \"$2\" ] || udisksctl power-off -b \"/dev/$2\"; }", "sh", dev, disk});
    }

    // ---------- network locations (SMB shares in /etc/fstab, changed through tools/kaze-share + pkexec) ----------
    static QString shareRoot() { return qEnvironmentVariable("KAZE_SHARE_ROOT"); }   // tests: a fake / for the helper
    static QString unescape(QString s) { return s.replace("\\040", " ").replace("\\011", "\t").replace("\\134", "\\"); }
    // every cifs line of /etc/fstab: where it is mounted, what it is, how (sign-in itself is root-only: only whether one is saved)
    Q_INVOKABLE QVariantList shares() const {
        QVariantList r;
        QFile t(shareRoot() + "/etc/fstab");
        if (!t.open(QIODevice::ReadOnly)) return r;
        QSet<QString> mounted;
        QFile m("/proc/self/mounts");
        if (m.open(QIODevice::ReadOnly))
            for (const QByteArray &line : m.readAll().split('\n')) { const auto f = line.split(' '); if (f.size() > 2 && (f[2] == "cifs" || f[2] == "smb3")) mounted << unescape(QString::fromUtf8(f[1])); }
        for (const QByteArray &line : t.readAll().split('\n')) {
            const QStringList c = QString::fromUtf8(line).simplified().split(' ');
            if (c.size() < 4 || c[0].startsWith('#') || !(c[2] == "cifs" || c[2] == "smb3")) continue;
            const QString src = unescape(c[0]), path = unescape(c[1]);
            QVariantMap o;
            for (const QString &kv : c[3].split(',')) o[kv.section('=', 0, 0)] = kv.contains('=') ? kv.section('=', 1) : QString("1");
            r << QVariantMap{{"path", path}, {"name", QFileInfo(path).fileName()},
                             {"server", src.section('/', 2, 2)}, {"share", src.section('/', 3)},
                             {"signedIn", o.contains("credentials") || o.contains("username") || o.contains("user")},
                             {"guest", o.contains("guest") || o.value("sec") == "none"},
                             {"ro", o.contains("ro")}, {"vers", o.value("vers").toString()},
                             {"boot", !o.contains("x-systemd.automount")},
                             {"idle", o.contains("x-systemd.idle-timeout") ? o.value("x-systemd.idle-timeout").toInt() : 0},
                             {"mounted", mounted.contains(path)}, {"offline", m_offline.contains(path)},
                             {"needsFix", !o.contains("noserverino")},   // Unraid / FUSE servers: "stale file handle" without it
                             {"inHome", path.startsWith(QDir::homePath() + "/")}};
        }
        return r;
    }
    // add / change a share (m: old, server, share, path, user, password, domain, guest, keep, vers, ro, boot, idle,
    // check -- see tools/kaze-share). The password goes to the helper on stdin only. shareDone(ok, message) after.
    Q_INVOKABLE void saveShare(const QVariantMap &m) {
        QByteArray in;
        for (auto it = m.begin(); it != m.end(); ++it) {
            QString v = it.value().typeId() == QMetaType::Bool ? QString(it.value().toBool() ? "1" : "0") : it.value().toString();
            if (v.contains('\n')) { emit shareDone(false, "Line breaks are not allowed"); return; }
            in += it.key().toUtf8() + "=" + v.toUtf8() + "\n";
        }
        const QString old = m.value("old").toString(), path = m.value("path").toString();
        runShare("save", in, [this, old, path](bool ok) {
            if (ok && !old.isEmpty() && old != path) QDir().rmdir(old);   // moved: the old empty folder goes
        });
    }
    Q_INVOKABLE void removeShare(const QString &path) {
        runShare("remove", ("path=" + path + "\n").toUtf8(), [path](bool ok) { if (ok) QDir().rmdir(path); });   // only if empty
    }
    Q_INVOKABLE void notify(const QString &text) { QProcess::startDetached("notify-send", {"-a", "Kaze", "Kaze", text}); }
    // add noserverino to a share's fstab line and reconnect (kaze-share fix); asks for the password
    Q_INVOKABLE void fixShare(const QString &path) {
        runShare("fix", ("path=" + path + "\n").toUtf8(), [](bool) {});
    }
    // disconnect now (it connects again when opened): systemd asks for the password itself (polkit)
    Q_INVOKABLE void disconnectShare(const QString &path) {
        auto *p = new QProcess(this);
        connect(p, &QProcess::finished, this, [this, p](int code) {
            emit shareDone(code == 0, code == 0 ? QString("Disconnected") : QString::fromUtf8(p->readAllStandardError()).trimmed());
            emit drivesChanged();
            p->deleteLater();
        });
        p->start("sh", {"-c", "systemctl stop \"$(systemd-escape -p --suffix=mount \"$1\")\"", "sh", path});
    }
    // SMB servers announcing themselves on this network (avahi / Bonjour): [{name, host, address}] via serversFound
    Q_INVOKABLE void findServers() {
        bg("servers", [] {
            QVariantList r;
            QSet<QString> seen;
            for (const QString &line : run("avahi-browse", {"-rtpk", "_smb._tcp"}).split('\n')) {
                const QStringList f = line.split(';');   // =;iface;IPv4;name;_smb._tcp;local;host.local;address;port;txt
                if (f.size() < 9 || f[0] != "=" || f[2] != "IPv4" || seen.contains(f[3])) continue;
                seen << f[3];
                r << QVariantMap{{"name", QString(f[3]).replace("\\032", " ")}, {"host", f[6]}, {"address", f[7]}};
            }
            return [r](Fs *fs) { emit fs->serversFound(r); };
        });
    }
    // is anything answering SMB (port 445) on this host? knocked(host, up) within 1.5 s; never touches a mount
    Q_INVOKABLE void knock(const QString &host) {
        if (host.isEmpty()) return;
        auto *s = new QTcpSocket(this);
        auto done = [this, s, host](bool up) {
            if (s->property("done").toBool()) return;
            s->setProperty("done", true);
            s->deleteLater();
            emit knocked(host, up);
        };
        connect(s, &QTcpSocket::connected, this, [done] { done(true); });
        connect(s, &QTcpSocket::errorOccurred, this, [done] { done(false); });
        QTimer::singleShot(1500, s, [done] { done(false); });
        s->connectToHost(host, 445);
    }
    void runShare(const QString &cmd, const QByteArray &in, std::function<void(bool)> after) {
        const QString helper = qEnvironmentVariable("KAZE_SHARE_HELPER", QCoreApplication::applicationDirPath() + "/../lib/kaze/kaze-share");
        if (!QFileInfo(helper).isExecutable()) { emit shareDone(false, "Kaze's share helper is missing (" + helper + ")"); return; }
        auto *p = new QProcess(this);
        connect(p, &QProcess::finished, this, [this, p, after](int code) {
            QString msg = QString::fromUtf8(p->readAllStandardError()).trimmed().section('\n', -1);
            if (code == 126 || code == 127) msg = "Not allowed (the password was not given)";   // pkexec: dismissed / failed
            after(code == 0);
            static const QHash<QString, QString> said{{"fixed", "Fixed: reconnected without “stale file handle” trouble"},
                                                     {"later", "Fixed: it takes effect when the share reconnects (it is in use now)"},
                                                     {"already", "Already fixed"}};
            const QString out = QString::fromUtf8(p->readAllStandardOutput()).trimmed().section('\n', -1);
            emit shareDone(code == 0, code == 0 ? said.value(out) : msg.isEmpty() ? QString("Something went wrong") : msg);
            probe();
            emit drivesChanged();
            p->deleteLater();
        });
        if (shareRoot().isEmpty()) p->start("pkexec", {QFileInfo(helper).absoluteFilePath(), cmd});
        else p->start(helper, {cmd});
        p->write(in);
        p->closeWriteChannel();
    }

    // ---------- opening ----------
    Q_INVOKABLE void open(const QString &p) { QDesktopServices::openUrl(QUrl::fromLocalFile(p)); }
    Q_INVOKABLE void terminal(const QString &dir) {
        // $TERMINAL, else the desktop's own choice (xdg-terminal-exec), else the first common terminal installed
        QStringList names{qEnvironmentVariable("TERMINAL"), "xdg-terminal-exec", "kitty", "foot", "alacritty", "ghostty",
                          "wezterm", "konsole", "ptyxis", "kgx", "gnome-terminal", "xfce4-terminal", "tilix", "xterm"};
        for (const QString &n : names)
            if (!n.isEmpty() && !QStandardPaths::findExecutable(n).isEmpty()) { QProcess::startDetached(n, {}, dir); return; }
    }
    bool seeThrough() const {
        const QString force = qEnvironmentVariable("KAZE_SEE_THROUGH");
        return force.isEmpty() ? qEnvironmentVariableIsSet("HYPRLAND_INSTANCE_SIGNATURE") : force == "1";
    }

    // ---------- file operations ----------
    // copy / move run one at a time through cp / mv; a name that exists gets " (2)", " (3)", ... -- nothing is overwritten
    Q_INVOKABLE void copy(const QStringList &paths, const QString &dest) { queue(paths, dest, false); }
    Q_INVOKABLE void move(const QStringList &paths, const QString &dest) { queue(paths, dest, true); }
    // on a network share these run on a worker (a quiet job: errors come as a message), never waiting here
    void later(const QString &verb, const QString &name, const QString &dir, std::function<QString(Act *)> work) {
        Job j;
        j.verb = verb; j.name = name; j.where = dir; j.items = true; j.quiet = true;
        Step s{dir + "/" + name};
        s.work = std::move(work);
        j.steps << s;
        add(j);
    }
    Q_INVOKABLE QString rename(const QString &p, const QString &name) {
        if (name.isEmpty() || name.contains('/') || name == "." || name == "..") return "Not a valid name";
        const QString to = parent(p) + "/" + name;
        if (to == p) return {};
        if (Folder::onNetwork(p)) {
            later("Renaming", QFileInfo(p).fileName(), parent(p), [p, to, name](Act *u) -> QString {
                if (QFileInfo::exists(to)) return "“" + name + "” already exists";
                if (!QFile::rename(p, to)) return "Could not rename “" + QFileInfo(p).fileName() + "”";
                *u = {"rename", to, p};
                return {};
            });
            return {};
        }
        if (QFileInfo::exists(to)) return "\"" + name + "\" already exists";
        if (inArchive(p)) return "An opened archive can’t be changed: extract it first";
        if (!QFile::rename(p, to)) return "Could not rename";
        pushUndo("Rename of “" + name + "”", {{"rename", to, p}});
        emit touched(parent(p));
        return {};
    }
    Q_INVOKABLE QString mkdir(const QString &dir, const QString &name) {
        if (name.isEmpty() || name.contains('/')) return "Not a valid name";
        if (Folder::onNetwork(dir)) {
            later("Creating", name, dir, [dir, name](Act *u) -> QString {
                if (QFileInfo::exists(dir + "/" + name)) return "“" + name + "” already exists";
                if (!QDir(dir).mkdir(name)) return "Could not create the folder “" + name + "”";
                *u = {"rmdir", dir + "/" + name};   // undo only while it is still empty (no Trash on a share)
                return {};
            });
            return {};
        }
        if (QFileInfo::exists(dir + "/" + name)) return "\"" + name + "\" already exists";
        if (inArchive(dir)) return "An opened archive can’t be changed: extract it first";
        if (!QDir(dir).mkdir(name)) return "Could not create the folder";
        pushUndo("New Folder “" + name + "”", {{"trash", dir + "/" + name}});
        emit touched(dir);
        return {};
    }
    // zip: one item -> "name.zip", several -> "Archive.zip", next to them (never overwrites: free name)
    Q_INVOKABLE void compress(const QStringList &paths, const QString &dir) {
        if (paths.isEmpty()) return;
        plan([paths, dir](const QSet<QString> &taken) {
            Job j;
            j.verb = "Compressing"; j.name = many(paths); j.where = dir; j.srcs = paths; j.readSide = true;
            const QString to = freeName(dir, (paths.size() == 1 ? QFileInfo(paths[0]).fileName() : QStringLiteral("Archive")) + ".zip", taken);
            QStringList names;
            for (const QString &x : paths) names << QFileInfo(x).fileName();
            Step s{paths.value(0), to, "bsdtar", QStringList{"-a", "-cf", to, "-C", dir, "--"} + names};
            s.made = true; s.undo = {"trash", to};
            j.steps << s;
            return j;
        });
    }
    // zip / tar.* / 7z / rar ... -> a new folder named after the archive, next to it
    // ponytail: always a folder, even when the archive holds a single top-level folder (Finder unwraps that)
    Q_INVOKABLE void extract(const QString &archive) {
        plan([archive](const QSet<QString> &taken) {
            QString base = QFileInfo(archive).fileName();
            for (const char *e : {".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tgz", ".zip", ".7z", ".rar", ".tar", ".gz", ".xz"})
                if (base.endsWith(e, Qt::CaseInsensitive)) { base.chop(qstrlen(e)); break; }
            const QString dir = QFileInfo(archive).absolutePath();
            Job j;
            j.verb = "Extracting"; j.name = QFileInfo(archive).fileName(); j.where = dir;   // ponytail: no total (would need a listing pass)
            const QString to = freeName(dir, base.isEmpty() ? QStringLiteral("Archive") : base, taken);
            if (!QDir().mkpath(to)) { j.errors << "Could not create “" + QFileInfo(to).fileName() + "”"; return j; }
            Step s{archive, to, "bsdtar", {"-xf", archive, "-C", to}};
            s.made = true; s.undo = {"trash", to};
            j.steps << s;
            return j;
        });
    }
    Q_INVOKABLE QString mkfile(const QString &dir, const QString &name) {
        if (name.isEmpty() || name.contains('/')) return "Not a valid name";
        if (Folder::onNetwork(dir)) {
            later("Creating", name, dir, [dir, name](Act *u) -> QString {
                QFile f(dir + "/" + name);
                if (!f.open(QIODevice::NewOnly)) return "Could not create “" + name + "” (it may exist already)";
                return {};   // no undo: it may have been written to meanwhile, and a share has no Trash
            });
            return {};
        }
        if (QFileInfo::exists(dir + "/" + name)) return "\"" + name + "\" already exists";
        QFile f(dir + "/" + name);
        if (inArchive(dir)) return "An opened archive can’t be changed: extract it first";
        if (!f.open(QIODevice::NewOnly)) return "Could not create the file";
        pushUndo("New File “" + name + "”", {{"trash", dir + "/" + name}});
        emit touched(dir);
        return {};
    }
    Q_INVOKABLE QString unique(const QString &dir, const QString &name) const {
        const QFileInfo f(dir + "/" + name);
        if (!f.exists() && !f.isSymLink() && !m_reserved.contains(f.filePath())) return f.filePath();
        // "a.tar.gz" -> "a (2).tar.gz"; folders and dotfiles keep the whole name as the base
        const int dot = f.isDir() || name.startsWith('.') ? -1 : name.indexOf('.');
        const QString base = dot > 0 ? name.left(dot) : name, ext = dot > 0 ? name.mid(dot) : QString();
        for (int i = 2;; ++i) {
            const QString t = dir + "/" + base + " (" + QString::number(i) + ")" + ext;
            if (!QFileInfo::exists(t) && !QFileInfo(t).isSymLink() && !m_reserved.contains(t)) return t;
        }
    }

    // ---------- drag and drop ----------
    // drag files out (to another pane, a folder, the sidebar, or another app): a system drag carrying file:// URLs.
    // Blocks until dropped; whoever receives it does the copy / move (Kaze's own drops: dropFiles below).
    Q_INVOKABLE void drag(const QStringList &paths) {
        if (paths.isEmpty()) return;
        auto *mime = new QMimeData;
        QList<QUrl> urls;
        for (const QString &p : paths) urls << QUrl::fromLocalFile(p);
        mime->setUrls(urls);
        mime->setText(paths.join('\n'));
        mime->setData("application/x-kaze-drag", QByteArray::number(QCoreApplication::applicationPid()));
        auto *d = new QDrag(this);
        d->setMimeData(mime);
        d->setPixmap(dragBadge(paths));
        d->setHotSpot(QPoint(-12, -12));
        emit dragStarted();
        d->exec(Qt::CopyAction | Qt::MoveAction | Qt::LinkAction, Qt::CopyAction);
    }
    // what the pointer carries: the first name (+ how many more), in the theme's colours
    QPixmap dragBadge(const QStringList &paths) const {
        const qreal dpr = qGuiApp->devicePixelRatio();
        QFont f(m_fonts.value("mono", "monospace").toString());
        f.setPixelSize(13);
        const QString name = QFileInfo(paths[0]).fileName(), more = paths.size() > 1 ? QString::number(paths.size()) : QString();
        const QFontMetrics fm(f);
        const QString shown = fm.elidedText(name, Qt::ElideMiddle, 260);
        const int w = fm.horizontalAdvance(shown) + 24 + (more.isEmpty() ? 0 : fm.horizontalAdvance(more) + 18), h = 28;
        QPixmap px(QSize(w + 2, h + 2) * dpr);
        px.setDevicePixelRatio(dpr);
        px.fill(Qt::transparent);
        QPainter g(&px);
        g.setRenderHint(QPainter::Antialiasing);
        auto col = [this](const char *k, const char *fb) { const QString v = m_colors.value(k).toString(); return QColor(v.isEmpty() ? fb : v); };
        QColor bg = col("surface", "#25262a"); bg.setAlphaF(0.95);
        g.setPen(QPen(col("accent", "#b9bcc4"), 1));
        g.setBrush(bg);
        g.drawRoundedRect(QRectF(0.5, 0.5, w, h), 6, 6);
        g.setFont(f);
        g.setPen(col("text", "#d4d5d9"));
        g.drawText(QRectF(12, 0, w, h), Qt::AlignVCenter, shown);
        if (!more.isEmpty()) {
            const QRectF b(w - fm.horizontalAdvance(more) - 14, 6, fm.horizontalAdvance(more) + 8, 16);
            g.setPen(Qt::NoPen); g.setBrush(col("accent", "#b9bcc4"));
            g.drawRoundedRect(b, 8, 8);
            g.setPen(col("bg", "#1b1c1f"));
            g.drawText(b, Qt::AlignCenter, more);
        }
        return px;
    }
    // files dropped on folder `dest` (from Kaze or another app). Like Finder / Nautilus: same drive = move, another
    // drive = copy; Ctrl = copy, Shift = move; onto the Trash = to the trash; into the folder they are already in =
    // nothing (Ctrl there = duplicate). Returns what it did, for the status bar ("" = nothing).
    Q_INVOKABLE bool altHeld() const { return QGuiApplication::queryKeyboardModifiers() & Qt::AltModifier; }
    Q_INVOKABLE QString dropFiles(const QList<QUrl> &urls, const QString &dest) {
        QStringList paths;
        for (const QUrl &u : urls) if (u.isLocalFile()) { const QString p = QFileInfo(u.toLocalFile()).absoluteFilePath(); if (p != dest) paths << p; }
        if (paths.isEmpty() || dest.isEmpty()) return {};
        const QString what = paths.size() == 1 ? "“" + QFileInfo(paths[0]).fileName() + "”" : QString::number(paths.size()) + " items";
        if (dest == trashDir()) return trash(paths) ? "Moving " + what + " to the Trash" : QString();
        if (dest.startsWith(trashDir() + "/")) return {};
        const auto mods = QGuiApplication::queryKeyboardModifiers();
        const bool copyIt = mods & Qt::ControlModifier ? true : mods & Qt::ShiftModifier ? false : Folder::mountOf(paths[0]) != Folder::mountOf(dest);
        if (!copyIt || !(mods & Qt::ControlModifier)) {
            paths.erase(std::remove_if(paths.begin(), paths.end(), [&](const QString &p) { return parent(p) == dest; }), paths.end());
            if (paths.isEmpty()) return {};
        }
        if (copyIt) copy(paths, dest); else move(paths, dest);
        return QString(copyIt ? "Copying " : "Moving ") + what + " to “" + QFileInfo(dest).fileName() + "”";
    }

    // ---------- clipboard (text/uri-list + GNOME's cut marker, so Nautilus and others understand it) ----------
    Q_INVOKABLE void setClipboard(const QStringList &paths, bool cut) {
        auto *m = new QMimeData;
        QList<QUrl> urls;
        QByteArray g = cut ? "cut" : "copy";
        for (const auto &p : paths) { urls << QUrl::fromLocalFile(p); g += "\n" + urls.last().toEncoded(); }
        m->setUrls(urls);
        m->setData("x-special/gnome-copied-files", g);
        m->setText(paths.join('\n'));
        QGuiApplication::clipboard()->setMimeData(m);
    }
    Q_INVOKABLE void setText(const QString &t) { QGuiApplication::clipboard()->setText(t); }
    Q_INVOKABLE QVariantMap clipboard() const {
        const QMimeData *m = QGuiApplication::clipboard()->mimeData();
        QStringList paths;
        if (m) for (const auto &u : m->urls()) if (u.isLocalFile()) paths << u.toLocalFile();
        return {{"paths", paths}, {"cut", m && m->data("x-special/gnome-copied-files").startsWith("cut")}};
    }

    // ---------- previews, all cached in ~/.cache/kaze (keyed by path + mtime), made by a queue of at most 2 processes ----------
    // Office files (docx/xlsx/pptx/doc/xls/ppt/odt/ods/odp/rtf) become a PDF through OnlyOffice's converter `x2t`
    // (Udiksa ships OnlyOffice); it needs OnlyOffice's font list, written the first time OnlyOffice runs.
    static QString x2t() { return QStringLiteral("/opt/onlyoffice/desktopeditors/converter/x2t"); }
    static QString officeFonts() { return QDir::homePath() + "/.local/share/onlyoffice/desktopeditors/data/fonts"; }
    bool officePreview() const { return QFileInfo::exists(x2t()) && QFileInfo::exists(officeFonts() + "/AllFonts.js"); }
    static bool modelPreview() { static const bool y = !QStandardPaths::findExecutable("f3d").isEmpty(); return y; }
    static bool office(const QString &kind) { return kind == "doc" || kind == "sheet" || kind == "slides"; }

    // the document as a PDF: the file itself, or its converted copy ("" while converting -> pdfReady())
    Q_INVOKABLE QString toPdf(const QString &p, const QString &kind) {
        if (kind == "pdf") return p;
        if (!office(kind) || !officePreview()) return {};
        const QString out = cachePath(p, ".pdf");
        if (QFileInfo::exists(out)) return out;
        if (m_pending.contains(out)) return {};
        const QString tmp = out.chopped(4) + ".tmp";
        QDir().mkpath(tmp);
        QFile x(tmp + "/task.xml");
        if (!x.open(QIODevice::WriteOnly)) return {};
        auto esc = [](QString t) { return t.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;"); };
        x.write(QString("<?xml version=\"1.0\" encoding=\"utf-8\"?><TaskQueueDataConvert><m_sFileFrom>%1</m_sFileFrom><m_sFileTo>%2</m_sFileTo>"
                        "<m_nFormatTo>513</m_nFormatTo><m_sAllFontsPath>%3/AllFonts.js</m_sAllFontsPath><m_sFontDir>%3</m_sFontDir>"
                        "<m_sTempDir>%4</m_sTempDir></TaskQueueDataConvert>").arg(esc(p), esc(out), esc(officeFonts()), esc(tmp)).toUtf8());
        x.close();
        enqueue(x2t(), {tmp + "/task.xml"}, out, Urgent, [this, p, kind, out, tmp](bool ok) {
            QDir(tmp).removeRecursively();
            if (!ok || !QFileInfo::exists(out)) { m_thumbAfterPdf.remove(p); emit previewFailed(p); return; }
            emit pdfReady(p, out);
            if (m_thumbAfterPdf.remove(p)) preview(p, kind);
        });
        return {};
    }

    // a small picture of the file: first page (pdf, office) or a video frame ("" while making it -> previewReady())
    // `later` = made ahead of time (prefetch): after everything that is on screen.
    Q_INVOKABLE QString preview(const QString &p, const QString &kind, bool later = false) {
        const QString out = cachePath(p, ".jpg");   // JPEG at 768 px: 3x faster than a 110 dpi PNG, 17x smaller
        if (QFileInfo::exists(out)) return out;
        if (m_pending.contains(out)) {   // asked ahead of time and now on screen: move it up
            // a picture waiting behind a folder's worth of others is made again, now, at the front (same file, written atomically)
            if (later || kind != "image" || !m_imgLater.remove(out)) {
                for (int i = 0; !later && i < m_bgq.size(); ++i) if (m_bgq[i].out == out) { m_pq.prepend(m_bgq.takeAt(i)); break; }
                return {};
            }
        }
        if (kind == "image") {
            // small pictures are shown as they are; big ones get a 768 px copy, made in-process (no program to start)
            const auto k = look(p);
            if (!k) return {};                         // a share not read yet: no picture rather than a wait
            if (k->size < 300 * 1024) return p;
            if (QFileInfo::exists(out.chopped(4) + ".png")) return out.chopped(4) + ".png";
            m_pending << out;
            if (later) m_imgLater << out;
            QPointer<Fs> self(this);
            m_imgPool.start([self, p, out] {
                QImageReader r(p);
                r.setAutoTransform(true);
                const QSize sz = r.size();
                if (sz.isValid() && std::max(sz.width(), sz.height()) > 768) r.setScaledSize(sz.scaled(768, 768, Qt::KeepAspectRatio));
                const QImage img = r.read();
                const QString file = img.hasAlphaChannel() ? out.chopped(4) + ".png" : out;   // keep transparency
                QSaveFile f(file);
                const bool ok = !img.isNull() && f.open(QIODevice::WriteOnly) && img.save(&f, img.hasAlphaChannel() ? "PNG" : "JPG", 85) && f.commit();
                QMetaObject::invokeMethod(qApp, [self, p, out, file, ok] {
                    if (!self) return;
                    self->m_pending.remove(out);
                    self->m_imgLater.remove(out);
                    if (ok || QFileInfo::exists(file)) emit self->previewReady(p, file);
                    else emit self->previewFailed(p);
                }, Qt::QueuedConnection);
            }, later ? 0 : 1);
            return {};
        }
        if (kind == "raw" || kind == "book") {   // the picture comes from a program's output / the book's zip: made in-process
            m_pending << out;
            if (later) m_imgLater << out;
            QPointer<Fs> self(this);
            m_imgPool.start([self, p, out, kind] {
                QProcess pr;
                if (kind == "raw") pr.start("dcraw_emu", {"-h", "-w", "-Z", "-", p});   // half size, camera colours, to stdout
                else {   // the cover: a picture named "cover", else the first picture in the book
                    QString pick;
                    for (const QString &e : run("unzip", {"-Z1", p}).split('\n'))
                        if (QRegularExpression("\\.(jpe?g|png|gif|webp)$", QRegularExpression::CaseInsensitiveOption).match(e).hasMatch()) {
                            if (pick.isEmpty()) pick = e;
                            if (e.contains("cover", Qt::CaseInsensitive)) { pick = e; break; }
                        }
                    if (!pick.isEmpty()) pr.start("unzip", {"-p", p, pick});
                }
                QByteArray data;
                if (pr.waitForFinished(30000)) data = pr.readAllStandardOutput(); else pr.kill();
                QBuffer buf(&data);
                QImageReader r(&buf);
                const QSize sz = r.size();
                if (sz.isValid() && std::max(sz.width(), sz.height()) > 768) r.setScaledSize(sz.scaled(768, 768, Qt::KeepAspectRatio));
                const QImage img = r.read();
                QSaveFile f(out);
                const bool ok = !img.isNull() && f.open(QIODevice::WriteOnly) && img.convertToFormat(QImage::Format_RGB32).save(&f, "JPG", 85) && f.commit();
                QMetaObject::invokeMethod(qApp, [self, p, out, ok] {
                    if (!self) return;
                    self->m_pending.remove(out); self->m_imgLater.remove(out);
                    if (ok) emit self->previewReady(p, out); else emit self->previewFailed(p);
                }, Qt::QueuedConnection);
            }, later ? 0 : 1);
            return {};
        }
        if (kind == "model") {   // 3D: a picture rendered by f3d (only when it is installed)
            const QString png = out.chopped(4) + ".png";
            if (QFileInfo::exists(png)) return png;
            if (!modelPreview() || m_pending.contains(png)) return {};
            enqueue("f3d", {"--output=" + png, "--resolution=768,768", p}, png, later ? Later : Shown,
                    [this, p, png](bool ok) { if (ok && QFileInfo::exists(png)) emit previewReady(p, png); else emit previewFailed(p); });
            return {};
        }
        auto done = [this, p, out](bool ok) { if (ok && QFileInfo::exists(out)) emit previewReady(p, out); else emit previewFailed(p); };
        if (kind == "video") enqueue("ffmpegthumbnailer", {"-i", p, "-o", out, "-s", "1024", "-c", "jpeg", "-q", "8"}, out, later ? Later : Shown, done);
        else if (kind == "pdf" || office(kind)) {
            const QString pdf = toPdf(p, kind);
            if (pdf.isEmpty()) { if (office(kind) && officePreview()) m_thumbAfterPdf << p; return {}; }
            enqueue("pdftoppm", {"-jpeg", "-singlefile", "-scale-to", "768", "-f", "1", "-l", "1", pdf, out.chopped(4)}, out, later ? Later : Shown, done);
        }
        return {};
    }

    // Make the previews of a folder's pictures, PDFs and videos ahead of time, so they are there before you look.
    // Office files are left until shown (the converter takes ~1 s each); folders on network shares are skipped.
    Q_INVOKABLE void prefetch(const QString &dir) {
        if (Folder::onNetwork(dir)) return;
        bg("prefetch:" + dir, [dir] {
            QStringList todo;
            for (const QFileInfo &f : QDir(dir).entryInfoList(QDir::Files | QDir::Hidden)) {
                const QString k = kind(f.filePath());
                if ((k == "image" || k == "pdf" || k == "video" || k == "raw" || k == "book") && todo.size() < 1000) todo << k + ":" + f.filePath();   // ponytail: 1000 per folder
            }
            return [todo](Fs *fs) { for (const QString &t : todo) fs->preview(t.section(':', 1), t.section(':', 0, 0), true); };
        });
    }

    // Preview cache (~/.cache/kaze): at start, previews unused for 60 days go, and the oldest go while it is over 500 MB.
    static QString cacheDir() { return QStandardPaths::writableLocation(QStandardPaths::CacheLocation); }
    static void prune(qint64 cap = 500LL << 20) {
        QFileInfoList L = QDir(cacheDir()).entryInfoList(QDir::Files, QDir::Time | QDir::Reversed);   // oldest first
        qint64 total = 0;
        for (const QFileInfo &f : L) total += f.size();
        const QDateTime old = QDateTime::currentDateTime().addDays(-60);
        for (const QFileInfo &f : L)
            if (total > cap || f.lastModified() < old) { total -= f.size(); QFile::remove(f.filePath()); }
    }
    Q_INVOKABLE void clearPreviews() {
        bg("clear-previews", [] {
            qint64 n = 0;
            for (const QFileInfo &f : QDir(cacheDir()).entryInfoList(QDir::Files)) if (QFile::remove(f.filePath())) n += f.size();
            return [n](Fs *fs) { emit fs->notice("Cleared " + size(n) + " of previews"); };
        });
    }

    // a folder's total size and what is in it, counted on a worker; stays on the folder's own drive (like du -x),
    // so a mounted share or disk inside is not counted (and a dead share cannot hang it)
    // stopDirSize(dir): the preview moved on -- the count stops (arrowing past big folders must not pile up walks)
    Q_INVOKABLE void askDirSize(const QString &dir) {
        auto stop = std::make_shared<std::atomic_bool>(false);
        if (auto old = m_sizing.value(dir)) *old = true;
        m_sizing.insert(dir, stop);
        QPointer<Fs> self(this);
        bg("dirsize:" + dir + ":" + QString::number(++m_sizeRun), [self, dir, stop] {
            qint64 files = 0, dirs = 0;
            const qint64 bytes = bytesIn(dir, stop.get(), &files, &dirs, [self, dir, stop](qint64 b, qint64 f, qint64 d) {   // so far
                QMetaObject::invokeMethod(qApp, [self, dir, stop, b, f, d] { if (self && !*stop) emit self->dirSizeReady(dir, double(b), int(f), int(d), false); });
            });
            return [dir, bytes, files, dirs, stop](Fs *fs) {
                if (fs->m_sizing.value(dir) == stop) fs->m_sizing.remove(dir);
                if (!*stop) emit fs->dirSizeReady(dir, double(bytes), int(files), int(dirs), true);
            };
        });
    }
    Q_INVOKABLE void stopDirSize(const QString &dir) { if (auto s = m_sizing.take(dir)) *s = true; }

    // folder looks: colour (a theme colour name) + emblem (a glyph name; "none" = no emblem), kept in ~/.config/kaze/looks.json
    // ponytail: keyed by path -- a renamed or moved folder loses its look
    Q_INVOKABLE void setLook(const QString &p, const QString &color, const QString &emblem) {
        if (color.isEmpty() && emblem.isEmpty()) m_looks.remove(p);
        else m_looks[p] = QVariantMap{{"color", color}, {"emblem", emblem}};
        QDir().mkpath(home() + "/.config/kaze");
        QFile f(home() + "/.config/kaze/looks.json");
        if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) f.write(QJsonDocument(QJsonObject::fromVariantMap(m_looks)).toJson());
        emit looksChanged();
    }

    // Open With: apps that say they open this type (or a type it is a kind of), the default first.
    // Same lists the desktop uses (mimeapps.list, mimeinfo.cache); `gio launch` starts the chosen one.
    Q_INVOKABLE QVariantList appsFor(const QString &p) const {
        const QMimeType m = QMimeDatabase().mimeTypeForFile(p, Folder::onNetwork(p) ? QMimeDatabase::MatchExtension : QMimeDatabase::MatchDefault);   // no reading a share
        const QStringList types = QStringList{m.name()} + m.aliases() + m.allAncestors();
        QStringList ids;
        QString def;
        auto add = [&](const QString &list) { for (const QString &id : list.split(';', Qt::SkipEmptyParts)) if (!ids.contains(id)) ids << id; };
        for (const QString &f : {QDir::homePath() + "/.config/mimeapps.list", QDir::homePath() + "/.local/share/applications/mimeapps.list"}) {
            QSettings ini(f, QSettings::IniFormat);
            for (const QString &t : types) {
                const QString d = ini.value("Default Applications/" + t).toStringList().join(';');
                if (def.isEmpty() && !d.isEmpty()) def = d.section(';', 0, 0);
                add(d);
                add(ini.value("Added Associations/" + t).toStringList().join(';'));
            }
        }
        const QStringList dirs = QStandardPaths::standardLocations(QStandardPaths::ApplicationsLocation);
        for (const QString &t : types)
            for (const QString &d : dirs) {
                QFile c(d + "/mimeinfo.cache");
                if (!c.open(QIODevice::ReadOnly)) continue;
                for (const QByteArray &line : c.readAll().split('\n'))
                    if (line.startsWith(t.toUtf8() + "=")) add(QString::fromUtf8(line.mid(t.size() + 1)));
            }
        QVariantList r;
        for (const QString &id : ids) {
            const QString file = QStandardPaths::locate(QStandardPaths::ApplicationsLocation, id);
            QFile f(file);
            if (file.isEmpty() || !f.open(QIODevice::ReadOnly)) continue;
            QString name;
            bool hidden = false, entry = false;
            for (const QByteArray &line : f.readAll().split('\n')) {
                if (line.startsWith('[')) { if (entry) break; entry = line.trimmed() == "[Desktop Entry]"; continue; }
                if (!entry) continue;
                if (line.startsWith("Name=") && name.isEmpty()) name = QString::fromUtf8(line.mid(5)).trimmed();
                if (line.startsWith("Hidden=true")) hidden = true;   // NoDisplay = not in app menus, still opens files (zathura's pdf plugin)
            }
            if (!hidden && !name.isEmpty()) r << QVariantMap{{"name", name}, {"desktop", file}, {"default", id == def}};
        }
        std::stable_sort(r.begin(), r.end(), [](const QVariant &a, const QVariant &b) { return a.toMap()["default"].toBool() > b.toMap()["default"].toBool(); });
        return r;
    }
    Q_INVOKABLE void openWith(const QString &desktop, const QStringList &paths) {
        if (!QProcess::startDetached("gio", QStringList{"launch", desktop} + paths)) emit error("Could not start the app");
    }

    // Quick Look pages: count, and one page `n` (1-based) rendered `width` px wide ("" while rendering -> pageReady())
    Q_INVOKABLE QString page(const QString &pdf, int n, int width) {
        const QString out = cachePath(pdf, "-p" + QString::number(n) + "-" + QString::number(width) + ".jpg");
        if (QFileInfo::exists(out)) return out;
        if (!m_pending.contains(out))
            enqueue("pdftoppm", {"-jpeg", "-jpegopt", "quality=90", "-singlefile", "-f", QString::number(n), "-l", QString::number(n), "-scale-to-x", QString::number(width),
                                 "-scale-to-y", "-1", pdf, out.chopped(4)}, out, Urgent,
                    [this, pdf, n, out](bool ok) { if (ok && QFileInfo::exists(out)) emit pageReady(pdf, n, out); });
        return {};
    }

    // Network shares: knock on the server's port (smb 445 / nfs 2049 / ssh 22) without touching the mount, which would
    // hang for seconds when the server is down. Unanswered within 1.5 s = offline: greyed in the sidebar, not opened.
    // Runs at start, every 30 s and when you click an offline share.
    Q_INVOKABLE void probe() {
        QHash<QString, QString> src;   // mount point -> source ("//host/share", "host:/path", "user@host:path")
        for (const QString f : {"/etc/fstab", "/proc/self/mounts"}) {
            QFile t(f);
            if (!t.open(QIODevice::ReadOnly)) continue;
            for (const QByteArray &line : t.readAll().split('\n')) {
                const auto c = line.simplified().split(' ');
                if (c.size() < 3 || c[0].startsWith('#')) continue;
                const QString type = c[2];
                if (type == "cifs" || type == "smb3" || type.startsWith("nfs") || type == "fuse.sshfs")
                    src[QString::fromUtf8(c[1]).replace("\\040", " ")] = type + " " + QString::fromUtf8(c[0]);
            }
        }
        for (auto it = src.begin(); it != src.end(); ++it) {
            const QString mp = it.key(), type = it.value().section(' ', 0, 0), from = it.value().section(' ', 1);
            const QString host = type.startsWith("nfs") ? from.section(':', 0, 0)
                               : type == "fuse.sshfs" ? from.section(':', 0, 0).section('@', -1)
                               : from.section('/', 2, 2);
            if (host.isEmpty()) continue;
            auto *s = new QTcpSocket(this);
            auto done = [this, s, mp](bool up) {
                if (s->property("done").toBool()) return;
                s->setProperty("done", true);
                s->deleteLater();
                if (up == !m_offline.contains(mp)) return;
                if (up) m_offline.removeAll(mp); else m_offline << mp;
                emit offlineChanged();
            };
            connect(s, &QTcpSocket::connected, this, [done] { done(true); });
            connect(s, &QTcpSocket::errorOccurred, this, [done] { done(false); });
            QTimer::singleShot(1500, s, [done] { done(false); });
            s->connectToHost(host, type.startsWith("nfs") ? 2049 : type == "fuse.sshfs" ? 22 : 445);
        }
    }

signals:
    void offlineChanged();
    void looksChanged();
    void dirSizeReady(const QString &dir, double bytes, int files, int folders, bool done);   // done = false: counts so far
    void themeChanged();
    void drivesChanged();
    void busyChanged();
    void shareDone(bool ok, const QString &message);
    void serversFound(const QVariantList &servers);
    void knocked(const QString &host, bool up);
    void jobsChanged();
    void touched(const QString &dir);
    void dragStarted();   // something in dir changed through Kaze (views of it re-read)
    void jobDone(const QString &verb, const QString &name, const QString &how);
    void caseClash(int id, const QStringList &pairs, const QString &dest);   // answer with clashAnswer   // done | failed | stopped
    void error(const QString &message);
    void notice(const QString &message);
    void mounted(const QString &path);
    void previewReady(const QString &path, const QString &image);
    void previewFailed(const QString &path);       // the program could not make one (broken / unusual file): show the icon
    void pdfReady(const QString &path, const QString &pdf);
    void pageReady(const QString &pdf, int page, const QString &image);
    void infoReady(const QString &path, const QVariantMap &info);
    void freeReady(const QString &dir, const QString &free);
    void textReady(const QString &path, const QString &text);
    void codeReady(const QString &path, const QString &html);
    void mediaReady(const QString &path, const QVariantList &rows);
    void pagesReady(const QString &pdf, int pages);
    void conflicts(int id, const QVariantList &items, const QString &verb, const QString &dest);   // answer with resolve()
    void confirmDelete(const QStringList &paths);   // no Trash there (network share): ask, then remove()
    void undoChanged();
    void archiveReady(const QString &archive, const QString &dir);
    void usageReady(const QString &dir, const QVariantList &rows, double total);
    void gitReady(const QString &dir, const QVariantMap &status, const QString &branch);

private:
    // run `work` on the thread pool; the callable it returns runs back on the UI thread. One probe per key at a time.
    template <class W> void bg(const QString &key, W work) {
        if (m_asking.contains(key)) return;
        m_asking << key;
        QPointer<Fs> self(this);
        QThreadPool::globalInstance()->start([self, key, work] {
            auto reply = work();   // static helpers only: Fs may be gone by the time a stuck probe returns
            QMetaObject::invokeMethod(qApp, [self, key, reply] { if (!self) return; self->m_asking.remove(key); reply(self.data()); }, Qt::QueuedConnection);
        });
    }
    QString cachePath(const QString &p, const QString &suffix) const {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
        QDir().mkpath(dir);
        const auto k = look(p);   // never stats a share from here (see Folder::Known)
        return dir + "/" + QCryptographicHash::hash((p + QString::number(k ? k->modified.toSecsSinceEpoch() : 0)).toUtf8(), QCryptographicHash::Md5).toHex() + suffix;
    }
    // preview jobs: half the cores at once. Quick Look pages / conversions (`urgent`) go first, in order; thumbnails
    // newest first, so the files you are looking at now come before the ones you scrolled past.
    struct PJob { QString prog; QStringList args; QString out; std::function<void(bool)> done; };
    enum Prio { Urgent, Shown, Later };
    void enqueue(const QString &prog, const QStringList &args, const QString &out, Prio prio, std::function<void(bool)> done) {
        m_pending << out;
        PJob j{prog, args, out, std::move(done)};
        if (prio == Urgent) m_urgent.append(j); else if (prio == Later) m_bgq.append(j); else m_pq.prepend(j);
        pump();
    }
    void pump() {
        static const int most = std::max(2, QThread::idealThreadCount() / 2);
        while (m_running < most && !(m_urgent.isEmpty() && m_pq.isEmpty() && m_bgq.isEmpty())) {
            const PJob j = !m_urgent.isEmpty() ? m_urgent.takeFirst() : !m_pq.isEmpty() ? m_pq.takeFirst() : m_bgq.takeFirst();
            ++m_running;
            auto *pr = new QProcess(this);
            auto finish = [this, pr, j](bool ok) { --m_running; m_pending.remove(j.out); pr->deleteLater(); j.done(ok); pump(); };
            connect(pr, &QProcess::finished, this, [finish](int code, QProcess::ExitStatus st) { finish(code == 0 && st == QProcess::NormalExit); });
            connect(pr, &QProcess::errorOccurred, this, [finish](QProcess::ProcessError e) { if (e == QProcess::FailedToStart) finish(false); });
            pr->start(j.prog, j.args);
            QTimer::singleShot(30000, pr, [pr] { pr->kill(); });   // a stuck converter must not hold a slot forever
        }
    }
    static bool udevIgnored(const QString &majMin) {
        QFile f("/run/udev/data/b" + majMin);
        return !f.open(QIODevice::ReadOnly) || f.readAll().contains("E:UDISKS_IGNORE=1");
    }
    void loadTheme() {
        auto read = [](const QString &f) { QFile x(f); return x.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(x.readAll()).object().toVariantMap() : QVariantMap(); };
        m_colors = read(m_themeDir + "/colors.json");
        m_fonts = read(m_themeDir + "/fonts.json");
        for (const char *f : {"/colors.json", "/fonts.json"}) if (QFileInfo::exists(m_themeDir + f)) m_watch.addPath(m_themeDir + f);
        if (QFileInfo(m_themeDir).isDir()) m_watch.addPath(m_themeDir);
        writeCodeStyle();
        emit themeChanged();
    }
    // source-highlight's colours, from the theme only: keywords accent (bold), types / strings / numbers the lighter
    // accent, comments dim (italic), punctuation muted, the rest text
    void writeCodeStyle() {
        auto c = [this](const char *k, const char *fallback) { const QString v = m_colors.value(k).toString(); return "\"" + (v.isEmpty() ? QString(fallback) : v) + "\""; };
        const QString acc = c("accent", "#b9bcc4"), acc2 = c("accent2", "#d0d2d7"), text = c("text", "#d4d5d9"), muted = c("muted", "#96989f"), dim = c("dim", "#5a5c62");
        QDir().mkpath(cacheDir());
        m_codeStyle = cacheDir() + "/code.style";
        QFile f(m_codeStyle);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
        f.write(QString("keyword %1 b;\npreproc %1;\ntodo %1 b;\ntype %2;\nusertype %2;\nclassname %2;\nfunction %2;\nstring %2;\nregexp %2;\nspecialchar %2;\n"
                        "number %2;\nnormal %3;\nvariable %3;\nsymbol %4;\ncbracket %4;\ncomment %5 i;\n")
                    .arg(acc, acc2, text, muted, dim).toUtf8());
    }
public:
    // ---------- the job engine: copy / move / link / zip / extract / trash / delete / undo, one job at a time ----------
    // A job is a list of steps (one per item). A step is a process (cp, mv, ln, bsdtar, rm, chmod, ...) or work done on a
    // worker thread (trash, restore, rename). Planning -- free names, which drive, names already taken -- runs on a
    // worker too, one plan after another, so a slow share never freezes the window. Every finished step leaves its
    // inverse (Act); a finished job's inverses are one Undo (Ctrl+Z).
    static QStringList cpArgs(bool net, bool merge) {
        // to a network share only timestamps are kept: cp -a also copies extended attributes and tries the owner, a
        // server round trip each per file (measured to a NAS: 50 small files 7.5 s with -a, 3.9 s without)
        QStringList a = net ? QStringList{"-dR", "--preserve=timestamps"} : QStringList{"-a"};
        return a << (merge ? "-u" : "-n") << "-T" << "--";   // merge: add what is missing, newer files replace older
    }
    // a free name in `dir` for `name`: "a.tar.gz" -> "a (2).tar.gz" (folders and dotfiles keep the whole name);
    // `taken` = names already promised to queued jobs. Stats the disk: workers only.
    static QString freeName(const QString &dir, const QString &name, const QSet<QString> &taken, bool disk = true) {
        auto free = [&](const QString &t) { return !taken.contains(t) && (!disk || (!QFileInfo::exists(t) && !QFileInfo(t).isSymLink())); };
        const QString first = dir + "/" + name;
        if (free(first)) return first;
        const int dot = (disk && QFileInfo(first).isDir()) || name.startsWith('.') ? -1 : name.indexOf('.');
        const QString base = dot > 0 ? name.left(dot) : name, ext = dot > 0 ? name.mid(dot) : QString();
        for (int i = 2;; ++i) { const QString t = dir + "/" + base + " (" + QString::number(i) + ")" + ext; if (free(t)) return t; }
    }
    static QString many(const QStringList &paths) { return paths.size() == 1 ? QFileInfo(paths[0]).fileName() : QString::number(paths.size()) + " items"; }

    // copy / move: one job however many items. A name that is taken asks (conflicts() -> resolve()); a copy into the
    // folder it is in is a duplicate ("x (2)") without asking.
    void queue(const QStringList &paths, const QString &dest, bool isMove) {
        if (paths.isEmpty()) return;
        plan([paths, dest, isMove](const QSet<QString> &taken) {
            const auto dev = [](const QString &p) { struct stat s; return ::stat(QFile::encodeName(p).constData(), &s) ? dev_t(-1) : s.st_dev; };
            Job j;
            j.verb = isMove ? "Moving" : "Copying"; j.where = dest; j.dest = dest; j.isMove = isMove; j.isCopy = true;
            j.net = Folder::onNetwork(dest);
            if (inArchive(dest)) { j.errors << "An opened archive can’t be changed: extract it first"; return j; }
            QSet<QString> mine = taken;
            for (const QString &p : paths) {
                const QFileInfo f(p);
                const QString from = f.absolutePath();
                if (isMove && from == dest) continue;   // moving into the folder it is already in
                if (dest == p || dest.startsWith(p + "/")) { j.errors << "Cannot put “" + f.fileName() + "” inside itself"; continue; }
                Item it{p, f.fileName(), f.isDir() && !f.isSymLink(), dev(from) == dev(dest)};
                const QFileInfo t(dest + "/" + it.name);
                if ((t.exists() || t.isSymLink()) && from != dest) {
                    it.conflict = j.conflicts.size();
                    j.conflicts << QVariantMap{{"name", it.name}, {"dir", it.dir}, {"theirDir", t.isDir()},
                                               {"size", it.dir ? QString() : size(f.size())}, {"theirSize", t.isDir() ? QString() : size(t.size())},
                                               {"date", QLocale().toString(f.lastModified(), "d MMM yyyy, HH:mm")},
                                               {"theirDate", QLocale().toString(t.lastModified(), "d MMM yyyy, HH:mm")},
                                               {"newer", f.lastModified() > t.lastModified()}};
                }
                it.keepBoth = freeName(dest, it.name, mine);
                mine << it.keepBoth;
                j.plan << it;
            }
            j.name = j.plan.size() == 1 ? j.plan[0].name : QString::number(j.plan.size()) + " items";
            if (j.net) { QStringList from; for (const Item &it : j.plan) from << it.from; j.clashes = caseClashes(from); }
            return j;
        });
    }
    // A Windows-style share (SMB) ignores letter case: "kaze" and "Kaze" in one folder are one name there, and the
    // second one fails to copy. Names in what is being copied that would clash: "Kaze/build/kaze  ·  Kaze/build/Kaze".
    // ponytail: every SMB destination counts as case-blind (Samba's and Windows' default); no probe of the server.
    static QStringList caseClashes(const QStringList &paths) {
        QStringList out;
        auto look = [&](const QStringList &names, const QString &shown) {
            QHash<QString, QString> seen;
            for (const QString &n : names) {
                const QString k = n.toLower();
                if (seen.contains(k)) out << shown + seen[k] + "  ·  " + shown + n; else seen.insert(k, n);
            }
        };
        QStringList tops;
        for (const QString &p : paths) tops << QFileInfo(p).fileName();
        look(tops, {});
        for (const QString &p : paths) {
            const QFileInfo f(p);
            if (!f.isDir() || f.isSymLink()) continue;
            const QString root = f.absolutePath() + "/";
            QStringList dirs{p};
            for (QDirIterator d(p, QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System | QDir::NoSymLinks, QDirIterator::Subdirectories); d.hasNext();) dirs << d.next();
            for (const QString &d : dirs) {
                if (out.size() > 50) return out;
                look(QDir(d).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System), d.mid(root.size()) + "/");
            }
        }
        return out;
    }
    // the answer to caseClash: go = copy anyway (those few fail, the rest arrives), else the paste is dropped
    Q_INVOKABLE void clashAnswer(int id, bool go) {
        if (!m_ask.contains(id)) return;
        Job j = m_ask.take(id);
        if (!go) { for (const Item &it : j.plan) m_reserved.remove(it.keepBoth); emit busyChanged(); emit jobsChanged(); return; }
        j.clashes.clear();
        if (!j.conflicts.isEmpty()) { m_ask.insert(id, j); emit conflicts(id, j.conflicts, j.verb, j.dest); }
        else { build(j, {}); add(j); }
    }
    // the answers to the conflicts, one per conflict: both | replace | skip | merge (folders); [] = cancel the whole paste
    Q_INVOKABLE void resolve(int id, const QStringList &choices) {
        if (!m_ask.contains(id)) return;
        Job j = m_ask.take(id);
        if (choices.isEmpty()) { for (const Item &it : j.plan) m_reserved.remove(it.keepBoth); emit busyChanged(); emit jobsChanged(); return; }
        build(j, choices);
        add(j);
    }
    void build(Job &j, const QStringList &choices) {
        for (const Item &it : j.plan) {
            const QString how = it.conflict < 0 ? "new" : choices.value(it.conflict, "both");
            const QString target = j.dest + "/" + it.name;
            if (how != "new" && how != "both") m_reserved.remove(it.keepBoth);
            if (how == "skip") continue;
            const bool merge = how == "merge" && it.dir;
            const QString to = how == "replace" || merge ? target : it.keepBoth;
            if (how == "replace") {   // the one there goes first: to the Trash on a local drive, deleted on a share
                if (j.net) { j.steps << Step{target, {}, "rm", {"-rf", "--", target}}; j.noUndo = true; }
                else j.steps << trashStep(target);
            }
            const QStringList cp = cpArgs(j.net, merge) + QStringList{it.from, to};
            Step s{it.from, to};
            s.made = !merge;
            s.counts = !j.isMove || !it.sameDev || j.net;   // a move within a drive is a rename: nothing to count
            if (!j.isMove) { s.prog = "cp"; s.args = cp; if (!merge) s.undo = {"trash", to}; }
            else if (!merge && (!j.net || it.sameDev)) { s.prog = "mv"; s.args = {"-n", "-T", "--", it.from, to}; s.undo = {"move", to, it.from}; }
            else {   // to a share from another drive (or merging): the copy above, then the originals go
                s.prog = "sh"; s.args = {"-c", "cp " + cp.mid(0, cp.size() - 2).join(' ') + " \"$1\" \"$2\" && rm -rf -- \"$1\"", "sh", it.from, to};
                if (!merge) s.undo = {"move", to, it.from};
            }
            if (merge) j.noUndo = true;
            j.steps << s;
        }
        j.plan.clear(); j.conflicts.clear();
    }
    // plans run one after another (each sees the names the one before took), on a worker
    void plan(std::function<Job(const QSet<QString> &)> make) {
        m_plans << make;
        emit busyChanged();
        if (m_plans.size() == 1) planNext();
    }
    void planNext() {
        if (m_plans.isEmpty()) return;
        QPointer<Fs> self(this);
        const auto make = m_plans.first();
        const QSet<QString> taken = m_reserved;
        QThreadPool::globalInstance()->start([self, make, taken] {
            Job j = make(taken);
            QMetaObject::invokeMethod(qApp, [self, j]() mutable { if (self) self->commit(j); }, Qt::QueuedConnection);
        });
    }
    void commit(Job j) {
        m_plans.removeFirst();
        for (const QString &e : j.errors) emit error(e);
        j.errors.clear();
        if (j.isCopy) {
            for (const Item &it : j.plan) m_reserved << it.keepBoth;
            if (!j.clashes.isEmpty()) {   // names only the letter case tells apart, going to a share: ask first
                j.id = ++m_jobId;
                m_ask.insert(j.id, j);
                emit caseClash(j.id, j.clashes, j.dest);
            } else if (!j.conflicts.isEmpty()) {   // ask; the plan waits
                j.id = ++m_jobId;
                m_ask.insert(j.id, j);
                emit conflicts(j.id, j.conflicts, j.verb, j.dest);
            } else { build(j, {}); add(j); }
        } else add(j);
        planNext();
        emit busyChanged();
    }
    void add(Job j) {
        if (j.steps.isEmpty()) { emit busyChanged(); emit jobsChanged(); return; }
        for (const Step &s : j.steps) if (s.made && !s.to.isEmpty()) m_reserved << s.to;
        if (!j.id) j.id = ++m_jobId;
        m_jobs << j;
        next();
    }
    void release(const Job &j, int from) { for (int i = from; i < j.steps.size(); ++i) m_reserved.remove(j.steps[i].to); }

    // trash: work on a worker (QFile::moveToTrash renames into ~/.local/share/Trash, or the drive's own .Trash-uid).
    // Network shares have no usable Trash (Qt can't make .Trash-uid there: the share forces its own permissions, and
    // the home Trash is another drive) -- confirmDelete() asks to delete instead, like Finder on a network volume.
    static Step trashStep(const QString &p) {
        Step s{p};
        s.work = [p](Act *u) -> QString {
            const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/Trash";
            for (const char *sub : {"/files", "/info"}) QDir().mkpath(base + sub);   // Qt fails when the home trash does not exist yet
            QString in;
            if (!QFile::moveToTrash(p, &in)) return "Could not move “" + QFileInfo(p).fileName() + "” to the Trash";
            *u = {"restore", in, p};
            return {};
        };
        return s;
    }
    Q_INVOKABLE bool trash(const QStringList &paths) {   // false: nothing moved (asked to delete instead, or refused)
        if (paths.isEmpty()) return false;
        if (inArchive(paths[0])) { emit error("An opened archive can’t be changed: extract it first"); return false; }
        QStringList noTrash;
        for (const QString &p : paths) if (Folder::onNetwork(p)) noTrash << p;
        if (!noTrash.isEmpty()) { emit confirmDelete(paths); return false; }
        Job j;
        j.verb = "Moving to Trash"; j.name = many(paths); j.where = parent(paths[0]); j.items = true;
        for (const QString &p : paths) j.steps << trashStep(p);
        add(j);
        return true;
    }
    // Put Back: to where it came from (a taken name gets " (2)")
    Q_INVOKABLE void restore(const QStringList &paths) {
        if (paths.isEmpty()) return;
        Job j;
        j.verb = "Putting back"; j.name = many(paths); j.where = trashDir(); j.items = true;
        for (const QString &p : paths) {
            Step s{p};
            s.work = [p](Act *u) -> QString {
                const QString name = QFileInfo(p).fileName(), info = QFileInfo(p).absolutePath() + "/../info/" + name + ".trashinfo";
                const QSettings ti(info, QSettings::IniFormat);
                QString orig = QUrl::fromPercentEncoding(ti.value("Trash Info/Path").toByteArray());
                if (orig.isEmpty()) return "No record of where “" + name + "” came from";
                if (!orig.startsWith('/')) {   // a drive's own Trash may keep the path relative to the drive
                    QString top = QFileInfo(p).absolutePath() + "/../..";
                    if (QFileInfo(top).fileName() == ".Trash") top += "/..";
                    orig = QDir(top).absolutePath() + "/" + orig;
                }
                QDir().mkpath(QFileInfo(orig).absolutePath());
                const QString to = freeName(QFileInfo(orig).absolutePath(), QFileInfo(orig).fileName(), {});
                if (!QFile::rename(p, to)) return "Could not put back “" + name + "”";
                QFile::remove(info);
                *u = {"trash", to};
                return {};
            };
            j.steps << s;
        }
        add(j);
    }
    // On a network share every file costs the server ~0.1 s (measured: 300 files 32 s, and 16 at once no faster), so
    // one rm -rf of a big folder would sit at "0 of 1" for minutes: there each file is its own step ("1023 of 1257").
    // ponytail: per-file steps only on shares; a local rm -rf is fast and 100k steps would just slow it down.
    static void eraseSteps(Job &j, const QString &p) {
        const QFileInfo top(p);
        if (!Folder::onNetwork(p) || !top.isDir() || top.isSymLink()) {
            j.steps << Step{p, {}, "rm", {"-rf", "--", p}};
            return;
        }
        QStringList dirs{p};
        auto gone = [](const QString &f, bool dir) {
            return [f, dir](Act *) -> QString {
                if (dir ? QDir().rmdir(f) : QFile::remove(f)) return {};
                return QFileInfo::exists(f) || QFileInfo(f).isSymLink() ? "Could not delete “" + QFileInfo(f).fileName() + "”" : QString();
            };
        };
        for (QDirIterator it(p, QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System, QDirIterator::Subdirectories); it.hasNext();) {
            const QFileInfo f = it.nextFileInfo();
            if (f.isDir() && !f.isSymLink()) { dirs << f.filePath(); continue; }
            Step s{f.filePath()}; s.work = gone(f.filePath(), false); j.steps << s;
        }
        std::sort(dirs.begin(), dirs.end(), [](const QString &a, const QString &b) { return a.size() > b.size(); });   // deepest first
        for (const QString &d : dirs) { Step s{d}; s.work = gone(d, true); j.steps << s; }
    }
    Q_INVOKABLE void emptyTrash() {
        const QString base = QFileInfo(trashDir()).absolutePath(), home = trashDir();
        plan([base, home](const QSet<QString> &) {   // the home Trash and every mounted drive's; walked on a worker
            Job j;
            j.verb = "Emptying"; j.name = "Trash"; j.where = home; j.items = true; j.noUndo = true;
            for (const QString &t : QStringList{base} + Folder::trashDirs())
                for (const char *sub : {"/files", "/info"})
                    for (const QFileInfo &f : QDir(t + sub).entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System))
                        eraseSteps(j, f.filePath());
            return j;
        });
    }
    // delete permanently (Shift+Delete, or a network share): can't be undone
    Q_INVOKABLE void remove(const QStringList &paths) {
        if (paths.isEmpty()) return;
        if (inArchive(paths[0])) { emit error("An opened archive can’t be changed: extract it first"); return; }
        plan([paths](const QSet<QString> &) {
            Job j;
            j.verb = "Deleting"; j.name = many(paths); j.where = QFileInfo(paths[0]).absolutePath(); j.items = true; j.noUndo = true;
            for (const QString &p : paths) eraseSteps(j, p);
            return j;
        });
    }
    // symbolic links to `paths` in `dest` (a taken name gets " (2)")
    Q_INVOKABLE void link(const QStringList &paths, const QString &dest) {
        if (paths.isEmpty()) return;
        plan([paths, dest](const QSet<QString> &taken) {
            Job j;
            j.verb = "Linking"; j.name = many(paths); j.where = dest; j.items = true;
            QSet<QString> mine = taken;
            for (const QString &p : paths) {
                const QString to = freeName(dest, QFileInfo(p).fileName(), mine);
                mine << to;
                Step s{p, to, "ln", {"-s", "-T", "--", p, to}};
                s.made = true; s.undo = {"remove", to};
                j.steps << s;
            }
            return j;
        });
    }

    // ---------- archives opened like folders: unpacked once into ~/.cache/kaze/archives (read only there) ----------
    static QString archiveRoot() { return cacheDir() + "/archives"; }
    Q_INVOKABLE static bool inArchive(const QString &p) { return p.startsWith(archiveRoot() + "/"); }
    Q_INVOKABLE void browse(const QString &archive) {
        const QString dir = archiveRoot() + "/" + QCryptographicHash::hash((archive + QString::number(QFileInfo(archive).lastModified().toSecsSinceEpoch())).toUtf8(),
                                                                          QCryptographicHash::Md5).toHex().left(12) + "/" + QFileInfo(archive).fileName();
        m_archives.insert(dir, archive);
        if (QFileInfo(dir + "/.").isDir() && !QFileInfo::exists(dir + ".part")) { emit archiveReady(archive, dir); return; }
        QDir().mkpath(dir);
        QFile(dir + ".part").open(QIODevice::WriteOnly);   // gone when complete: a half-unpacked view is unpacked again
        Job j;
        j.verb = "Opening"; j.name = QFileInfo(archive).fileName(); j.where = QFileInfo(archive).absolutePath(); j.archive = archive; j.noUndo = true;
        Step s{archive, dir, "bsdtar", {"-xf", archive, "-C", dir}};
        s.made = true;
        j.steps << s;
        add(j);
    }
    // where an archive view really is: ".../x.zip/inner" for ".../archives/<id>/x.zip/inner" ("" = not in one)
    Q_INVOKABLE QString archiveOf(const QString &p) const {
        for (auto it = m_archives.cbegin(); it != m_archives.cend(); ++it)
            if (p == it.key() || p.startsWith(it.key() + "/")) return it.value() + p.mid(it.key().size());
        return {};
    }
    Q_INVOKABLE QString archiveView(const QString &shown) const {   // the reverse (crumbs)
        for (auto it = m_archives.cbegin(); it != m_archives.cend(); ++it)
            if (shown == it.value() || shown.startsWith(it.value() + "/")) return it.key() + shown.mid(it.value().size());
        return {};
    }

    // ---------- undo ----------
    Q_INVOKABLE QString undo() {
        if (m_undo.isEmpty()) return {};
        const auto [label, acts] = m_undo.takeLast();
        emit undoChanged();
        Job j;
        j.verb = "Undoing"; j.name = label; j.items = true;
        for (int i = acts.size() - 1; i >= 0; --i) {
            const Act a = acts[i];
            if (j.where.isEmpty()) j.where = parent(a.type == "restore" ? a.b : a.a);
            if (a.type == "move") j.steps << Step{a.a, {}, "mv", {"--update=none-fail", "-T", "--", a.a, a.b}};
            else if (a.type == "remove" || (a.type == "trash" && Folder::onNetwork(a.a))) j.steps << Step{a.a, {}, "rm", {"-rf", "--", a.a}};
            else if (a.type == "trash") j.steps << trashStep(a.a);
            else if (a.type == "rmdir") j.steps << Step{a.a, {}, "rmdir", {"--", a.a}};
            else if (a.type == "mode") j.steps << Step{a.a, {}, "chmod", {a.b, "--", a.a}};
            else if (a.type == "restore" || a.type == "rename") {
                Step s{a.a, a.b};
                const bool restore = a.type == "restore";
                s.work = [a, restore](Act *) -> QString {
                    if (QFileInfo::exists(a.b)) return "“" + QFileInfo(a.b).fileName() + "” is there again: not replaced";
                    QDir().mkpath(QFileInfo(a.b).absolutePath());
                    if (!QFile::rename(a.a, a.b)) return "Could not put back “" + QFileInfo(a.b).fileName() + "”";
                    if (restore) QFile::remove(QFileInfo(a.a).absolutePath() + "/../info/" + QFileInfo(a.a).fileName() + ".trashinfo");
                    return {};
                };
                j.steps << s;
            }
        }
        add(j);
        return "Undo " + label;
    }
    void pushUndo(const QString &label, const QList<Act> &acts) {
        if (acts.isEmpty()) return;
        m_undo << qMakePair(label, acts);
        if (m_undo.size() > 30) m_undo.removeFirst();
        emit undoChanged();
    }
    QString undoText() const { return m_undo.isEmpty() ? QString() : m_undo.last().first; }

    // ---------- running ----------
    QVariantList jobs() const {
        QVariantList r;
        auto row = [](const Job &j, bool running) {
            const double total = j.items ? j.steps.size() : j.total, done = j.items ? j.step : j.done;
            const double eta = running && !j.items && total > 0 && j.speed > 0 ? std::max(0.0, (total - done) / j.speed) : -1;
            const QString now = running && j.steps.size() > 1 && j.step < j.steps.size() ? QFileInfo(j.steps[j.step].from).fileName() : QString();
            return QVariantMap{{"id", j.id}, {"verb", j.verb}, {"name", j.name}, {"where", j.where}, {"running", running},
                               {"total", total}, {"done", done}, {"speed", j.items ? 0.0 : j.speed}, {"eta", eta}, {"items", j.items},
                               {"now", now}, {"step", j.step + 1}, {"steps", int(j.steps.size())}, {"paused", j.paused}, {"failed", false}};
        };
        if (m_run.id && !m_run.quiet) r << row(m_run, true);
        for (const Job &j : m_jobs) if (!j.quiet) r << row(j, false);
        for (const QVariantMap &f : m_failed) r << f;
        return r;
    }
    // stop a job: a waiting one is dropped. A running one stops after the item it is on -- a copy / zip / extract / link
    // is killed and its half-made item removed (it never existed before); a move or trash finishes that item first
    // (a move across drives deletes the originals at the end: killing it there would leave both halves incomplete).
    Q_INVOKABLE void cancel(int id) {
        for (int i = 0; i < m_jobs.size(); ++i)
            if (m_jobs[i].id == id) { release(m_jobs[i], 0); m_jobs.removeAt(i); emit jobsChanged(); emit busyChanged(); return; }
        if (m_run.id != id) return;
        m_stopping = true;
        const Step &s = m_run.steps[m_run.step];
        if (m_run.paused) { m_run.paused = false; if (m_proc.state() != QProcess::NotRunning) signalTree(m_proc.processId(), SIGCONT); }
        if (m_proc.state() != QProcess::NotRunning && s.made && !m_run.isMove) m_proc.kill();
        else if (m_proc.state() == QProcess::NotRunning && !m_working) { m_stopping = false; release(m_run, m_run.step); finish("stopped"); }   // paused between items
        emit jobsChanged();
    }
    // pause / go on: the running process (and its children) is stopped with SIGSTOP; work steps finish their item
    Q_INVOKABLE void pause(int id, bool on) {
        if (m_run.id != id || m_run.paused == on) return;
        m_run.paused = on;
        if (m_proc.state() != QProcess::NotRunning) signalTree(m_proc.processId(), on ? SIGSTOP : SIGCONT);
        m_run.speed = 0;
        m_run.clock.restart();
        if (!on) next();
        emit jobsChanged();
    }
    Q_INVOKABLE void dismiss(int id) {
        for (int i = 0; i < m_failed.size(); ++i) if (m_failed[i]["id"].toInt() == id) { m_failed.removeAt(i); emit jobsChanged(); return; }
    }
    static void signalTree(qint64 pid, int sig) {
        if (pid <= 0) return;
        ::kill(pid_t(pid), sig);
        QFile c(QString("/proc/%1/task/%1/children").arg(pid));
        if (c.open(QIODevice::ReadOnly)) for (const QByteArray &k : c.readAll().split(' ')) if (k.toLongLong() > 0) signalTree(k.toLongLong(), sig);
    }
    void next() {
        if (!m_run.id && !m_jobs.isEmpty()) {
            m_run = m_jobs.takeFirst();
            QStringList srcs; QList<int> at;
            for (int i = 0; i < m_run.steps.size(); ++i) if (m_run.steps[i].counts) { srcs << m_run.steps[i].from; at << i; }
            if (m_run.readSide && !m_run.steps.isEmpty()) { srcs = m_run.srcs; }
            if (!m_run.items && !srcs.isEmpty()) {   // the total (and each item's size), counted once on a worker
                const int id = m_run.id;
                const bool read = m_run.readSide;
                bg("jobtotal:" + QString::number(id), [id, srcs, at, read] {
                    QList<qint64> sizes;
                    for (const QString &s : srcs) sizes << bytesIn(s);
                    return [id, sizes, at, read](Fs *fs) {
                        Job &j = fs->m_run;
                        if (j.id != id) return;
                        j.total = 0;
                        for (int i = 0; i < sizes.size(); ++i) { j.total += sizes[i]; if (!read && i < at.size()) j.steps[at[i]].size = sizes[i]; }
                        emit fs->jobsChanged();
                    };
                });
            }
        }
        if (m_run.id && !m_run.paused && !m_working && m_proc.state() == QProcess::NotRunning && m_run.step < m_run.steps.size()) {
            Step &s = m_run.steps[m_run.step];
            m_run.clock.start();
            if (s.work) {
                m_working = true;
                QPointer<Fs> self(this);
                const int id = m_run.id;
                const auto work = s.work;
                QThreadPool::globalInstance()->start([self, id, work] {
                    Act a;
                    const QString e = work(&a);
                    QMetaObject::invokeMethod(qApp, [self, id, e, a] { if (self && self->m_run.id == id) self->stepEnded(e.isEmpty(), e, a); }, Qt::QueuedConnection);
                });
            } else m_proc.start(s.prog, s.args);
        }
        if (m_run.id) { if (!m_tick.isActive()) m_tick.start(); } else m_tick.stop();
        emit busyChanged();
        emit jobsChanged();
    }
    void stepEnded(bool ok, const QString &err, const Act &done = {}) {
        Job &j = m_run;
        if (!j.id) return;
        m_working = false;
        const Step s = j.steps[j.step];
        m_reserved.remove(s.to);
        for (const QString &d : {QFileInfo(s.to).absolutePath(), QFileInfo(s.from).absolutePath()}) if (!d.isEmpty() && d != "/" && d != ".") emit touched(d);
        if (m_stopping) {   // stopped: a half-made item goes, finished ones stay, the rest are skipped
            m_stopping = false;
            if (!ok && s.made && !s.to.isEmpty()) {
                const QString to = s.to;
                QThreadPool::globalInstance()->start([to] {   // on a share this can take long: never on the UI thread
                    const QFileInfo f(to);
                    if (f.isDir() && !f.isSymLink()) QDir(to).removeRecursively(); else QFile::remove(to);
                });
            } else if (ok) { const Act a = s.work ? done : s.undo; if (!a.type.isEmpty()) j.undo << a; }
            release(j, j.step + 1);
            finish("stopped");
            return;
        }
        if (ok) { const Act a = s.work ? done : s.undo; if (!a.type.isEmpty()) j.undo << a; }
        else j.errors << (err.isEmpty() ? "Could not finish “" + QFileInfo(s.from).fileName() + "”" : err.section('\n', 0, 0));
        j.base += s.size >= 0 ? s.size : std::max<qint64>(0, j.done - j.base);
        j.done = j.base;
        if (++j.step < j.steps.size()) { next(); return; }
        finish(j.errors.isEmpty() ? "done" : "failed");
    }
    void finish(const QString &how) {
        const Job j = m_run;
        m_run = {};
        if (!j.undo.isEmpty() && !j.noUndo && j.verb != "Undoing") {
            static const QHash<QString, QString> noun{{"Copying", "Copy"}, {"Moving", "Move"}, {"Moving to Trash", "Trash"}, {"Linking", "Link"},
                                                      {"Compressing", "Compress"}, {"Extracting", "Extract"},
                                                      {"Changing permissions of", "Permissions"}, {"Putting back", "Put Back"},
                                                      {"Renaming", "Rename"}, {"Creating", "New"}};
            pushUndo(noun.value(j.verb, j.verb) + " of “" + j.name + "”", j.undo);
        }
        if (how == "failed" && j.quiet) emit error(j.errors[0]);
        else if (how == "failed") {
            const QString e = j.errors.size() == 1 ? j.errors[0] : j.errors[0] + QString(" (and %1 more)").arg(j.errors.size() - 1);
            m_failed << QVariantMap{{"id", j.id}, {"verb", j.verb}, {"name", j.name}, {"where", j.where}, {"failed", true}, {"error", e},
                                    {"running", false}, {"items", true}, {"total", 0}, {"done", 0}, {"speed", 0}, {"eta", -1}, {"now", ""}, {"paused", false}};
            emit error(e);
        }
        if (!j.archive.isEmpty()) {
            const QString dir = j.steps.value(0).to;
            if (how == "done") { QFile::remove(dir + ".part"); emit archiveReady(j.archive, dir); }
            else QDir(QFileInfo(dir).absolutePath()).removeRecursively();
        }
        emit jobDone(j.verb, j.name, how);
        next();
    }
    // how far the running item is: the bytes its process (and its children: sh -> cp) wrote -- or read, for a zip --
    // from /proc/<pid>/io. Nothing touches the destination (walking a share while copying to it slowed both).
    void measure() {
        Job &j = m_run;
        if (!j.id || j.items || j.paused || m_proc.state() == QProcess::NotRunning) { if (j.id) emit jobsChanged(); return; }
        const QByteArray key = j.readSide ? "rchar: " : "wchar: ";
        std::function<qint64(qint64)> io = [&](qint64 pid) -> qint64 {
            qint64 b = 0;
            QFile f(QString("/proc/%1/io").arg(pid));
            if (f.open(QIODevice::ReadOnly)) for (const QByteArray &l : f.readAll().split('\n')) if (l.startsWith(key)) b = l.mid(key.size()).toLongLong();
            QFile c(QString("/proc/%1/task/%1/children").arg(pid));
            if (c.open(QIODevice::ReadOnly)) for (const QByteArray &k : c.readAll().split(' ')) if (k.toLongLong() > 0) b += io(k.toLongLong());
            return b;
        };
        qint64 b = j.base + io(m_proc.processId());
        if (j.total > 0) b = std::min(b, j.total);
        const double secs = j.clock.restart() / 1000.0;
        if (secs > 0 && b >= j.done) { const double now = (b - j.done) / secs; j.speed = j.speed > 0 ? 0.7 * j.speed + 0.3 * now : now; }
        j.done = b;
        emit jobsChanged();
    }
private:

    QVariantMap m_colors, m_fonts;
    QString m_themeDir;
    QString m_codeStyle;     // ~/.cache/kaze/code.style
    QFileSystemWatcher m_watch;
    QMimeDatabase m_mime;
    QProcess m_proc;
    struct Act { QString type, a, b; };   // the inverse of a finished step: move a->b | remove a | trash a | restore a->b | rename a->b | mode a b
    struct Item { QString from, name; bool dir = false, sameDev = false; int conflict = -1; QString keepBoth; };   // a copy / move, planned
    struct Step {
        QString from, to, prog;   // to = what it makes (made: never existed before -- free names)
        QStringList args;
        qint64 size = -1;         // bytes of `from` (for the progress after it)
        bool made = false, counts = false;   // counts: its bytes are part of the job's total
        Act undo;
        std::function<QString(Act *)> work;   // instead of a process: runs on a worker, returns an error or ""
    };
    struct Job {
        int id = 0;
        QString verb, name, where, dest, archive;
        QStringList srcs;         // what a zip reads (for the total)
        QList<Step> steps;
        QList<Item> plan;         // a copy / move before its conflicts are answered
        QVariantList conflicts;
        QStringList clashes;      // names that differ only in case, going to a case-blind share
        QList<Act> undo;
        bool readSide = false;    // progress = bytes read (a zip writes fewer than it reads)
        bool items = false;       // progress = items done (trash, delete, link)
        bool isMove = false, isCopy = false, net = false, noUndo = false, paused = false;
        bool quiet = false;       // not listed (rename / new on a share): only its error is said
        QStringList errors;
        int step = 0;
        qint64 total = -1, done = 0, base = 0;   // base = bytes of the items already finished
        double speed = 0;         // bytes / s
        QElapsedTimer clock;
    };
    QHash<int, Job> m_ask;     // copies waiting for an answer about taken names
    QList<QVariantMap> m_failed;   // failed jobs stay in the list until dismissed
    QList<QPair<QString, QList<Act>>> m_undo;
    QHash<QString, QString> m_archives;   // archive view folder -> the archive
    bool m_working = false;
    QList<std::function<Job(const QSet<QString> &)>> m_plans;   // copies waiting to be planned (the first is being planned)
    QList<Job> m_jobs;        // waiting
    Job m_run;                // running
    int m_jobId = 0;
    bool m_stopping = false;
    QTimer m_tick;
    QSet<QString> m_reserved;
    QList<PJob> m_pq, m_urgent, m_bgq;
    QSet<QString> m_imgLater;  // pictures queued ahead of time (prefetch): shown ones are made again at the front
    int m_running = 0;
    QSet<QString> m_pending, m_thumbAfterPdf, m_asking;
    QStringList m_offline;
    QVariantMap m_looks;
    QHash<QString, std::shared_ptr<std::atomic_bool>> m_sizing;   // folder counts running, by folder
    int m_sizeRun = 0;
    QThreadPool m_imgPool;     // picture previews (own pool: a big photo folder must not hold up folder reading)
    void loadLooks() {
        QFile f(home() + "/.config/kaze/looks.json");
        if (f.open(QIODevice::ReadOnly)) m_looks = QJsonDocument::fromJson(f.readAll()).object().toVariantMap();
    }
    QTimer m_probeTimer;
};
