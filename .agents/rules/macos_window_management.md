# macOS Window Management & Permissions

When developing macOS applications that interact with windows of other processes, adhere to the following rules:

1. **Window Titles & Screen Recording**: 
   - `CGWindowListCopyWindowInfo` will NOT return window titles (`kCGWindowName`) unless the app has Screen Recording permissions.
   - **Workaround**: Use the Accessibility API (`AXUIElement`) as a fallback to retrieve window titles if the user has not granted Screen Recording permissions (which is often preferred over requesting Screen Recording just for window names).
   - Example: Use `AXUIElementCreateApplication` and `AXUIElementCopyAttributeValue(window, kAXTitleAttribute...)` to fetch the title.

2. **Raising/Activating Windows**:
   - `NSRunningApplication.activate(options:)` sometimes only focuses the app without un-minimizing or raising the frontmost window.
   - **Workaround**: To reliably open or bring the most recent window of another app to the front, use AppleScript to perform an `AXRaise` action.
   - Example snippet:
     ```swift
     let script = """
     try
         tell application "System Events" to tell process "AppName"
             set frontmost to true
             perform action "AXRaise" of window 1
         end tell
     end try
     """
     // Execute via Process("/usr/bin/osascript")
     ```
