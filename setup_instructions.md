# MacMonitor — Xcode Setup

## 1. Create Xcode Project
1. Open Xcode → **File > New > Project**
2. Select **macOS > App** → Next
3. Product Name: `MacMonitor`
4. Interface: **SwiftUI**
5. Language: **Swift**
6. Save

## 2. Add Files
1. `ContentView.swift` → delete the existing one, replace with this file
2. `MacMonitorApp.swift` → delete the existing one, replace with this file
3. `SystemMonitor.swift` → add as a new file to the project
4. `Info.plist` → verify `LSUIElement` = YES in project settings (included by default)

## 3. Build Settings
- Target > General > **Deployment Target**: macOS 13.0+
- Signing & Capabilities: use your Developer account or "Sign to Run Locally"

## 4. Run
Build and run with Cmd+R.
The widget appears on your desktop — drag to reposition.

## 5. Auto-Launch on Login (optional)
System Settings > General > Login Items → add the app
