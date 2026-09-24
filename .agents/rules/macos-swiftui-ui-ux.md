# macOS SwiftUI UI/UX Best Practices

When building custom taskbars, toolbars, or interactive UI components in macOS using SwiftUI, strictly adhere to the following UI/UX patterns:

## 1. Custom Hover States
Avoid relying solely on `PlainButtonStyle()` for interactive elements like taskbar icons. `PlainButtonStyle()` removes hover feedback. Instead, create a custom `ButtonStyle` (e.g., `HoverButtonStyle`) that:
- Uses `.onHover { isHovered in ... }` to track state.
- Applies a subtle translucent background (e.g., `Color.white.opacity(0.15)`) when hovered.
- Uses `.scaleEffect()` for a pressed state feedback.
- Uses `.contentShape(Rectangle())` to ensure the entire padded area is clickable.

## 2. Hit Area Expansion
For text-based buttons (like a clock or status indicators), the default clickable area is restricted to the text bounds. Always apply `.padding()` followed by `.contentShape(Rectangle())` inside the button label to expand the hit area and make it easily clickable.

## 3. Fluid Reordering over Default Drag/Drop
When building horizontal lists that require inline, fluid reordering (like app icons in a taskbar):
- **DO NOT** use the default `.onDrag` and `.onDrop` if you want to avoid graying out the item or restricting its drag axis.
- **DO** use a custom `.gesture(DragGesture())`.
- Track the drag offset and apply a `visualOffset` using `.offset()` to non-dragged items so they smoothly yield space to the dragged item.
- Apply layout array reordering only at `.onEnded`, using `withAnimation(.spring())` to snap the dropped item into its final place seamlessly.
