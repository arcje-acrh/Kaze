// Kaze -- the Udiksa file manager. `kaze [folder | file | file:// url]`: a file opens its folder with it selected.
// KAZE_SHOT=<png> renders the window once and saves it (README screenshots; run with QT_QPA_PLATFORM=offscreen).
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <memory>
#include <QQuickWindow>
#include <QThreadPool>
#include <QTimer>
#include <unistd.h>
#include <QtQml/qqmlextensionplugin.h>
#include "fs.h"
#include "dbus.h"

Q_IMPORT_QML_PLUGIN(KazePlugin)

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--dbus-service")) return runFileManager1(argc, argv);
    QString props;   // kaze --properties <path>: its folder, it selected, Properties open (FileManager1.ShowItemProperties)
    if (argc > 2 && !strcmp(argv[1], "--properties")) { props = QString::fromLocal8Bit(argv[2]); argv[1] = argv[2]; argc = 2; }
    QQuickWindow::setDefaultAlphaBuffer(true);   // see-through sidebar (Hyprland blurs behind it)
    QGuiApplication app(argc, argv);
    app.setApplicationName("kaze");
    app.setDesktopFileName("kaze");   // Wayland app id = window class "kaze"

    QString start = argc > 1 ? QString::fromLocal8Bit(argv[1]) : QDir::homePath();
    if (!props.isEmpty()) Fs::startProps = QDir::cleanPath(QDir(props).absolutePath());
    if (start.startsWith("file:")) start = QUrl(start).toLocalFile();
    start = QDir::cleanPath(QDir(start).absolutePath());   // no trailing "/": stat("share/") would wake an automount
    QFileInfo f(start);
    if (Folder::onNetwork(start)) {
        // ponytail: no stat on a share (a busy one answers in seconds): a name with an extension is a file to select
        if (f.suffix().isEmpty()) Fs::startDir = start;
        else { Fs::startDir = f.absolutePath(); Fs::startSelect = start; }
    } else {
        if (!f.exists()) f = QFileInfo(QDir::homePath());
        if (f.isDir()) Fs::startDir = f.absoluteFilePath();
        else { Fs::startDir = f.absolutePath(); Fs::startSelect = f.absoluteFilePath(); }
    }

    int code;
    {
    // A plain QQmlEngine, not QQmlApplicationEngine: that one installs a file selector which stats every Image's file
    // on the UI thread before loading it (even an asynchronous one) -- 13 s on a share busy with a copy, and it can't
    // be taken out afterwards. Kaze has no "+selector" variants to pick.
    QQmlEngine engine;
    engine.addImageProvider("kaze", new NetImages);
    QObject::connect(&engine, &QQmlEngine::quit, &app, &QCoreApplication::quit, Qt::QueuedConnection);
    QObject::connect(&engine, &QQmlEngine::exit, &app, &QCoreApplication::exit, Qt::QueuedConnection);
    QQmlComponent main(&engine);
    main.loadFromModule("Kaze", "Main");
    std::unique_ptr<QObject> root(main.create());
    if (!root) { for (const auto &e : main.errors()) qWarning("%s", qPrintable(e.toString())); _exit(1); }

    if (const QString shot = qEnvironmentVariable("KAZE_SHOT"); !shot.isEmpty())
        QTimer::singleShot(qEnvironmentVariableIntValue("KAZE_SHOT_MS") ?: 1500, &app, [&, shot] {
            auto *w = qobject_cast<QQuickWindow *>(root.get());
            if (!w || !w->grabWindow().save(shot)) qWarning("kaze: could not save %s", qPrintable(shot));
            app.quit();
        });
    code = app.exec();
    }   // the engine (and the Settings it writes) is gone here
    // Leave without waiting for worker threads: one may be stuck for many seconds on a network share whose server
    // is down, and there is nothing left for it to report to.
    QThreadPool::globalInstance()->clear();
    fflush(nullptr);
    _exit(code);
}
