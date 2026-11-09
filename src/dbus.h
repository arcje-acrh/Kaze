// dbus.h -- org.freedesktop.FileManager1: what browsers, editors and other apps call for "Show in folder" / "Open
// containing folder". `kaze --dbus-service` (started by D-Bus on demand, see tools/org.freedesktop.FileManager1.service)
// answers each call with an ordinary Kaze window: ShowItems = the item's folder with it selected, ShowFolders = the
// folder, ShowItemProperties = that window with Properties open. It has no window itself and goes after 30 s idle.
#pragma once
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusError>
#include <QDir>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTimer>
#include <QUrl>

class FileManager1 : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.FileManager1")
public:
    FileManager1() { m_idle.setSingleShot(true); m_idle.setInterval(30000); connect(&m_idle, &QTimer::timeout, qApp, &QCoreApplication::quit); m_idle.start(); }
public slots:
    void ShowFolders(const QStringList &uris, const QString &startupId) { for (const QString &u : uris) open({path(u)}, startupId); }
    void ShowItems(const QStringList &uris, const QString &startupId) {
        QStringList seen;   // ponytail: one window per folder, the first item of it selected
        for (const QString &u : uris) {
            const QString p = path(u), d = QFileInfo(p).absolutePath();
            if (!seen.contains(d)) { seen << d; open({p}, startupId); }
        }
    }
    void ShowItemProperties(const QStringList &uris, const QString &startupId) { for (const QString &u : uris) open({"--properties", path(u)}, startupId); }
private:
    static QString path(const QString &u) { const QUrl url(u); return url.isLocalFile() ? url.toLocalFile() : u; }
    void open(const QStringList &args, const QString &startupId) {
        QProcess p;
        p.setProgram(QCoreApplication::applicationFilePath());
        p.setArguments(args);
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        if (!startupId.isEmpty()) env.insert("XDG_ACTIVATION_TOKEN", startupId);   // lets the new window take the focus
        p.setProcessEnvironment(env);
        p.startDetached();
        m_idle.start();
    }
    QTimer m_idle;
};

inline int runFileManager1(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    FileManager1 fm;
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.registerObject("/org/freedesktop/FileManager1", &fm, QDBusConnection::ExportAllSlots)
        || !bus.registerService("org.freedesktop.FileManager1")) {
        qWarning("kaze: org.freedesktop.FileManager1 is taken (%s)", qPrintable(bus.lastError().message()));
        return 1;
    }
    return app.exec();
}
