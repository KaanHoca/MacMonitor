# Widget Appearance: Light, Dark and Glass States

Date: 2026-09-13
Status: Draft, awaiting user review

## Goal

Make the MacMonitor widget look like the native macOS 26 desktop widgets next
to it in every state:

- Follow the light or dark appearance, selectable as Automatic, Light or Dark.
- Switch between the full-color and the dimmed Liquid Glass state the way
  native widgets do, selectable as Automatic, Full-color or Glass.
- Use the native corner shape.

## Background (measured on the target Mac, macOS 26.6.2)

**Corners.** Native widgets use continuous (squircle) corners. A 27.5pt
continuous rounded rectangle matches the measured native corner profile within
0.5pt. MacMonitor uses 18pt circular corners.

**Appearance.** The system runs Light with automatic day and night switching
(`AppleInterfaceStyleSwitchesAutomatically = 1`). The widget window forces
`darkAqua`, and the views hardcode white in 83 places (72 in ContentView, 5 in
Components, 6 in the theme table). Most are text and icon opacity levels
(0.25 to 0.9) and faint fills; the solid whites are labels on accent-filled
buttons.

**Native widget states.** Full-color: in Light, white background with colored
content. Dimmed: Liquid Glass that shows the wallpaper refracted through it,
with monochrome white content (colored icons turn white or gray; only photos
keep their color).

**What switches the state.** Two observer runs sampled a native widget pixel
every 0.4s and logged clicks, the window under each click and app activations
while the user performed a scripted sequence:

| Event | Native widgets on that display |
|---|---|
| Click on the wallpaper of that display (windows slide away) | Full-color within about 0.4s |
| Click on a parked window so the windows return | Dimmed |
| Click on MacMonitor (it becomes the frontmost app) | Unchanged |
| Activating apps whose windows are on other displays | Unchanged |
| Opening a Finder window with Cmd+N while revealed, clicking into it (the click lands on a Dock-owned layer 18 window) | Unchanged |

So the state follows the per-display "desktop revealed" state, not the
frontmost app. No distributed or NSWorkspace notification announces it (both
were observed during the transitions). A global left mouse-down monitor worked
without Accessibility permission.

**API.** `NSGlassEffectView` (macOS 26 SDK) offers `contentView`,
`cornerRadius`, `tintColor` and `style` (`.regular`, `.clear`).

## User-Facing Behavior

Two submenus in the status item menu, next to Theme and Widget Rows:

- **Appearance**: Automatic (default; follows the system, including automatic
  day and night switching), Light, Dark. UserDefaults key `appearanceMode`
  (`auto`, `light`, `dark`).
- **Widget Style**: Automatic (default; tracks the native state), Full-color,
  Glass. Key `widgetStyle` (`auto`, `fullColor`, `glass`). It mirrors the
  macOS "Widget style" setting; the same fixed value on both sides guarantees
  a match without detection.

Checkmarks show the selection. Changes apply immediately with a short
cross-fade, without animation under Reduce Motion.

| State | Background | Content |
|---|---|---|
| Full-color, Light | Near-white, matched to a capture of a native widget in full-color Light | Dark text and icons; theme colors in deeper variants, checked for contrast on white |
| Full-color, Dark | The current dark design | White text and icons; current theme colors |
| Glass (any appearance) | `NSGlassEffectView`, wallpaper refracted like dimmed native widgets | Monochrome white: dial ticks, icons, text; warning and critical ticks differ by brightness only, like native dimmed content |

Corners are 27.5pt continuous in every state and in detail views.

On macOS 13 to 25 there is no `NSGlassEffectView`: Light and Dark work, and
the Glass state uses a translucent `NSVisualEffectView` with the same
monochrome content.

## State Detection (Widget Style: Automatic)

D is the display MacMonitor's window is on. The window list is read front to
back, skipping windows with alpha 0 and full-display Dock overlays (layer 20,
click-through).

1. **Global left mouse-down at point p on D.** Classify the first window at p:
   - Finder's desktop (desktop icon level) or the wallpaper (Dock and Window
     Server desktop levels): full-color.
   - A normal app window (layer 0 up to below 18): dimmed.
   - MacMonitor, a native widget, the menu bar or a menu: unchanged.
   - Anything else (for example a Dock layer 18 window): 0.7s later, dimmed
     if a normal window is visible on D, otherwise unchanged.

   Clicks on other displays leave the state unchanged.
2. **App activation** (`NSWorkspace.didActivateApplicationNotification`): 0.7s
   later, dimmed if the activated app has a normal window visible on D,
   otherwise unchanged. This covers Cmd+Tab and Dock clicks that bring
   windows back.
3. **Launch, display changes, or the widget moving to another display:**
   full-color if no normal window is visible on D, otherwise dimmed.

**Cost.** One `CGWindowListCopyWindowInfo` call per click or activation, plus
at most one delayed re-check. No timers, no polling.

**Known limits.** Transitions without a click or activation (for example a
keyboard shortcut or gesture that shows the desktop, Mission Control) can
leave the widget out of sync until the next click. The one observed mismatch
is a new window opened while the desktop is revealed (rule 1 then dims on the
re-check while native widgets stay full-color). The fixed Widget Style values
guarantee a match.

**Permissions.** None expected. If the global mouse monitor needs a permission
inside MacMonitor, Automatic falls back to rules 2 and 3 and never triggers a
prompt.

## Architecture

- **`DesktopFocusRule.swift`** (pure, unit tested): a `WindowInfo` value type
  (owner kind: finder, dock, windowServer, widgetHost, macMonitor, other;
  layer; bounds; alpha) and the three rules as functions returning
  `.fullColor`, `.dimmed` or `.unchanged`. No AppKit state.
- **`WidgetAppearance.swift`** (AppKit): an `ObservableObject` that reads the
  two menu choices, resolves the effective appearance (window
  `effectiveAppearance` for Automatic) and the render style, owns the global
  mouse monitor and the activation observer, and maps `CGWindowList` entries
  to `WindowInfo` (owner kind by bundle id, never by localized name).
- **Background view** (AppKit): a container that shows `NSGlassEffectView` on
  macOS 26 (or `NSVisualEffectView` before it) for Glass, and a plain
  full-color background otherwise, with the 27.5pt continuous corners. The
  SwiftUI hosting view is its content; it replaces the current
  `NSVisualEffectView` with the forced dark appearance and the mask image.
- **SwiftUI**: the window appearance drives `colorScheme` (Glass renders its
  content in the dark scheme, so text is white). An environment value tells
  views whether Glass is active. Hardcoded white becomes `.primary` with the
  same opacity; accent-filled button labels stay white. `ThemeColors` resolves
  per state: Dark keeps today's colors, Light uses deeper variants, Glass uses
  white. The Mono theme becomes black in Light.
- **Menus** in `MacMonitorApp.swift`: the two submenus write the keys and
  notify the appearance object.

## Testing

- **Unit** (`./test.sh`): the three rules with fixtures from the logged
  clicks. Cases: Finder desktop click gives full-color; normal window on D
  gives dimmed; MacMonitor click and native widget click give unchanged;
  click on another display gives unchanged; the Dock layer 20 overlay is
  skipped; a layer 18 click re-checks visible windows; activation with and
  without a window on D.
- **Visual**: side-by-side region captures of MacMonitor next to native
  widgets in the dimmed state (apps in front) and in full-color Light (after a
  wallpaper click the user performs); Dark when the system switches in the
  evening. Detail views in each state.
- **Behavior**: the user repeats the observer click sequence; MacMonitor must
  switch together with the native widgets.
- **Resources**: CPU and memory sampled before and after, as in the previous
  release; no new timers.

## Out of Scope

- Reserving grid slots or changing native widgets.
- Transitions without a click or activation (see Known limits).
- The macOS 26 tinted and clear icon modes.
