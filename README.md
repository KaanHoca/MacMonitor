# MacMonitor

A lightweight, native macOS desktop widget that displays real-time system metrics — CPU, Memory, Disk, Temperature, Fans, Network and Battery — right on your desktop. Includes a built-in disk cleanup tool, fan boost and memory cleanup.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-supported-green)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## Features

- **2x2 Circular Gauges** — CPU, Memory, Disk, Temperature with live sparklines and secondary info under each ring
- **Live Ring Transitions** — tap a gauge and its ring flies into the detail header, staying live while the detail is open
- **Dynamic Window Height** — the widget grows for detail views and shrinks back, bottom edge anchored
- **Thermals View** — CPU temperature history graph, per-fan cards, RPM history and a fan boost with selectable duration (admin, gentle ramp)
- **Disk Cleanup** — scan and clean 19 categories of junk files safely; recoverable categories go to the Trash instead of being deleted
- **Memory Cleanup** — Quick (no password) and Purge (admin); both report the actually measured freed amount
- **Battery Info** — charge, health and cycle count on portable Macs (hidden on desktops)
- **Threshold Alerts** — notification when the CPU hits 100°C or the disk is 90% full (max once per hour, toggleable)
- **Keep Mac Awake** — one-click sleep prevention from the menu bar
- **Menu Bar Stats** — CPU, Memory, Disk, Temp, Fan, GPU, uptime and load average; optional compact text mode instead of the icon
- **Real Sensors** — SMC temperature keys discovered per chip generation (M1 through M4 and Intel)
- **Network Monitor** — live download/upload speeds, color-coded ping, tap-to-copy external and local IPs
- **6 Color Themes** — Ocean, Lavender, Emerald, Sunset, Sakura, Mono; single solid-color rings
- **Launch at Login, Remembered Position, Desktop-Level Window**
- **Accessible** — tooltips, VoiceOver labels and Reduce Motion support

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
| **Thermals and fans** | Click the **Temperature** gauge |
| **Fan boost** | **Boost** button in Thermals (admin password; pick 15s to 2m; gentle ramp up and down) |
| **Go back** | Click **<** in the detail view |
| **Quick memory clean** | **Quick** button in Memory detail (no password) |
| **Deep memory purge** | **Purge** button in Memory detail (admin password) |
| **Change theme** | Menu bar icon > **Theme** |
| **Alerts on/off** | Menu bar icon > **Alerts** |
| **Keep Mac awake** | Menu bar icon > **Keep Mac Awake** |
| **Text in menu bar** | Menu bar icon > **Stats in Menu Bar** |
| **Launch at login** | Menu bar icon > **Launch at Login** |
| **Show / Hide** | Menu bar icon > **Show Widget** / **Hide Widget** |
| **Copy IP** | Click the external or local IP address |
| **Quit** | Menu bar icon > **Quit** |

## Disk Cleanup

Click the **Disk** gauge to open the cleanup tool. It scans 19 categories; after a scan the cleanable total also appears as a badge under the disk gauge.

**Enabled by default (safe, auto-regenerates):**
- System and app caches, logs, crash reports
- macOS installer files (moved to Trash), iOS firmware files
- Incomplete downloads (moved to Trash), QuickLook cache
- Mail attachment cache, macOS wallpaper videos

**Optional (disabled by default):**
- Trash, browser caches
- Xcode (DerivedData, simulators, device support, archives)
- Package manager caches (npm, pip, Homebrew)
- Developer tool caches (Gradle, Maven, CocoaPods, Cargo, Go, Yarn, pnpm)
- Docker build cache, IDE caches (VS Code, Cursor, JetBrains)

Recoverable categories are moved to the Trash instead of being permanently deleted, and the completion screen reports that portion separately. Toggle preferences persist across restarts; categories not present on your system are hidden; every category has an info button.

## How It Works

Pure Swift/SwiftUI with no external dependencies, built with `swiftc`:

| Metric | Source |
|---|---|
| CPU Usage | Mach `host_processor_info`, 64-bit wrap-safe tick deltas |
| Memory | `vm_statistics64` via Mach |
| Disk | `FileManager` volume capacity APIs |
| Temperature | IOKit SMC reads; sensor keys discovered per chip (M1/M2/M3/M4, Intel) |
| Fans | SMC fan keys; boost via a separate admin helper binary |
| Network Speed | `getifaddrs` byte deltas across en*/bridge* interfaces |
| Ping | `/sbin/ping`, single ICMP echo to 8.8.8.8 |
| IPs | `getifaddrs` (local) and `api.ipify.org` (external) |
| Battery | IOKit power sources + AppleSmartBattery registry |
| GPU | IOAccelerator performance statistics (menu only) |
| Processes | `/bin/ps` output, parsed and grouped |

### Performance

- UI updates every **5 seconds**; disk every ~30s; IPs and battery every ~60s
- SMC key info is **cached**; temperature keys probed **once per launch**
- Published properties only update **when values change**
- Metric history lives in a separate store, so sparkline updates **do not redraw the whole widget**
- Process lists refresh only while a detail view is open; menu stats only while the menu is open (and they actually update live while it is open)
- GPU is read only while the menu is open

Typical CPU usage: **~1–2%**

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (auto-prompted on first build)
- Apple Silicon or Intel Mac

## Project Structure

```
MacMonitor/
├── MacMonitor/
│   ├── MacMonitorApp.swift      # App entry, window, menu bar, keep awake, resizing
│   ├── ContentView.swift        # Gauge grid, process lists, disk cleanup, thermals
│   ├── Components.swift         # RingGauge, Sparkline, HistoryGraph, HistoryStore
│   ├── SystemMonitor.swift      # Metrics engine, alerts, purge, themes
│   ├── DiskCleaner.swift        # Disk cleanup engine (19 categories)
│   ├── FanHelper.swift          # Admin fan control helper (separate binary)
│   └── Info.plist               # App configuration
├── build.sh                     # Terminal build script
├── Install and Run.command      # One-click build & run
├── architecture.md              # Technical architecture notes
└── memory.md                    # Working log and decisions
```

See `architecture.md` for the data flow, the run loop details and the fan helper security model.

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## License

This project is available under the [MIT License](LICENSE).
