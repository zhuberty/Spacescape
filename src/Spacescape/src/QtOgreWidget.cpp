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
#include "QtOgreWidget.h"
#include <QApplication>
#if defined(Q_WS_MAC)
//#import <Cocoa/Cocoa.h>
//#include <OgreOSXContext.h>
#include <AGL/agl.h>
#elif !defined(Q_WS_WIN)
#include <QX11Info>
#endif

#include <QDir>
#include <QFile>
#include <QTextStream>
#include <QDateTime>
#include <QFileInfo>

// Append a diagnostic line to startup.log
static void ogreWidgetLog(const QString& msg) {
    QFile f(QApplication::applicationDirPath() + "/startup.log");
    f.open(QIODevice::Append | QIODevice::Text);
    QTextStream ts(&f);
    ts << QDateTime::currentDateTime().toString("hh:mm:ss.zzz") << "  [OgreWidget] " << msg << "\n";
}

Ogre::Root * QtOgreWidget::mOgreRoot = NULL;

/** Constructor
@param parent
*/
QtOgreWidget::QtOgreWidget(QWidget* parent, Qt::WindowFlags f) : QWidget(parent) {
//QtOgreWidget::QtOgreWidget(QWidget *parent) : QWidget(parent) {
	setAttribute(Qt::WA_PaintOnScreen);
	setAttribute(Qt::WA_NoBackground);
    setAttribute(Qt::WA_NativeWindow);
	
	mRenderWindow = NULL;
	mOgreRoot = NULL;
}

/** Destructor
*/
QtOgreWidget::~QtOgreWidget(void) {
}

/** Configure Ogre
*/
void QtOgreWidget::configure(void) {
	if (mOgreRoot)
		return;

	ogreWidgetLog("configure() entered");
	ogreWidgetLog("CWD before setCurrent : " + QDir::currentPath());
	ogreWidgetLog("applicationDirPath    : " + QApplication::applicationDirPath());
	
#ifdef WIN32
	// Set the CWD to the directory containing the executable (i.e. dist/).
	// Config files (plugins.cfg, app.cfg, resources.cfg) are looked up as
	// "../plugins.cfg" etc., which resolves one level above CWD — the repo root —
	// where build.ps1 generates them with absolute PluginFolder paths.
	QString path = QApplication::applicationDirPath();
	QDir::setCurrent(path.toStdString().c_str());
	ogreWidgetLog("CWD set to exe dir    : " + QDir::currentPath());
#endif

#if defined(Q_OS_UNIX)
	ogreWidgetLog("Creating Ogre::Root with plugins.cfg / app.cfg / app.log (UNIX)");
        mOgreRoot = new Ogre::Root("plugins.cfg", "app.cfg", "app.log");
#else
    #ifdef _DEBUG
	ogreWidgetLog("Creating Ogre::Root with ../plugins_d.cfg / ../app.cfg / ../app.log (Win DEBUG)");
	{
		QFileInfo pf(QDir::currentPath() + "/../plugins_d.cfg");
		ogreWidgetLog("  plugins_d.cfg exists: " + QString(pf.exists() ? "YES" : "NO") + "  path: " + pf.absoluteFilePath());
	}
    mOgreRoot = new Ogre::Root(
        QString("../plugins_d.cfg").toStdString(), 
        QString("../app.cfg").toStdString(), 
        QString("../app.log").toStdString()
    );
    #else
	ogreWidgetLog("Creating Ogre::Root with ../plugins.cfg / ../app.cfg / ../app.log (Win Release)");
	{
		QString resolvedPlugins = QDir(QDir::currentPath()).filePath("../plugins.cfg");
		QFileInfo pf(resolvedPlugins);
		ogreWidgetLog("  plugins.cfg exists: " + QString(pf.exists() ? "YES" : "NO") + "  path: " + pf.absoluteFilePath());
		QFileInfo af(QDir(QDir::currentPath()).filePath("../app.cfg"));
		ogreWidgetLog("  app.cfg exists    : " + QString(af.exists() ? "YES" : "NO") + "  path: " + af.absoluteFilePath());
	}
    mOgreRoot = new Ogre::Root(
        QString("../plugins.cfg").toStdString(), 
        QString("../app.cfg").toStdString(), 
        QString("../app.log").toStdString()
    );
    #endif
#endif
	ogreWidgetLog("Ogre::Root created successfully - plugins loaded");
	if (!mOgreRoot->restoreConfig()) {
        Ogre::RenderSystem *renderSystem = mOgreRoot->getRenderSystemByName("OpenGL Rendering Subsystem");
        OgreAssert(renderSystem, "OpenGL RenderSystem must be available");
		
		mOgreRoot->setRenderSystem(renderSystem);
		QString dimensions = QString("%1x%2").arg(width()).arg(height());
		renderSystem->setConfigOption("Video Mode", dimensions.toStdString());
		
		// initialize without creating window
		mOgreRoot->getRenderSystem()->setConfigOption("Full Screen", "No");
		mOgreRoot->saveConfig();
	}
	mOgreRoot->initialise(false);
	ogreWidgetLog("Ogre::Root::initialise(false) completed - render system ready");
}

/** Create the Ogre render window
*/
void QtOgreWidget::createRenderWindow(void) {
	Ogre::NameValuePairList params;
	
	if (mRenderWindow)
		return;
	if (!mOgreRoot)
		configure();
	
#if defined(Q_WS_MAC) || defined(Q_WS_WIN)
	params["externalWindowHandle"] = Ogre::StringConverter::toString((size_t)winId());
#else
    QX11Info info = x11Info();
	Ogre::String winHandle;
	winHandle  = Ogre::StringConverter::toString((unsigned long)(info.display()));
	winHandle += ":";
	winHandle += Ogre::StringConverter::toString((unsigned int)(info.screen()));
	winHandle += ":";
	winHandle += Ogre::StringConverter::toString((unsigned long)(this->parentWidget()->winId()));
	params["parentWindowHandle"] = winHandle;

#endif
	mRenderWindow = mOgreRoot->createRenderWindow("View" + Ogre::StringConverter::toString((unsigned long) this),
			width(), height(), false, &params);
	
#if defined(Q_WS_MAC)
	// store context for hack
//	Ogre::OSXContext *context;
//	mRenderWindow->getCustomAttribute("GLCONTEXT", &context);
//	context->setCurrent();
	mAglContext = aglGetCurrentContext();
	resizeRenderWindow();
#endif
	
	// take over ogre window
#if !defined(Q_WS_MAC) && !defined(Q_WS_WIN)
	WId ogreWinId = 0x0;
	mRenderWindow->getCustomAttribute("WINDOW", &ogreWinId);
	assert(ogreWinId);
	create(ogreWinId);
#endif
}

/** Give the minimum size for this widget
@return the minimum size for this widget
*/
QSize QtOgreWidget::minimumSizeHint(void) const {
	return QSize(50, 50);
}

/** Handle a paint event (just render again, if needed create render window)
@param e The event data
*/
void QtOgreWidget::paintEvent(QPaintEvent *) {
	if (!mRenderWindow)
		createRenderWindow();
	
	update();
}

/** Handle a resize event (pass it along to the render window)
@param e The event data
*/
void QtOgreWidget::resizeEvent(QResizeEvent *) {
	if (mRenderWindow)
		resizeRenderWindow();
}

/** Resize the render window (when the widget was resized)
*/
void QtOgreWidget::resizeRenderWindow(void) {
	if (!mRenderWindow)
		return;
	
#if !defined(Q_WS_MAC)
	mRenderWindow->resize(width(), height());
	mRenderWindow->windowMovedOrResized();
#else
	GLint bufferRect[4];
	HIViewRef mView = HIViewRef(winId());
	
	mRenderWindow->windowMovedOrResized();
	
	// reposition our drawing region
	HIRect viewBounds, winBounds;
	HIViewGetBounds(mView, &viewBounds);
	HIViewRef root = HIViewGetRoot(HIViewGetWindow(mView));
	HIViewRef content_root;
	HIViewFindByID(root, kHIViewWindowContentID, &content_root);
	
	HIViewGetBounds(content_root, &winBounds);
	HIViewConvertRect(&viewBounds, mView, content_root);
	
	bufferRect[0] = x();
	bufferRect[1] = GLint((winBounds.size.height) - (viewBounds.origin.y + viewBounds.size.height));
	bufferRect[2] = width();
	bufferRect[3] = height();
	
	aglSetInteger(mAglContext, AGL_BUFFER_RECT, bufferRect);
	aglEnable(mAglContext, AGL_BUFFER_RECT);
#endif
}

/** Update the Ogre render window
*/
void QtOgreWidget::update(void) {
	if (mRenderWindow && this->isEnabled()) {
		mOgreRoot->_fireFrameStarted();
		mRenderWindow->update();
		mOgreRoot->_fireFrameEnded();
	}
}
