# MacMonitor

A lightweight, native macOS desktop widget that displays real-time system metrics — CPU, Memory, Disk, Temperature, and Network — right on your desktop. Includes a built-in disk cleanup tool to free up storage safely.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-supported-green)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## Features

- **2x2 Circular Gauges** — CPU, Memory, Disk, Temperature with live network stats and IP addresses
- **Disk Cleanup** — scan and clean 19 categories of junk files safely (caches, logs, old installers, etc.)
- **Native macOS Look & Feel** — system visual effect materials, blends seamlessly with your desktop
- **Live Process Details** — click CPU or Memory gauge to see top processes, auto-refreshes while open
- **Memory Cleanup** — two options: Quick (no password, memory pressure) and Purge (admin, system-level)
- **Real CPU Temperature** — actual sensor data via SMC (System Management Controller)
- **6 Color Themes** — Ocean, Lavender, Emerald, Sunset, Sakura, and Mono
- **Clean Single-Color Rings** — each gauge uses a solid theme color for a modern, minimal look
- **Network Monitor** — live download/upload speeds and ping latency with color-coded indicator
- **IP Addresses** — external and local IP shown below network stats, tap to copy
- **Menu Bar Stats** — quick glance at CPU, Memory, Disk, and Temp without opening the widget
- **Launch at Login** — one-click setup from the menu bar
- **Remembers Position** — widget stays where you last placed it across restarts
- **Desktop-Level Window** — stays behind app windows, always visible on your desktop

## Quick Start

**Double-click** the `Install and Run.command` file. That's it.

> On first run, if Xcode Command Line Tools are not installed, you'll be prompted to install them. Once the installation finishes, double-click again.

### Alternative: Build from Terminal

```bash
chmod +x build.sh
./build.sh
open MacMonitor.app
```

## Usage

| Action | How |
|---|---|
| **Move widget** | Drag it anywhere on your desktop |
| **View processes** | Click the **CPU** or **Memory** gauge |
| **Disk cleanup** | Click the **Disk** gauge to scan and clean junk files |
| **Go back** | Click **<** in the detail view |
| **Quick memory clean** | Click the **Quick** button in Memory detail (no password needed) |
| **Deep memory purge** | Click the **Purge** button in Memory detail (admin password required) |
| **Change theme** | Menu bar icon > **Theme** > pick a color scheme |
| **Launch at login** | Menu bar icon > **Launch at Login** (toggles on/off) |
| **Show / Hide** | Menu bar icon > **Show Widget** / **Hide Widget** |
| **Copy IP** | Click the External or Local IP address to copy it to clipboard |
| **Quick stats** | Click the menu bar icon to see live CPU, Memory, Disk, Temp |
| **Quit** | Menu bar icon > **Quit** |

## Disk Cleanup

Click the **Disk** gauge to open the cleanup tool. It scans your system for safely removable files across 19 categories:

**Enabled by default (safe, auto-regenerates):**
- System and app caches, logs, crash reports
- macOS installer files, iOS firmware files
- Incomplete downloads, QuickLook cache
- Mail attachment cache, macOS wallpaper videos

**Optional (disabled by default):**
- Trash, browser caches
- Xcode (DerivedData, simulators, device support, archives)
- Package manager caches (npm, pip, Homebrew)
- Developer tool caches (Gradle, Maven, CocoaPods, Cargo, Go, Yarn, pnpm)
- Docker build cache, IDE caches (VS Code, Cursor, JetBrains)

All toggle preferences are saved and persist across restarts. Categories not present on your system are automatically hidden. Each category has an info button explaining what it does.

## Themes

| Theme | Style |
|---|---|
| **Ocean** | Sky blue, steel blue, teal |
| **Lavender** | Vivid purple, deep lavender, mauve |
| **Emerald** | Emerald green, teal, mint |
| **Sunset** | Warm amber, burnt orange, gold |
| **Sakura** | Rose pink, deep rose, soft pink |
| **Mono** | White, light gray, soft gray |

Your selected theme is saved and persists across restarts.

## How It Works

MacMonitor is a pure Swift/SwiftUI application with no external dependencies. It collects system metrics using low-level macOS APIs:

| Metric | Source |
|---|---|
| CPU Usage | Mach kernel `processor_info` calls |
| Memory | `vm_statistics64` via Mach |
| Disk | `FileManager` volume capacity APIs |
| Temperature | IOKit SMC (System Management Controller) sensor reads |
| Network Speed | `getifaddrs` — bytes in/out delta across en*/bridge* interfaces |
| Ping | `/sbin/ping` — single ICMP echo to 8.8.8.8 (3s timeout) |
| Local IP | `getifaddrs` — IPv4 address from active interface (en0 preferred) |
| External IP | `api.ipify.org` — public IP via lightweight HTTP request |
| Processes | `/bin/ps` output, parsed and grouped |

### Performance

- UI updates every **5 seconds** (not 3) to minimize CPU overhead
- Disk is checked every **~30 seconds** (rarely changes)
- IP addresses refresh every **~60 seconds** (rarely change)
- SMC key info is **cached** — queried once, reused forever
- Published properties only update when values **actually change**, preventing unnecessary SwiftUI redraws
- Process lists only refresh while the **detail view is open**
- Menu bar stats only update while the **menu is open**

Typical CPU usage: **~1–2%**

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (auto-prompted on first build)
- Apple Silicon or Intel Mac

## Project Structure

```
MacMonitor/
├── MacMonitor/
│   ├── MacMonitorApp.swift      # App entry, window, menu bar & launch at login
│   ├── ContentView.swift        # SwiftUI views, gauges, process lists & disk cleanup UI
│   ├── SystemMonitor.swift      # System metrics engine & theme definitions
│   ├── DiskCleaner.swift        # Disk cleanup engine (19 categories, scan/clean logic)
│   └── Info.plist               # App configuration
├── build.sh                     # Terminal build script
└── Install and Run.command      # One-click build & run
```

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## License

This project is available under the [MIT License](LICENSE).
