# Taskbar Dialogue Positioning

When implementing native popup dialogues, context menus, or `NSMenu` popups from SwiftUI views embedded in the taskbar:

1. **Avoid Fixed Heights on Host Views:** Ensure the `NSViewRepresentable` or host view triggering the menu does NOT have a small, fixed height (e.g., `.frame(width: 20, height: 20)`).
2. **Span Full Taskbar Height:** Apply `.frame(maxHeight: .infinity)` to the host view so its bounds match the full vertical height of the taskbar.
3. **Calculate Origin Safely:** When calling `menu.popUp(positioning:at:in:)`, use the host view's `bounds.height` (which now correctly equals the taskbar's full height) plus a small offset to ensure the dialogue opens strictly above the taskbar without overlapping.
