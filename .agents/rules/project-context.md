# Project Context: Mac Windows Taskbar

This rule file provides context for any AI agents working in this workspace.

## Goal
The goal of this project is to build a macOS application using Swift (SwiftUI + AppKit) that closely mimics the Windows taskbar experience. It overlays on top of the screen at the bottom of all connected displays.

## How to Build and Run
This project is set up as a standard Swift Package executable (not an `.xcodeproj`).
- **To build:** Run `swift build` in the root directory (`/Users/rd908/projects/mac-windows-taskbar`).
- **To run:** Run `./.build/debug/MacTaskbar`. (It is recommended to run the compiled binary directly rather than `swift run` to easily manage the process and permissions).

## System Architecture & Dependencies
1. **Dock Hidden:** The default macOS Dock is hidden permanently by setting a massive auto-hide delay. 
   - Command: `defaults write com.apple.dock autohide-delay -float 1000 && killall Dock`
2. **Rectangle App (Window Management):** Used to prevent maximized windows from covering the taskbar. Rectangle is configured to have a 48px bottom margin.
   - Command: `defaults write com.knollmac.Rectangle bottomMargin -int 48 && killall Rectangle && open -a Rectangle`
3. **Permissions:** The executable requires **Screen Recording** and **Accessibility** permissions. Since it uses ad-hoc signing on build, rebuilding the app may prompt for these permissions again if the binary signature changes. 

## Implementation Details
- **Window Overlay:** We use `NSPanel` with a `.floating` window level, spanning across `NSScreen.screens`. The app uses `NSApp.setActivationPolicy(.accessory)` to hide itself from the app switcher and macOS Dock.
- **Open Apps & Accordion:** We fetch running apps using `NSWorkspace.shared.runningApplications` combined with `CGWindowListCopyWindowInfo` to determine exactly how many windows an app has open on standard layers. If `windowCount > 1`, we show a two-dot indicator under the app icon.
- **Spotlight:** Triggered by an AppleScript command that simulates `Cmd + Space` (which is standard for Spotlight).
- **Control Center:** Opened via the URL scheme `x-apple.systempreferences:com.apple.ControlCenter-Settings.extension`.
- **System Tray:** Includes functional widgets for Wi-Fi (opens system settings), battery (parses `pmset -g batt` for live percentage), and a chevron to display a list of background/menu-bar apps (filtered by `activationPolicy == .accessory`).
- **Context Menus:** When hovering over an app icon, a native `NSMenu` pops up mimicking the macOS right-click menu, listing open windows (clickable), pin/unpin options, and a quit option. The menu is kept open naturally by `NSMenu` but is dismissed programmatically via `cancelTracking()` if the mouse leaves the immediate bounds of the icon and menu, allowing seamless transitions between icons.
- **Window Activation Fallbacks:** Because `CGWindowListCopyWindowInfo` requires Screen Recording permissions to fetch `kCGWindowName`, we generate fallback names like "Window 1" if permissions are missing. Clicking these fallback names uses an AppleScript wrapped in a `try...end try` block to suppress errors and just bring the app `frontmost` if the window name doesn't match the actual Accessibility title.
