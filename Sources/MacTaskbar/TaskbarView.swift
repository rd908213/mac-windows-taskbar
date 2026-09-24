import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

class AppState: ObservableObject {
    @Published var displayApps: [AppModel] = []
    @Published var menuBarApps: [AppModel] = []
    @Published var activeAppPID: Int32?
    @Published var isDragging: Bool = false
    private var timer: AnyCancellable?
    
    @Published var pinnedBundleIDs: [String] = [] {
        didSet {
            UserDefaults.standard.set(pinnedBundleIDs, forKey: "PinnedApps")
        }
    }
    
    @Published var appOrder: [String] = [] {
        didSet {
            UserDefaults.standard.set(appOrder, forKey: "AppOrder")
        }
    }
    
    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "PinnedApps") {
            pinnedBundleIDs = saved
        } else {
            pinnedBundleIDs = ["com.apple.finder"]
        }
        
        if let savedOrder = UserDefaults.standard.stringArray(forKey: "AppOrder") {
            appOrder = savedOrder
        } else {
            appOrder = pinnedBundleIDs
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeAppChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        self.activeAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        
        fetchApps()
        timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.fetchApps()
        }
    }
    
    @objc func activeAppChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            DispatchQueue.main.async {
                self.activeAppPID = app.processIdentifier
            }
        }
    }
    
    func togglePin(for bundleID: String) {
        if pinnedBundleIDs.contains(bundleID) {
            pinnedBundleIDs.removeAll { $0 == bundleID }
        } else {
            pinnedBundleIDs.append(bundleID)
        }
        fetchApps()
    }
    
    func fetchApps() {
        let currentPinned = self.pinnedBundleIDs
        let currentAppOrder = self.appOrder
        DispatchQueue.global(qos: .userInitiated).async {
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            
            var appWindows: [Int32: Int] = [:]
            var appWindowNames: [Int32: [String]] = [:]
            
            for window in windowList {
                if let pid = window[kCGWindowOwnerPID as String] as? Int32 {
                    let layer = window[kCGWindowLayer as String] as? Int ?? 0
                    if layer == 0 {
                        appWindows[pid, default: 0] += 1
                        if let windowName = window[kCGWindowName as String] as? String, !windowName.isEmpty {
                            appWindowNames[pid, default: []].append(windowName)
                        }
                    }
                }
            }
            
            for pid in appWindows.keys {
                if appWindowNames[pid] == nil || appWindowNames[pid]!.isEmpty {
                    let appElement = AXUIElementCreateApplication(pid)
                    var windowsValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                       let windows = windowsValue as? [AXUIElement] {
                        var names: [String] = []
                        for window in windows {
                            var titleValue: CFTypeRef?
                            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                               let title = titleValue as? String, !title.isEmpty {
                                names.append(title)
                            }
                        }
                        if !names.isEmpty {
                            appWindowNames[pid] = names
                        } else {
                            appWindowNames[pid] = (1...appWindows[pid]!).map { "Window \($0)" }
                        }
                    } else {
                        appWindowNames[pid] = (1...appWindows[pid]!).map { "Window \($0)" }
                    }
                } else {
                    let currentCount = appWindowNames[pid]!.count
                    let targetCount = appWindows[pid]!
                    if currentCount < targetCount {
                        appWindowNames[pid]!.append(contentsOf: (currentCount+1...targetCount).map { "Window \($0)" })
                    }
                }
            }
            
            let runningApps = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular && appWindows[app.processIdentifier] != nil
            }
            
            var newDisplayApps: [AppModel] = []
            var processedBundleIDs: Set<String> = []
            
            for bundleID in currentPinned {
                processedBundleIDs.insert(bundleID)
                if let runningApp = runningApps.first(where: { $0.bundleIdentifier == bundleID }) {
                    let pid = runningApp.processIdentifier
                    newDisplayApps.append(AppModel(
                        bundleIdentifier: bundleID,
                        processIdentifier: pid,
                        app: runningApp,
                        windowCount: appWindows[pid] ?? 1,
                        windowNames: appWindowNames[pid] ?? [],
                        icon: runningApp.icon,
                        name: runningApp.localizedName ?? "Unknown",
                        isRunning: true,
                        isPinned: true
                    ))
                } else {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.deletingPathExtension().lastPathComponent
                        let icon = NSWorkspace.shared.icon(forFile: url.path)
                        newDisplayApps.append(AppModel(
                            bundleIdentifier: bundleID,
                            processIdentifier: nil,
                            app: nil,
                            windowCount: 0,
                            windowNames: [],
                            icon: icon,
                            name: name,
                            isRunning: false,
                            isPinned: true
                        ))
                    }
                }
            }
            
            for runningApp in runningApps {
                if let bundleID = runningApp.bundleIdentifier, !processedBundleIDs.contains(bundleID) {
                    let pid = runningApp.processIdentifier
                    newDisplayApps.append(AppModel(
                        bundleIdentifier: bundleID,
                        processIdentifier: pid,
                        app: runningApp,
                        windowCount: appWindows[pid] ?? 1,
                        windowNames: appWindowNames[pid] ?? [],
                        icon: runningApp.icon,
                        name: runningApp.localizedName ?? "Unknown",
                        isRunning: true,
                        isPinned: false
                    ))
                }
            }
            
            var workingOrder = currentAppOrder
            for app in newDisplayApps {
                if !workingOrder.contains(app.bundleIdentifier) {
                    workingOrder.append(app.bundleIdentifier)
                }
            }
            
            newDisplayApps.sort { app1, app2 in
                let idx1 = workingOrder.firstIndex(of: app1.bundleIdentifier) ?? Int.max
                let idx2 = workingOrder.firstIndex(of: app2.bundleIdentifier) ?? Int.max
                return idx1 < idx2
            }
            
            let accessoryApps = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .accessory && app.bundleIdentifier != nil && app.icon != nil && !(app.bundleIdentifier?.hasPrefix("com.apple.") ?? false)
            }
            
            var newMenuBarApps: [AppModel] = []
            for app in accessoryApps {
                if let bundleID = app.bundleIdentifier {
                    newMenuBarApps.append(AppModel(
                        bundleIdentifier: bundleID,
                        processIdentifier: app.processIdentifier,
                        app: app,
                        windowCount: 0,
                        windowNames: [],
                        icon: app.icon,
                        name: app.localizedName ?? "Unknown",
                        isRunning: true,
                        isPinned: false
                    ))
                }
            }
            
            DispatchQueue.main.async {
                if !self.isDragging {
                    self.displayApps = newDisplayApps
                    if self.appOrder != workingOrder {
                        self.appOrder = workingOrder
                    }
                }
                self.menuBarApps = newMenuBarApps.sorted(by: { $0.name < $1.name })
                if self.activeAppPID == nil {
                    self.activeAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                }
            }
        }
    }
}

struct AppModel: Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let processIdentifier: Int32?
    let app: NSRunningApplication?
    let windowCount: Int
    let windowNames: [String]
    let icon: NSImage?
    let name: String
    let isRunning: Bool
    let isPinned: Bool
    
    static func ==(lhs: AppModel, rhs: AppModel) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}

class BatteryModel: ObservableObject {
    @Published var percentage: String = "100%"
    @Published var systemImageName: String = "battery.100"
    private var timer: AnyCancellable?

    init() {
        updateBattery()
        timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.updateBattery()
        }
    }

    func updateBattery() {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.launchPath = "/usr/bin/pmset"
            task.arguments = ["-g", "batt"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.launch()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                if let regex = try? NSRegularExpression(pattern: "(\\d+)%"),
                   let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                   let range = Range(match.range(at: 1), in: output) {
                    let percentStr = output[range]
                    
                    let isCharging = output.contains("AC attached") && !output.contains("discharging")
                    let isCharged = output.contains("charged")
                    
                    let percentInt = Int(percentStr) ?? 100
                    
                    var iconName = "battery.100"
                    if percentInt <= 10 {
                        iconName = isCharging ? "battery.0.bolt" : "battery.0"
                    } else if percentInt <= 25 {
                        iconName = isCharging ? "battery.25.bolt" : "battery.25"
                    } else if percentInt <= 50 {
                        iconName = isCharging ? "battery.50.bolt" : "battery.50"
                    } else if percentInt <= 75 {
                        iconName = isCharging ? "battery.75.bolt" : "battery.75"
                    } else {
                        iconName = isCharging ? "battery.100.bolt" : "battery.100"
                    }
                    if isCharged {
                        iconName = "battery.100.bolt"
                    }
                    
                    DispatchQueue.main.async {
                        self.percentage = "\(percentStr)%"
                        self.systemImageName = iconName
                    }
                }
            }
        }
    }
}

struct TaskbarView: View {
    @StateObject private var appState = AppState()
    @StateObject private var batteryModel = BatteryModel()
    @State private var draggedItem: String?
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        HStack {
            Button(action: {
                let process = Process()
                process.launchPath = "/usr/bin/osascript"
                process.arguments = ["-e", "tell application \"System Events\" to keystroke space using command down"]
                process.launch()
            }) {
                Image(systemName: "applelogo")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
            }
            .buttonStyle(HoverButtonStyle())
            .padding(.leading, 8)
            
            // Open Apps
            HStack(spacing: 0) {
                ForEach(appState.displayApps) { appModel in
                    let isDragged = draggedItem == appModel.bundleIdentifier
                    let draggedIndex = appState.displayApps.firstIndex(where: { $0.bundleIdentifier == draggedItem }) ?? 0
                    let myIndex = appState.displayApps.firstIndex(of: appModel) ?? 0
                    
                    let itemWidth: CGFloat = 44
                    let draggedVisualPosition = CGFloat(draggedIndex) * itemWidth + dragOffset
                    let currentDragIndex = Int(round(draggedVisualPosition / itemWidth))
                    let clampedDragIndex = max(0, min(appState.displayApps.count - 1, currentDragIndex))
                    
                    let visualOffset: CGFloat = {
                        if isDragged { return dragOffset }
                        guard draggedItem != nil else { return 0 }
                        if myIndex > draggedIndex && myIndex <= clampedDragIndex {
                            return -itemWidth
                        } else if myIndex < draggedIndex && myIndex >= clampedDragIndex {
                            return itemWidth
                        }
                        return 0
                    }()
                    
                    AppIconView(appModel: appModel, appState: appState)
                        .scaleEffect(isDragged ? 1.15 : 1.0)
                        .offset(x: visualOffset, y: isDragged ? -4 : 0)
                        .zIndex(isDragged ? 100 : 0)
                        .shadow(color: isDragged ? Color.black.opacity(0.5) : Color.clear, radius: isDragged ? 8 : 0, x: 0, y: isDragged ? 6 : 0)
                        .animation(isDragged ? .none : .spring(), value: visualOffset)
                        .animation(isDragged ? .none : .spring(), value: isDragged)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    if draggedItem == nil { 
                                        draggedItem = appModel.bundleIdentifier 
                                        appState.isDragging = true
                                    }
                                    dragOffset = value.translation.width
                                }
                                .onEnded { _ in
                                    guard let draggedItem = draggedItem else { return }
                                    let draggedIdx = appState.displayApps.firstIndex(where: { $0.bundleIdentifier == draggedItem }) ?? 0
                                    let visualPos = CGFloat(draggedIdx) * itemWidth + dragOffset
                                    let targetIdx = max(0, min(appState.displayApps.count - 1, Int(round(visualPos / itemWidth))))
                                    
                                    withAnimation(.spring()) {
                                        if targetIdx != draggedIdx {
                                            var newDisplayApps = appState.displayApps
                                            let movedApp = newDisplayApps.remove(at: draggedIdx)
                                            newDisplayApps.insert(movedApp, at: targetIdx)
                                            
                                            let movedID = movedApp.bundleIdentifier
                                            var newOrder = appState.appOrder
                                            if let orderIdx = newOrder.firstIndex(of: movedID) {
                                                newOrder.remove(at: orderIdx)
                                            }
                                            
                                            if targetIdx == 0 {
                                                newOrder.insert(movedID, at: 0)
                                            } else {
                                                let appBeforeID = newDisplayApps[targetIdx - 1].bundleIdentifier
                                                if let beforeIdx = newOrder.firstIndex(of: appBeforeID) {
                                                    newOrder.insert(movedID, at: beforeIdx + 1)
                                                } else {
                                                    newOrder.append(movedID)
                                                }
                                            }
                                            appState.appOrder = newOrder
                                            
                                            if !appState.pinnedBundleIDs.contains(movedID) {
                                                appState.pinnedBundleIDs.append(movedID)
                                            }
                                            
                                            appState.displayApps = newDisplayApps
                                        }
                                        self.draggedItem = nil
                                        self.dragOffset = 0
                                        appState.isDragging = false
                                    }
                                }
                        )
                }
            }
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity)
            
            Spacer()
            
            // System Tray
            HStack(spacing: 0) {
                TrayMenuViewRepresentable(appState: appState)
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                
                Button(action: {
                    let process = Process()
                    process.launchPath = "/usr/bin/open"
                    process.arguments = ["x-apple.systempreferences:com.apple.preference.network?Wi-Fi"]
                    process.launch()
                }) {
                    Image(systemName: "wifi")
                }
                .buttonStyle(HoverButtonStyle())
                
                Button(action: {
                    let process = Process()
                    process.launchPath = "/usr/bin/open"
                    process.arguments = ["x-apple.systempreferences:com.apple.preference.battery"]
                    process.launch()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: batteryModel.systemImageName)
                        Text(batteryModel.percentage)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(HoverButtonStyle())
                
                Button(action: {
                    let process = Process()
                    process.launchPath = "/usr/bin/open"
                    process.arguments = ["x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"]
                    process.launch()
                }) {
                    Image(systemName: "switch.2")
                }
                .buttonStyle(HoverButtonStyle())
                
                Button(action: {
                    if let url = URL(string: "ical://") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    }
                }) {
                    Text(Date(), style: .time)
                }
                .buttonStyle(HoverButtonStyle())
            }
            .foregroundColor(.white)
            .padding(.trailing, 8)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView().edgesIgnoringSafeArea(.all))
    }
}

struct HoverButtonStyle: ButtonStyle {
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.white.opacity(0.15) : Color.clear)
                    .padding(.vertical, 4)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}



struct AppIconView: View {
    let appModel: AppModel
    @ObservedObject var appState: AppState
    
    var isActive: Bool {
        appState.activeAppPID != nil && appState.activeAppPID == appModel.processIdentifier
    }
    
    var body: some View {
        Button(action: {
            if let app = appModel.app {
                if let appName = app.localizedName {
                    let script = """
                    try
                        tell application "System Events" to tell process "\(appName)"
                            set frontmost to true
                            perform action "AXRaise" of window 1
                        end tell
                    end try
                    """
                    let process = Process()
                    process.launchPath = "/usr/bin/osascript"
                    process.arguments = ["-e", script]
                    process.launch()
                } else {
                    app.activate(options: .activateIgnoringOtherApps)
                }
            } else {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appModel.bundleIdentifier) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
            }
        }) {
            VStack(spacing: 2) {
                if let icon = appModel.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                } else {
                    Circle().fill(Color.gray).frame(width: 28, height: 28)
                }
                
                // Open app dot or active line indicator
                ZStack {
                    if isActive {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue)
                            .frame(width: 20, height: 4)
                    } else if appModel.isRunning {
                        if appModel.windowCount > 1 {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.white.opacity(0.8))
                                    .frame(width: 4, height: 4)
                                Circle()
                                    .fill(Color.white.opacity(0.8))
                                    .frame(width: 4, height: 4)
                            }
                        } else {
                            Circle()
                                .fill(Color.white.opacity(0.8))
                                .frame(width: 4, height: 4)
                        }
                    } else {
                        Color.clear.frame(width: 20, height: 4)
                    }
                }
                .frame(height: 4)
                .animation(.easeInOut, value: isActive)
                .animation(.easeInOut, value: appModel.isRunning)
            }
            .frame(width: 36)
            .contentShape(Rectangle())
            .background(HoverMenuViewRepresentable(appModel: appModel, appState: appState))
        }
        .buttonStyle(HoverButtonStyle())
    }
}

struct HoverMenuViewRepresentable: NSViewRepresentable {
    let appModel: AppModel
    let appState: AppState
    
    func makeNSView(context: Context) -> HoverMenuView {
        let view = HoverMenuView()
        view.appModel = appModel
        view.appState = appState
        return view
    }
    
    func updateNSView(_ nsView: HoverMenuView, context: Context) {
        nsView.appModel = appModel
        nsView.appState = appState
    }
}

class HoverMenuView: NSView {
    var appModel: AppModel?
    var appState: AppState?
    
    private var trackingArea: NSTrackingArea?
    private var currentMenu: NSMenu?
    private var trackingTimer: Timer?
    private var hoverTimer: Timer?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
    
    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    override func mouseEntered(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.showMenu()
        }
    }
    
    func showMenu() {
        guard let appModel = appModel, let appState = appState else { return }
        
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        if !appModel.windowNames.isEmpty {
            for windowName in appModel.windowNames {
                let item = NSMenuItem(title: windowName, action: #selector(windowSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = windowName
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }
        
        let pinItem = NSMenuItem(title: appModel.isPinned ? "Unpin from Taskbar" : "Pin to Taskbar", action: #selector(togglePin(_:)), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)
        
        if appModel.isRunning {
            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "")
            quitItem.target = self
            menu.addItem(quitItem)
        }
        
        // Position menu at the top of the taskbar window, same spacing as the chevron
        let windowHeight = window?.frame.height ?? bounds.height
        let myOriginInWindow = convert(NSPoint(x: 0, y: 0), to: nil)
        let popupY = windowHeight - myOriginInWindow.y + 4
        let pt = NSPoint(x: 0, y: popupY)
        currentMenu = menu
        
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let menu = self.currentMenu, let window = self.window else { return }
            let mouseLoc = NSEvent.mouseLocation
            
            let iconRectInWindow = self.convert(self.bounds, to: nil)
            let iconRectOnScreen = window.convertToScreen(iconRectInWindow)
            
            // Approximate menu rect on screen (use window top as reference for menu height anchor)
            let menuRectOnScreen = NSRect(x: iconRectOnScreen.minX, y: iconRectOnScreen.maxY, width: menu.size.width, height: menu.size.height)
            
            // Do not expand the icon rect horizontally so that moving to adjacent icons closes the menu
            let expandedIconRect = iconRectOnScreen.insetBy(dx: 0, dy: -10)
            let expandedMenuRect = menuRectOnScreen.insetBy(dx: -10, dy: -10)
            
            if !expandedIconRect.contains(mouseLoc) && !expandedMenuRect.contains(mouseLoc) {
                menu.cancelTracking()
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        trackingTimer = timer
        
        menu.popUp(positioning: nil, at: pt, in: self)
        
        trackingTimer?.invalidate()
        trackingTimer = nil
        currentMenu = nil
    }
    
    @objc func windowSelected(_ sender: NSMenuItem) {
        if let windowName = sender.representedObject as? String {
             if let appName = appModel?.app?.localizedName {
                  let script = """
                  try
                      tell application "System Events" to tell process "\(appName)"
                          set frontmost to true
                          perform action "AXRaise" of window "\(windowName)"
                      end tell
                  end try
                  """
                  let process = Process()
                  process.launchPath = "/usr/bin/osascript"
                  process.arguments = ["-e", script]
                  process.launch()
             } else {
                  appModel?.app?.activate()
             }
        }
    }
    
    @objc func togglePin(_ sender: NSMenuItem) {
        if let bundleID = appModel?.bundleIdentifier {
            appState?.togglePin(for: bundleID)
        }
    }
    
    @objc func quitApp(_ sender: NSMenuItem) {
        appModel?.app?.terminate()
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct TrayMenuViewRepresentable: NSViewRepresentable {
    @ObservedObject var appState: AppState
    
    func makeNSView(context: Context) -> TrayChevronView {
        let view = TrayChevronView()
        view.appState = appState
        return view
    }
    
    func updateNSView(_ nsView: TrayChevronView, context: Context) {
        nsView.appState = appState
    }
}

class TrayChevronView: NSView {
    var appState: AppState?
    
    private let imageView = NSImageView()
    private let backgroundLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?
    private var trackingTimer: Timer?
    private var currentMenu: NSMenu?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        wantsLayer = true
        backgroundLayer.cornerRadius = 4
        backgroundLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(backgroundLayer)
        
        if let image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil) {
            imageView.image = image
            imageView.contentTintColor = .white
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    override func layout() {
        super.layout()
        // Match the vertical padding (4pt) of HoverButtonStyle
        backgroundLayer.frame = bounds.insetBy(dx: 0, dy: 4)
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
    
    override func mouseExited(with event: NSEvent) {
        backgroundLayer.backgroundColor = NSColor.clear.cgColor
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    override func mouseEntered(with event: NSEvent) {
        backgroundLayer.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.showMenu()
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        showMenu()
    }
    
    func showMenu() {
        guard let appState = appState else { return }
        
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        let header = NSMenuItem(title: "Menu Bar Apps", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())
        
        if appState.menuBarApps.isEmpty {
            let empty = NSMenuItem(title: "No apps", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for menuApp in appState.menuBarApps {
                let item = NSMenuItem(title: menuApp.name, action: #selector(appSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = menuApp.bundleIdentifier
                if let icon = menuApp.icon {
                    // Resize icon to 16x16
                    let newIcon = NSImage(size: NSSize(width: 16, height: 16))
                    newIcon.lockFocus()
                    icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                    newIcon.unlockFocus()
                    item.image = newIcon
                }
                menu.addItem(item)
            }
        }
        
        let pt = NSPoint(x: 0, y: bounds.height + 4)
        currentMenu = menu
        
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let menu = self.currentMenu, let window = self.window else { return }
            let mouseLoc = NSEvent.mouseLocation
            
            let iconRectInWindow = self.convert(self.bounds, to: nil)
            let iconRectOnScreen = window.convertToScreen(iconRectInWindow)
            
            // Approximate menu rect on screen
            let menuRectOnScreen = NSRect(x: iconRectOnScreen.minX, y: iconRectOnScreen.maxY, width: menu.size.width, height: menu.size.height)
            
            let expandedIconRect = iconRectOnScreen.insetBy(dx: 0, dy: -10)
            let expandedMenuRect = menuRectOnScreen.insetBy(dx: -10, dy: -10)
            
            if !expandedIconRect.contains(mouseLoc) && !expandedMenuRect.contains(mouseLoc) {
                menu.cancelTracking()
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        trackingTimer = timer
        
        menu.popUp(positioning: nil, at: pt, in: self)
        
        trackingTimer?.invalidate()
        trackingTimer = nil
        currentMenu = nil
    }
    
    @objc func appSelected(_ sender: NSMenuItem) {
        if let bundleID = sender.representedObject as? String,
           let app = appState?.menuBarApps.first(where: { $0.bundleIdentifier == bundleID })?.app {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }
}
