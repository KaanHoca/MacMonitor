# MacMonitor

A lightweight, native macOS desktop widget that displays real-time system metrics — CPU, Memory, Disk, and Temperature — right on your desktop.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-supported-green)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## Features

- **2×2 Circular Gauges** — CPU usage, Memory, Disk, and CPU Temperature at a glance
- **Native macOS Look & Feel** — uses the system's visual effect materials, blends seamlessly with your desktop
- **Process Details** — tap CPU or Memory gauge to see top processes ranked by usage
- **Memory Purge** — clear inactive memory cache directly from the widget (requires admin password)
- **Real CPU Temperature** — reads actual sensor data via SMC (System Management Controller)
- **Desktop-Level Window** — stays behind app windows, always visible on your desktop
- **Menu Bar Control** — show, hide, or quit from the menu bar icon
- **Draggable** — position it anywhere on your screen

## Quick Start

**Double-click** the `Kur ve Çalıştır.command` file. That's it.

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
| **Go back** | Click **<** in the detail view |
| **Purge memory** | Click the purge button in Memory detail (admin password required) |
| **Show / Hide** | Menu bar gauge icon → **Show Widget** |
| **Quit** | Menu bar gauge icon → **Quit** |

## Auto-Launch on Login

1. Copy `MacMonitor.app` to `/Applications`
2. Go to **System Settings → General → Login Items** and add MacMonitor

## How It Works

MacMonitor is a pure Swift/SwiftUI application with no external dependencies. It collects system metrics using low-level macOS APIs:

| Metric | Source |
|---|---|
| CPU Usage | Mach kernel `processor_info` calls |
| Memory | `vm_statistics64` via Mach |
| Disk | `FileManager` volume capacity APIs |
| Temperature | IOKit SMC (System Management Controller) sensor reads |
| Processes | `/bin/ps` output, parsed and grouped |

All system calls run on background threads; the UI updates on the main thread every 3 seconds.

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (auto-prompted on first build)
- Apple Silicon or Intel Mac

## Project Structure

```
MacMonitor/
├── MacMonitor/
│   ├── MacMonitorApp.swift      # App entry point, window & menu bar setup
│   ├── ContentView.swift        # SwiftUI views, gauges & process lists
│   ├── SystemMonitor.swift      # System metrics collection engine
│   └── Info.plist               # App configuration
├── build.sh                     # Terminal build script
└── Kur ve Çalıştır.command      # One-click build & run
```

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## License

This project is available under the [MIT License](LICENSE).
