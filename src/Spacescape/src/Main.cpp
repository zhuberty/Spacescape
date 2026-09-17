/* 
This source file is part of Spacescape
For the latest info, see http://alexcpeterson.com/spacescape

"He determines the number of the stars and calls them each by name. "
Psalm 147:4

The MIT License

Copyright (c) 2010 Alex Peterson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QTextStream>
#include <QDateTime>
#include <QCoreApplication>
#include "QtSpacescapeMainWindow.h"

// Write a line to startup.log (next to the exe) so it's visible even on early crash
static void startupLog(const QString& msg) {
    QFile f(QApplication::applicationDirPath() + "/startup.log");
    f.open(QIODevice::Append | QIODevice::Text);
    QTextStream ts(&f);
    ts << QDateTime::currentDateTime().toString("hh:mm:ss.zzz") << "  " << msg << "\n";
}

int main(int argc, char *argv[]) {
#ifdef Q_OS_MAC
    QDir dir(argv[0]);
    dir.cdUp();
    dir.cdUp();
    dir.cd("PlugIns");
    QApplication::setLibraryPaths(QStringList(dir.absolutePath()));
    printf("after change, libraryPaths=(%s)\n", QCoreApplication::libraryPaths().join(",").toUtf8().data());
#endif

    QApplication app(argc, argv);

    // Clear previous log and write initial diagnostics
    {
        QFile f(QApplication::applicationDirPath() + "/startup.log");
        f.open(QIODevice::WriteOnly | QIODevice::Text); // truncate
    }
    startupLog("=== Spacescape startup ===");
    startupLog("applicationDirPath : " + QApplication::applicationDirPath());
    startupLog("CWD at entry       : " + QDir::currentPath());
    startupLog("Qt library paths   : " + QApplication::libraryPaths().join("; "));

    // Log Qt runtime DLL versions by checking file timestamps of known DLLs
#ifdef Q_OS_WIN
    QString appDir = QApplication::applicationDirPath();
    for (const QString& dll : QStringList{"Qt5Core.dll", "Qt5Gui.dll", "Qt5Widgets.dll", "Qt5Svg.dll"}) {
        QFileInfo fi(appDir + "/" + dll);
        if (fi.exists())
            startupLog(dll + " last modified: " + fi.lastModified().toString(Qt::ISODate)
                       + "  size: " + QString::number(fi.size()) + " bytes");
        else
            startupLog(dll + " : NOT FOUND");
    }
#endif

    startupLog("--- Creating main window ---");

    QtSpacescapeMainWindow w;
    w.show();

    startupLog("--- Entering event loop ---");
    return app.exec();
}
