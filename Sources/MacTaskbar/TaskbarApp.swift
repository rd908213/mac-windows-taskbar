import SwiftUI
import AppKit

typealias CGSMainConnectionIDType = @convention(c) () -> CInt
typealias CGSSetWindowListStrutType = @convention(c) (CInt, UnsafePointer<CInt>, Int, CInt, CInt, CInt, CInt) -> CInt

@main
struct TaskbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panels: [NSPanel] = []
    var windowGuard: WindowGuard?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Hide from Dock
        
        setupPanels()
        windowGuard = WindowGuard()
        
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    
    @objc func screensChanged() {
        setupPanels()
        // Re-constrain all windows for new screen geometry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.windowGuard?.constrainAllWindows()
        }
    }
    
    func setupPanels() {
        for panel in panels {
            panel.close()
        }
        panels.removeAll()
        
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 48),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            
            let hostingView = NSHostingView(rootView: TaskbarView())
            panel.contentView = hostingView
            
            panel.orderFront(nil)
            
            if let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) {
                if let symCGSMain = dlsym(handle, "CGSMainConnectionID"),
                   let symCGSStrut = dlsym(handle, "CGSSetWindowListStrut") {
                    let CGSMainConnectionID = unsafeBitCast(symCGSMain, to: CGSMainConnectionIDType.self)
                    let CGSSetWindowListStrut = unsafeBitCast(symCGSStrut, to: CGSSetWindowListStrutType.self)
                    
                    let cid = CGSMainConnectionID()
                    var wid = CInt(panel.windowNumber)
                    _ = CGSSetWindowListStrut(cid, &wid, 1, 0, 0, 0, 48)
                }
                dlclose(handle)
            }
            
            panels.append(panel)
        }
    }
}
