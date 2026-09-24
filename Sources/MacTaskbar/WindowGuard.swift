import AppKit
import ApplicationServices

/// Monitors all application windows and prevents them from overlapping the taskbar.
/// Uses the Accessibility API to observe window moved/resized notifications and
/// constrains windows so they don't extend into the reserved taskbar area.
class WindowGuard {
    static let taskbarHeight: CGFloat = 48
    
    private var observers: [pid_t: AXObserver] = [:]
    private var trackedElements: [pid_t: [AXUIElement]] = [:]
    
    init() {
        // Observe app launches and terminations
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        
        // Start watching all currently running apps
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            watchApp(pid: app.processIdentifier)
        }
        
        // Do an initial pass to fix any windows that are already wrong
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.constrainAllWindows()
        }
    }
    
    deinit {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        trackedElements.removeAll()
    }
    
    // MARK: - App lifecycle
    
    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        // Delay slightly to let the app create its windows
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.watchApp(pid: pid)
        }
    }
    
    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        unwatchApp(pid: app.processIdentifier)
    }
    
    // MARK: - AXObserver setup
    
    private func watchApp(pid: pid_t) {
        guard observers[pid] == nil else { return }
        
        var observer: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &observer)
        guard result == .success, let observer = observer else { return }
        
        let appElement = AXUIElementCreateApplication(pid)
        
        // Watch for window-level notifications on the app element
        let notifications: [String] = [
            kAXWindowResizedNotification,
            kAXWindowCreatedNotification,
        ]
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in notifications {
            AXObserverAddNotification(observer, appElement, note as CFString, refcon)
        }
        
        // Also watch existing windows for resize (maximize detection)
        if let windows = getWindows(for: appElement) {
            trackedElements[pid] = windows
            for window in windows {
                AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, refcon)
            }
        }
        
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }
    
    private func unwatchApp(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        trackedElements.removeValue(forKey: pid)
    }
    
    // MARK: - Window constraining
    
    /// Called from the AXObserver callback when a window is moved, resized, or created.
    func handleWindowEvent(element: AXUIElement, notification: String) {
        if notification == kAXWindowCreatedNotification {
            // Track the new window and add resize observers
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if let observer = observers[pid] {
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                AXObserverAddNotification(observer, element, kAXResizedNotification as CFString, refcon)
                trackedElements[pid, default: []].append(element)
            }
            // Check if the new window was created maximized
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.constrainIfMaximized(element)
            }
        } else if notification == kAXWindowResizedNotification ||
                  notification == kAXResizedNotification as String {
            // Only constrain if this resize looks like a maximize
            constrainIfMaximized(element)
        }
        // Move notifications are intentionally ignored — windows can freely
        // overlap the taskbar when dragged, just like screen side edges.
    }
    
    /// Only constrains a window if it appears to be maximized (spanning the full screen).
    /// Windows that are merely dragged near the taskbar are left alone.
    private func constrainIfMaximized(_ window: AXUIElement) {
        guard let position = getAXPosition(window),
              var size = getAXSize(window) else { return }
        
        // Skip tiny windows (tooltips, popups, etc.)
        if size.width < 50 || size.height < 50 { return }
        
        // Find which screen this window is on
        let centerX = position.x + size.width / 2
        let centerY = position.y + size.height / 2
        guard let screen = screenContaining(x: centerX, y: centerY) else { return }
        
        let screenFrame = screen.frame
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        
        // Screen bounds in AX coordinates (top-left origin)
        let screenTopInAX = mainScreenHeight - screenFrame.maxY
        let screenBottomInAX = mainScreenHeight - screenFrame.minY
        
        // The menu bar height (difference between frame and visibleFrame at the top)
        let menuBarHeight = screenFrame.height - screen.visibleFrame.height
            - (screenFrame.minY - screen.visibleFrame.minY).magnitude
        let usableTopInAX = screenTopInAX + menuBarHeight
        
        let windowBottom = position.y + size.height
        let tolerance: CGFloat = 10 // pixels of tolerance for "matches screen edge"
        
        // Detect a maximize: window spans (nearly) the full screen width
        // AND its bottom edge reaches (nearly) the screen bottom.
        // This catches double-click-titlebar, Option+green button, and programmatic maximizes.
        let spansFullWidth = abs(size.width - screenFrame.width) < tolerance
        let reachesBottom = abs(windowBottom - screenBottomInAX) < tolerance
        let startsAtTop = abs(position.y - usableTopInAX) < tolerance
                       || abs(position.y - screenTopInAX) < tolerance
        
        let isMaximized = spansFullWidth && reachesBottom && startsAtTop
        
        if isMaximized {
            // Shrink the window so it stops above the taskbar
            let maxBottomEdge = screenBottomInAX - WindowGuard.taskbarHeight
            let newHeight = maxBottomEdge - position.y
            if newHeight > 100 && newHeight < size.height {
                size.height = newHeight
                setAXSize(window, size: size)
            }
        }
    }
    
    /// Constrain all maximized windows from all running apps (used for initial pass and screen changes).
    func constrainAllWindows() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if let windows = getWindows(for: appElement) {
                for window in windows {
                    constrainIfMaximized(window)
                }
            }
        }
    }
    
    // MARK: - AX Helpers
    
    private func getWindows(for appElement: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return nil }
        return windows
    }
    
    private func getAXPosition(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }
    
    private func getAXSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }
    
    private func setAXPosition(_ element: AXUIElement, position: CGPoint) {
        var pos = position
        if let value = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }
    
    private func setAXSize(_ element: AXUIElement, size: CGSize) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }
    
    private func screenContaining(x: CGFloat, y: CGFloat) -> NSScreen? {
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        // Convert AX coords (top-left origin) to NSScreen coords (bottom-left origin)
        let nsY = mainScreenHeight - y
        let nsPoint = CGPoint(x: x, y: nsY)
        
        for screen in NSScreen.screens {
            if screen.frame.contains(nsPoint) {
                return screen
            }
        }
        // Fallback to main screen
        return NSScreen.main
    }
}

// MARK: - AXObserver C callback

/// Global C callback for AXObserver notifications. Forwards to the WindowGuard instance.
private func axCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let guard_ = Unmanaged<WindowGuard>.fromOpaque(refcon).takeUnretainedValue()
    guard_.handleWindowEvent(element: element, notification: notification as String)
}
