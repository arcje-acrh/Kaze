// folder.h -- `Folder`, the list of one folder for the views (replaces Qt.labs FolderListModel, which waits on the UI
// thread while a folder is read: a dead network share froze the window for ~6 s per folder).
// Reading happens on the thread pool; the UI gets the result when it is ready. Sorting is Finder-like: folders first,
// natural order ("file2" before "file10"), case-insensitive. Local folders are watched live; folders on network
// mounts are not (adding an inotify watch there can hang too, and it misses other computers' changes): they are
// read again every 4 s on a worker while shown, and the list only changes when the folder did.
#pragma once
#include <QAbstractListModel>
#include <QCollator>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QProcess>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QPointer>
#include <optional>
#include <QMutex>
#include <QQmlEngine>
#include <QThreadPool>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <algorithm>
#include <atomic>
#include <memory>
#include <sys/stat.h>
#include <unistd.h>

class Folder : public QAbstractListModel {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QUrl folder READ folder WRITE setFolder NOTIFY folderChanged)
    Q_PROPERTY(bool showHidden MEMBER m_hidden WRITE setShowHidden NOTIFY changed)
    Q_PROPERTY(QString sortField MEMBER m_sort WRITE setSortField NOTIFY changed)       // name | time | size | type
    Q_PROPERTY(bool sortReversed MEMBER m_reversed WRITE setSortReversed NOTIFY changed)
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    Q_PROPERTY(bool ready MEMBER m_ready NOTIFY readyChanged)
    Q_PROPERTY(QString error MEMBER m_error NOTIFY readyChanged)
    // search: names containing every word of `query` (any case), in this folder and all below it (hidden ones only
    // with showHidden; network shares and other drives are not entered). Results stream in while it walks.
    Q_PROPERTY(QString query MEMBER m_query WRITE setQuery NOTIFY queryChanged)
    // search everywhere (the whole computer, from plocate's index) instead of this folder and below
    Q_PROPERTY(bool everywhere MEMBER m_everywhere WRITE setEverywhere NOTIFY queryChanged)

public:
    struct Entry { QString name, path, suffix; bool dir; qint64 size; QDateTime modified; };
    // What the folder reads learned about files on network shares. A share busy with a copy makes every stat() wait
    // for the copy's data to be flushed (measured: 4.5 s for one stat, 21 s for one listing, Nautilus froze too), so
    // the UI thread never asks the share: it uses this (Fs::look).
    struct Known { bool dir = false; qint64 size = 0; QDateTime modified; };
    static inline QMutex s_lock;
    static inline QHash<QString, Known> s_known;
    static std::optional<Known> known(const QString &p) { QMutexLocker l(&s_lock); auto it = s_known.constFind(p); if (it == s_known.cend()) return std::nullopt; return *it; }
    // the mount point p is on (longest match; "/" at least) -- no disk access
    static QString mountOf(const QString &p) {
        QFile m("/proc/self/mounts");
        QString best = "/";
        if (!m.open(QIODevice::ReadOnly)) return best;
        for (const QByteArray &line : m.readAll().split('\n')) {
            const auto f = line.split(' ');
            if (f.size() < 3 || f[2] == "autofs") continue;
            const QString mp = QString::fromUtf8(f[1]).replace("\\040", " ");
            if ((p == mp || p.startsWith(mp + "/")) && mp.size() > best.size()) best = mp;
        }
        return best;
    }
    enum Role { Name = Qt::UserRole + 1, Path, Suffix, IsDir, Size, Modified };

    Folder() {
        m_reload.setSingleShot(true);
        m_reload.setInterval(250);
        connect(&m_reload, &QTimer::timeout, this, [this] { load(); });
        connect(&m_watch, &QFileSystemWatcher::directoryChanged, &m_reload, qOverload<>(&QTimer::start));
        m_poll.setInterval(4000);
        connect(&m_poll, &QTimer::timeout, this, [this] { if (m_query.isEmpty() && m_ready && !m_polling) load(true); });   // one look at a time (a dead share answers slowly)
    }

    QUrl folder() const { return QUrl::fromLocalFile(m_path); }
    void setFolder(const QUrl &u) {
        const QString p = u.toLocalFile();
        if (p == m_path) return;
        if (!m_watch.directories().isEmpty()) m_watch.removePaths(m_watch.directories());
        m_path = p;
        beginResetModel(); m_shown.clear(); m_all.clear(); endResetModel();
        emit countChanged(); emit folderChanged();
        if (!onNetwork(p)) { m_watch.addPath(p); m_poll.stop(); } else m_poll.start();
        load();
    }
    void setQuery(const QString &q) {
        if (q == m_query) return;
        m_query = q;
        emit queryChanged();
        beginResetModel(); m_shown.clear(); m_all.clear(); endResetModel();
        emit countChanged();
        load();
    }
    void setEverywhere(bool v) {
        if (v == m_everywhere) return;
        m_everywhere = v;
        emit queryChanged();
        if (!m_query.isEmpty()) { beginResetModel(); m_shown.clear(); m_all.clear(); endResetModel(); emit countChanged(); load(); }
    }
    void setShowHidden(bool v) { if (v != m_hidden) { m_hidden = v; emit changed(); if (m_query.isEmpty()) arrange(); else load(); } }
    void setSortField(const QString &v) { if (v != m_sort) { m_sort = v; emit changed(); arrange(); } }
    void setSortReversed(bool v) { if (v != m_reversed) { m_reversed = v; emit changed(); arrange(); } }

    int rowCount(const QModelIndex & = {}) const override { return m_shown.size(); }
    QHash<int, QByteArray> roleNames() const override {
        return {{Name, "fileName"}, {Path, "filePath"}, {Suffix, "fileSuffix"}, {IsDir, "fileIsDir"}, {Size, "fileSize"}, {Modified, "fileModified"}};
    }
    QVariant data(const QModelIndex &i, int role) const override {
        if (i.row() < 0 || i.row() >= m_shown.size()) return {};
        const Entry &e = m_shown[i.row()];
        switch (role) {
        case Name: return e.name;
        case Path: return e.path;
        case Suffix: return e.suffix;
        case IsDir: return e.dir;
        case Size: return e.size;
        case Modified: return e.modified;
        }
        return {};
    }
    // same calls the views used on FolderListModel
    Q_INVOKABLE QVariant get(int i, const QString &role) const { return data(index(i), roleNames().key(role.toUtf8())); }
    Q_INVOKABLE int indexOf(const QString &path) const {
        for (int i = 0; i < m_shown.size(); ++i) if (m_shown[i].path == path) return i;
        return -1;
    }
    Q_INVOKABLE void refresh() { load(); }

    // mount points of network shares (cifs / nfs / sshfs / rclone, and the automounts under home that stand for them)
    static QSet<QString> netMounts() {
        QSet<QString> r;
        QFile m("/proc/self/mounts");
        if (!m.open(QIODevice::ReadOnly)) return r;
        static const QStringList net = {"cifs", "smb3", "nfs", "nfs4", "fuse.sshfs", "fuse.rclone"};
        for (const QByteArray &line : m.readAll().split('\n')) {
            const auto f = line.split(' ');
            if (f.size() < 3) continue;
            const QString mp = QString::fromUtf8(f[1]).replace("\\040", " ");
            if (net.contains(QString::fromUtf8(f[2])) || (f[2] == "autofs" && mp.startsWith(QDir::homePath() + "/"))) r << mp;
        }
        return r;
    }
    // the Trash of every other mounted drive (freedesktop: <drive>/.Trash-<uid> or <drive>/.Trash/<uid>): files moved to
    // the Trash on a USB disk or a share stay on that drive. The Trash view lists them with the home Trash.
    static QStringList trashDirs() {
        QStringList r;
        QFile m("/proc/self/mounts");
        if (!m.open(QIODevice::ReadOnly)) return r;
        static const QStringList skip = {"autofs", "proc", "sysfs", "tmpfs", "devtmpfs", "cgroup2", "overlay", "squashfs"};
        const QString uid = QString::number(::getuid());
        for (const QByteArray &line : m.readAll().split('\n')) {
            const auto f = line.split(' ');
            if (f.size() < 3 || skip.contains(QString::fromUtf8(f[2]))) continue;
            const QString mp = QString::fromUtf8(f[1]).replace("\\040", " ");
            if (!(mp.startsWith(QDir::homePath() + "/") || mp.startsWith("/run/media/") || mp.startsWith("/media/") || mp.startsWith("/mnt/"))) continue;
            for (const QString &t : {mp + "/.Trash-" + uid, mp + "/.Trash/" + uid}) if (QFileInfo(t + "/files").isDir()) r << t;
        }
        return r;
    }
    // is `p` on a network mount (cifs / nfs / sshfs / an automount under home)? Longest mount point wins.
    static bool onNetwork(const QString &p) {
        QFile m("/proc/self/mounts");
        if (!m.open(QIODevice::ReadOnly)) return false;
        QString best, bestType;
        for (const QByteArray &line : m.readAll().split('\n')) {
            const auto f = line.split(' ');
            if (f.size() < 3) continue;
            const QString mp = QString::fromUtf8(f[1]).replace("\\040", " ");
            if ((p == mp || p.startsWith(mp == "/" ? mp : mp + "/")) && mp.size() >= best.size()) { best = mp; bestType = QString::fromUtf8(f[2]); }
        }
        static const QStringList net = {"cifs", "smb3", "nfs", "nfs4", "fuse.sshfs", "fuse.rclone", "autofs"};
        return net.contains(bestType);
    }

signals:
    void folderChanged();
    void changed();
    void countChanged();
    void readyChanged();
    void queryChanged();

private:
    void load(bool quiet = false) {   // quiet: a look for changes (network folders), the list stays as it is meanwhile
        const QString path = m_path;
        const int gen = ++m_gen;
        *m_live = gen;
        if (m_ready && !quiet) { m_ready = false; emit readyChanged(); }
        if (quiet) m_polling = true;
        QPointer<Folder> self(this);
        if (!m_query.isEmpty() && !path.isEmpty()) { if (m_everywhere) locate(gen); else search(path, gen); return; }
        QThreadPool::globalInstance()->start([self, path, gen, quiet] {
            QList<Entry> out;
            QString err;
            QDir d(path);
            const QSet<QString> shares = netMounts();   // network shares are in the sidebar, not in folder lists
            if (!d.exists()) err = "This folder can’t be opened";
            else {
                const auto list = d.entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
                if (list.isEmpty() && !d.isReadable()) err = "You don’t have permission to see this folder";
                for (const QFileInfo &f : list)
                    if (!shares.contains(f.filePath())) out.append(entry(f));
                if (onNetwork(path)) {
                    QMutexLocker l(&s_lock);
                    s_known.insert(path, {true, 0, {}});
                    for (const Entry &e : out) s_known.insert(e.path, {e.dir, e.size, e.modified});
                }
                if (path == QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/Trash/files")
                    for (const QString &t : trashDirs())
                        for (const QFileInfo &f : QDir(t + "/files").entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System)) out.append(entry(f));
            }
            // back on the UI thread (posted to the app object, which outlives every Folder)
            QMetaObject::invokeMethod(qApp, [self, gen, out, err, quiet] {
                if (self && quiet) self->m_polling = false;
                if (!self || self->m_gen != gen) return;   // gone, or a newer read was started
                if (quiet && err == self->m_error && out.size() == self->m_all.size()
                    && std::equal(out.begin(), out.end(), self->m_all.begin(), [](const Entry &a, const Entry &b) {
                           return a.name == b.name && a.size == b.size && a.modified == b.modified && a.dir == b.dir; })) return;   // nothing changed
                self->m_all = out;
                self->m_error = err;
                self->arrange();
                self->m_ready = true;
                emit self->readyChanged();
            }, Qt::QueuedConnection);
        });
    }
    static Entry entry(const QFileInfo &f) { return {f.fileName(), f.filePath(), f.isDir() ? QString() : f.completeSuffix(), f.isDir(), f.size(), f.lastModified()}; }
    void search(const QString &root, int gen) {
        QPointer<Folder> self(this);
        const auto live = m_live;
        const QStringList words = m_query.toLower().split(' ', Qt::SkipEmptyParts);
        const bool hidden = m_hidden;
        QThreadPool::globalInstance()->start([self, live, gen, root, words, hidden] {
            QList<Entry> out;
            const QSet<QString> shares = netMounts();
            const auto dev = [](const QString &p) { struct stat s; return ::stat(QFile::encodeName(p).constData(), &s) ? dev_t(0) : s.st_dev; };
            const dev_t home = dev(root);
            QStringList todo{root};
            QElapsedTimer t; t.start();
            auto post = [&](bool last) {
                QMetaObject::invokeMethod(qApp, [self, gen, out, last] {
                    if (!self || self->m_gen != gen) return;
                    self->m_all = out; self->m_error.clear(); self->arrange();
                    if (last) { self->m_ready = true; emit self->readyChanged(); }
                }, Qt::QueuedConnection);
            };
            // ponytail: stops at 2000 matches; a full index (locate / tracker) if whole-disk search is ever wanted
            while (!todo.isEmpty() && *live == gen && out.size() < 2000) {
                const QString d = todo.takeFirst();   // breadth first: near matches come before deep ones
                const auto list = QDir(d).entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | (hidden ? QDir::Hidden : QDir::Filters()) | QDir::System);
                for (const QFileInfo &f : list) {
                    const QString n = f.fileName().toLower();
                    if (std::all_of(words.begin(), words.end(), [&](const QString &w) { return n.contains(w); })) out.append(entry(f));
                    if (f.isDir() && !f.isSymLink() && !shares.contains(f.filePath()) && dev(f.filePath()) == home) todo << f.filePath();
                }
                if (t.elapsed() > 300) { post(false); t.restart(); }
            }
            if (*live == gen) post(true);
        });
    }
    // everywhere: names holding every word, from plocate's index (updated daily by plocate-updatedb.timer; network
    // shares are not in it). Only what still exists and that you may see; hidden paths only with hidden files shown.
    void locate(int gen) {
        QPointer<Folder> self(this);
        const QStringList words = m_query.split(' ', Qt::SkipEmptyParts);
        const bool hidden = m_hidden;
        QThreadPool::globalInstance()->start([self, gen, words, hidden] {
            QList<Entry> out;
            QString err;
            QProcess p;
            p.start("plocate", QStringList{"-i", "-b", "-l", "20000", "--"} + words);
            if (!p.waitForStarted(3000)) err = "Searching everywhere needs plocate (sudo pacman -S plocate)";
            else {
                p.waitForFinished(15000);
                if (p.exitCode() > 1) err = QString::fromUtf8(p.readAllStandardError()).trimmed().section('\n', 0, 0);
                for (const QByteArray &l : p.readAllStandardOutput().split('\n')) {
                    if (l.isEmpty()) continue;
                    const QString f = QString::fromUtf8(l);
                    if (!hidden && f.contains("/.")) continue;
                    const QFileInfo i(f);
                    if (!i.exists() && !i.isSymLink()) continue;   // gone since the index was made
                    out.append(entry(i));
                    if (out.size() >= 2000) break;
                }
            }
            QMetaObject::invokeMethod(qApp, [self, gen, out, err] {
                if (!self || self->m_gen != gen) return;
                self->m_all = out; self->m_error = err; self->arrange();
                self->m_ready = true; emit self->readyChanged();
            }, Qt::QueuedConnection);
        });
    }
    void arrange() {
        QList<Entry> v;
        for (const Entry &e : m_all) if (m_hidden || !e.name.startsWith('.')) v.append(e);
        QCollator c;
        c.setNumericMode(true);
        c.setCaseSensitivity(Qt::CaseInsensitive);
        const QString s = m_sort;
        std::stable_sort(v.begin(), v.end(), [&](const Entry &a, const Entry &b) {
            if (a.dir != b.dir) return a.dir;                       // folders first, in either direction
            int r = 0;
            if (s == "time") r = a.modified < b.modified ? 1 : a.modified > b.modified ? -1 : 0;   // newest first
            else if (s == "size") r = a.size < b.size ? 1 : a.size > b.size ? -1 : 0;             // biggest first
            else if (s == "type") r = c.compare(a.suffix, b.suffix);
            if (!r) r = c.compare(a.name, b.name);
            return m_reversed ? r > 0 : r < 0;
        });
        beginResetModel();
        m_shown = v;
        endResetModel();
        emit countChanged();
    }

    QString m_path, m_sort = "name", m_error, m_query;
    std::shared_ptr<std::atomic_int> m_live = std::make_shared<std::atomic_int>(0);   // the walk to keep (a newer search stops the old one)
    bool m_hidden = false, m_reversed = false, m_ready = false, m_polling = false, m_everywhere = false;
    int m_gen = 0;
    QList<Entry> m_all, m_shown;
    QFileSystemWatcher m_watch;
    QTimer m_reload, m_poll;
};
