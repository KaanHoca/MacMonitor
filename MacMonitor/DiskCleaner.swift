import Foundation
import SwiftUI

// MARK: - Cleanup Category Model

struct CleanupPath {
    let path: String           // directory or file path (supports ~ prefix)
    let pattern: String?       // optional glob pattern filter (e.g. "*.crdownload")
    let recursive: Bool        // scan subdirectories

    init(_ path: String, pattern: String? = nil, recursive: Bool = true) {
        self.path = path
        self.pattern = pattern
        self.recursive = recursive
    }
}

struct CleanupCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let detail: String         // short description for the user
    let defaultEnabled: Bool
    let paths: [CleanupPath]
    let detector: [String]     // paths to check if category is relevant on this system
}

// MARK: - Disk Cleaner

class DiskCleaner: ObservableObject {
    @Published var sizes: [String: Int64] = [:]
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var scanProgress: Double = 0
    @Published var cleanProgress: Double = 0
    @Published var lastCleanedSize: Int64 = 0
    @Published var cleanJustCompleted = false

    let categories: [CleanupCategory] = DiskCleaner.buildCategories()
    private let fm = FileManager.default
    private let home = NSHomeDirectory()

    // MARK: - Toggle Persistence

    func isEnabled(_ categoryId: String) -> Bool {
        let key = "diskClean_\(categoryId)"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return categories.first { $0.id == categoryId }?.defaultEnabled ?? false
    }

    func setEnabled(_ categoryId: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "diskClean_\(categoryId)")
        objectWillChange.send()
    }

    func isDefaultValue(_ categoryId: String) -> Bool {
        let key = "diskClean_\(categoryId)"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        let current = UserDefaults.standard.bool(forKey: key)
        let def = categories.first { $0.id == categoryId }?.defaultEnabled ?? false
        return current == def
    }

    func resetToDefault(_ categoryId: String) {
        UserDefaults.standard.removeObject(forKey: "diskClean_\(categoryId)")
        objectWillChange.send()
    }

    func resetAllToDefaults() {
        for cat in categories {
            UserDefaults.standard.removeObject(forKey: "diskClean_\(cat.id)")
        }
        objectWillChange.send()
    }

    // MARK: - Availability Check

    func isCategoryAvailable(_ category: CleanupCategory) -> Bool {
        if category.detector.isEmpty { return true }
        for path in category.detector {
            let expanded = expandPath(path)
            if fm.fileExists(atPath: expanded) { return true }
        }
        return false
    }

    // MARK: - Scanning

    func scanAll() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        sizes = [:]

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let available = self.categories.filter { self.isCategoryAvailable($0) }
            let total = available.count

            for (index, cat) in available.enumerated() {
                let size = self.scanCategory(cat)
                DispatchQueue.main.async {
                    self.sizes[cat.id] = size
                    self.scanProgress = Double(index + 1) / Double(max(total, 1))
                }
            }

            DispatchQueue.main.async {
                self.isScanning = false
                self.scanProgress = 1.0
            }
        }
    }

    func scanCategory(_ category: CleanupCategory) -> Int64 {
        var totalSize: Int64 = 0
        for cleanupPath in category.paths {
            let expanded = expandPath(cleanupPath.path)
            guard fm.fileExists(atPath: expanded) else { continue }

            if let pattern = cleanupPath.pattern {
                // Scan with pattern matching
                totalSize += sizeOfMatchingFiles(in: expanded, pattern: pattern)
            } else if cleanupPath.recursive {
                totalSize += sizeOfDirectory(expanded)
            } else {
                totalSize += sizeOfItem(expanded)
            }
        }
        return totalSize
    }

    // MARK: - Cleaning

    func cleanEnabled(completion: @escaping (Int64) -> Void) {
        guard !isCleaning else { return }
        isCleaning = true
        cleanProgress = 0
        lastCleanedSize = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let enabledCats = self.categories.filter {
                self.isCategoryAvailable($0) && self.isEnabled($0.id) && (self.sizes[$0.id] ?? 0) > 0
            }
            let total = enabledCats.count
            var cleaned: Int64 = 0

            for (index, cat) in enabledCats.enumerated() {
                let freed = self.cleanCategory(cat)
                cleaned += freed
                DispatchQueue.main.async {
                    self.cleanProgress = Double(index + 1) / Double(max(total, 1))
                    self.lastCleanedSize = cleaned
                }
            }

            DispatchQueue.main.async {
                self.isCleaning = false
                self.cleanProgress = 1.0
                self.lastCleanedSize = cleaned
                self.cleanJustCompleted = true

                // Re-scan to update sizes
                self.scanAll()

                completion(cleaned)
            }
        }
    }

    private func cleanCategory(_ category: CleanupCategory) -> Int64 {
        var freed: Int64 = 0
        for cleanupPath in category.paths {
            let expanded = expandPath(cleanupPath.path)
            guard fm.fileExists(atPath: expanded) else { continue }

            if let pattern = cleanupPath.pattern {
                freed += removeMatchingFiles(in: expanded, pattern: pattern)
            } else {
                freed += removeContents(of: expanded)
            }
        }
        return freed
    }

    // MARK: - File Operations

    private func sizeOfDirectory(_ path: String) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func sizeOfItem(_ path: String) -> Int64 {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    private func sizeOfMatchingFiles(in directory: String, pattern: String) -> Int64 {
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }
        var total: Int64 = 0
        for name in contents where matchesPattern(name, pattern: pattern) {
            let fullPath = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir) {
                total += isDir.boolValue ? sizeOfDirectory(fullPath) : sizeOfItem(fullPath)
            }
        }
        return total
    }

    private func removeContents(of directory: String) -> Int64 {
        guard isPathSafe(directory) else { return 0 }
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }
        var freed: Int64 = 0
        for name in contents {
            let fullPath = (directory as NSString).appendingPathComponent(name)
            let size = sizeOfItemOrDir(fullPath)
            do {
                try fm.removeItem(atPath: fullPath)
                freed += size
            } catch {
                // Skip items we can't remove (permission denied, in use, etc.)
            }
        }
        return freed
    }

    private func removeMatchingFiles(in directory: String, pattern: String) -> Int64 {
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }
        var freed: Int64 = 0
        for name in contents where matchesPattern(name, pattern: pattern) {
            let fullPath = (directory as NSString).appendingPathComponent(name)
            // Check safety per file — allows /Applications/Install macOS*.app
            guard isPathSafe(fullPath) else { continue }
            let size = sizeOfItemOrDir(fullPath)
            do {
                try fm.removeItem(atPath: fullPath)
                freed += size
            } catch {
                // Skip items we can't remove
            }
        }
        return freed
    }

    private func sizeOfItemOrDir(_ path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        return isDir.boolValue ? sizeOfDirectory(path) : sizeOfItem(path)
    }

    // MARK: - Safety

    private func isPathSafe(_ path: String) -> Bool {
        let expanded = expandPath(path)
        // Block dangerous root paths
        let blocked = ["/", "/System", "/usr", "/bin", "/sbin", "/var",
                       home, "\(home)/Documents", "\(home)/Desktop",
                       "\(home)/Pictures", "\(home)/Music", "\(home)/Movies",
                       "\(home)/Library", "\(home)/Library/Keychains",
                       "\(home)/.ssh", "\(home)/.gnupg"]
        if blocked.contains(expanded) { return false }
        // Must be inside home Library, system tmp, or /Applications
        let allowed = ["\(home)/Library/", "\(home)/.Trash/", "\(home)/.npm/",
                       "\(home)/.cache/", "\(home)/.gradle/", "\(home)/.m2/",
                       "\(home)/.cargo/", "\(home)/go/", "\(home)/.composer/",
                       "\(home)/Downloads/",
                       "/private/tmp/", "/private/var/tmp/",
                       "/Library/Application Support/com.apple.idleassetsd/",
                       "/Library/Logs/DiagnosticReports/",
                       "/Applications/Install macOS"]
        return allowed.contains { expanded.hasPrefix($0) }
    }

    // MARK: - Helpers

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    private func matchesPattern(_ name: String, pattern: String) -> Bool {
        // Simple glob: "*.ext" or "*.{ext1,ext2}"
        if pattern.hasPrefix("*.") {
            let ext = String(pattern.dropFirst(2))
            if ext.hasPrefix("{") && ext.hasSuffix("}") {
                let exts = ext.dropFirst().dropLast().split(separator: ",").map { String($0) }
                return exts.contains { name.hasSuffix(".\($0)") }
            }
            return name.hasSuffix(".\(ext)")
        }
        // fnmatch handles wildcards like "Install macOS*.app"
        return fnmatch(pattern, name, 0) == 0
    }

    // MARK: - Formatting

    static func formatSize(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        if bytes < 1_048_576 { return String(format: "%.0f KB", Double(bytes) / 1_024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    var totalCleanableSize: Int64 {
        categories.filter { isEnabled($0.id) && isCategoryAvailable($0) }
            .compactMap { sizes[$0.id] }
            .reduce(0, +)
    }

    var hasScanned: Bool {
        !sizes.isEmpty
    }

    // MARK: - Category Definitions

    private static func buildCategories() -> [CleanupCategory] {
        return [
            // ── Default ON ──────────────────────────────────────────────
            CleanupCategory(
                id: "systemCaches",
                name: "System & App Caches",
                icon: "folder.badge.gearshape",
                detail: "Temporary files that apps recreate automatically.",
                defaultEnabled: true,
                paths: [
                    CleanupPath("~/Library/Caches"),
                    CleanupPath("~/Library/Application Support/Spotify/PersistentCache"),
                    CleanupPath("~/Library/Application Support/Slack/Cache"),
                    CleanupPath("~/Library/Application Support/Slack/Service Worker/CacheStorage"),
                    CleanupPath("~/Library/Application Support/discord/Cache"),
                    CleanupPath("~/Library/Application Support/discord/GPUCache"),
                    CleanupPath("~/Library/Application Support/Microsoft Teams/Cache"),
                    CleanupPath("~/Library/Application Support/Microsoft Teams/GPUCache"),
                ],
                detector: []
            ),
            CleanupCategory(
                id: "systemLogs",
                name: "System & App Logs",
                icon: "doc.text",
                detail: "Old log files from apps and macOS.",
                defaultEnabled: true,
                paths: [
                    CleanupPath("~/Library/Logs"),
                ],
                detector: []
            ),
            CleanupCategory(
                id: "crashReports",
                name: "Crash Reports",
                icon: "exclamationmark.triangle",
                detail: "Diagnostic reports from app crashes.",
                defaultEnabled: true,
                paths: [
                    CleanupPath("~/Library/DiagnosticReports"),
                    CleanupPath("/Library/Logs/DiagnosticReports"),
                ],
                detector: []
            ),
            CleanupCategory(
                id: "macosInstallers",
                name: "macOS Installers",
                icon: "arrow.down.app",
                detail: "Old macOS installer apps (12+ GB each).",
                defaultEnabled: true,
                paths: [
                    CleanupPath("/Applications", pattern: "Install macOS*.app", recursive: false),
                ],
                detector: []
            ),
            CleanupCategory(
                id: "iosFirmware",
                name: "iOS Firmware Files",
                icon: "iphone.gen3",
                detail: "Downloaded iOS update files, no longer needed.",
                defaultEnabled: true,
                paths: [
                    CleanupPath("~/Library/iTunes/iPhone Software Updates"),
                    CleanupPath("~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware"),
                ],
                detector: [
                    "~/Library/iTunes/iPhone Software Updates",
                    "~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator"
                ]
            ),
            CleanupCategory(
                id: "incompleteDownloads",
                name: "Incomplete Downloads",
                icon: "exclamationmark.arrow.circlepath",
                detail: "Failed or interrupted download files.",
                defaultEnabled: true,
                paths: [
                    CleanupPath("~/Downloads", pattern: "*.crdownload", recursive: false),
                    CleanupPath("~/Downloads", pattern: "*.download", recursive: false),
                    CleanupPath("~/Downloads", pattern: "*.part", recursive: false),
                ],
                detector: []
            ),
            CleanupCategory(
                id: "quicklookCache",
                name: "QuickLook Cache",
                icon: "eye",
                detail: "File preview thumbnails, regenerated on demand.",
                defaultEnabled: true,
                paths: [
                    CleanupPath("~/Library/Caches/com.apple.QuickLook.thumbnailcache"),
                ],
                detector: []
            ),
            CleanupCategory(
                id: "mailAttachments",
                name: "Mail Attachments Cache",
                icon: "envelope",
                detail: "Cached copies of email attachments.",
                defaultEnabled: true,
                paths: [
                    CleanupPath("~/Library/Mail Downloads"),
                    CleanupPath("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                ],
                detector: [
                    "~/Library/Mail Downloads",
                    "~/Library/Containers/com.apple.mail"
                ]
            ),
            CleanupCategory(
                id: "wallpaperVideos",
                name: "macOS Wallpaper Videos",
                icon: "photo.artframe",
                detail: "Aerial screensaver videos, re-downloaded if needed.",
                defaultEnabled: true,
                paths: [
                    CleanupPath("/Library/Application Support/com.apple.idleassetsd/Customer"),
                ],
                detector: ["/Library/Application Support/com.apple.idleassetsd/Customer"]
            ),

            // ── Default OFF ─────────────────────────────────────────────
            CleanupCategory(
                id: "trash",
                name: "Trash",
                icon: "trash",
                detail: "Files you have already deleted. Cannot be undone.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/.Trash"),
                ],
                detector: []
            ),
            CleanupCategory(
                id: "browserCaches",
                name: "Browser Caches",
                icon: "globe",
                detail: "Cached web data. Logins stay intact.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/Library/Caches/com.apple.Safari"),
                    CleanupPath("~/Library/Caches/Google/Chrome"),
                    CleanupPath("~/Library/Application Support/Google/Chrome/Default/Application Cache"),
                    CleanupPath("~/Library/Application Support/Google/Chrome/Default/GPUCache"),
                    CleanupPath("~/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage"),
                    CleanupPath("~/Library/Application Support/Google/Chrome/ShaderCache"),
                    CleanupPath("~/Library/Caches/com.microsoft.edgemac"),
                    CleanupPath("~/Library/Application Support/Microsoft Edge/Default/GPUCache"),
                    CleanupPath("~/Library/Application Support/Microsoft Edge/Default/Service Worker/CacheStorage"),
                    CleanupPath("~/Library/Caches/Firefox"),
                    CleanupPath("~/Library/Caches/company.thebrowser.Browser"),
                    CleanupPath("~/Library/Caches/BraveSoftware/Brave-Browser"),
                    CleanupPath("~/Library/Caches/com.operasoftware.Opera"),
                    CleanupPath("~/Library/Caches/com.vivaldi.Vivaldi"),
                ],
                detector: []
            ),
            CleanupCategory(
                id: "xcodeDerivedData",
                name: "Xcode DerivedData",
                icon: "hammer",
                detail: "Build artifacts. Projects will rebuild when opened.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/Library/Developer/Xcode/DerivedData"),
                ],
                detector: ["/Applications/Xcode.app", "~/Library/Developer/Xcode"]
            ),
            CleanupCategory(
                id: "xcodeSimulators",
                name: "Xcode Simulators",
                icon: "iphone",
                detail: "Simulator cache data. Xcode recreates if needed.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/Library/Developer/CoreSimulator/Caches"),
                ],
                detector: ["/Applications/Xcode.app", "~/Library/Developer/CoreSimulator"]
            ),
            CleanupCategory(
                id: "xcodeDeviceSupport",
                name: "Xcode Device Support",
                icon: "desktopcomputer",
                detail: "Debug symbols for old iOS versions.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/Library/Developer/Xcode/iOS DeviceSupport"),
                    CleanupPath("~/Library/Developer/Xcode/watchOS DeviceSupport"),
                    CleanupPath("~/Library/Developer/Xcode/tvOS DeviceSupport"),
                ],
                detector: ["/Applications/Xcode.app", "~/Library/Developer/Xcode/iOS DeviceSupport"]
            ),
            CleanupCategory(
                id: "xcodeArchives",
                name: "Xcode Archives",
                icon: "archivebox",
                detail: "Old build archives for App Store submissions.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/Library/Developer/Xcode/Archives"),
                ],
                detector: ["~/Library/Developer/Xcode/Archives"]
            ),
            CleanupCategory(
                id: "packageManagerCaches",
                name: "Package Manager Caches",
                icon: "shippingbox",
                detail: "npm, pip, Homebrew download caches. Not your projects.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/.npm/_cacache"),
                    CleanupPath("~/.npm/_logs"),
                    CleanupPath("~/Library/Caches/pip"),
                    CleanupPath("~/Library/Caches/Homebrew"),
                ],
                detector: ["~/.npm", "~/Library/Caches/pip", "~/Library/Caches/Homebrew"]
            ),
            CleanupCategory(
                id: "devToolCaches",
                name: "Dev Tool Caches",
                icon: "wrench.and.screwdriver",
                detail: "Gradle, Maven, CocoaPods, Cargo, Go, Yarn caches.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/.gradle/caches"),
                    CleanupPath("~/.m2/repository"),
                    CleanupPath("~/Library/Caches/CocoaPods"),
                    CleanupPath("~/.cargo/registry/cache"),
                    CleanupPath("~/Library/Caches/go-build"),
                    CleanupPath("~/.cache/yarn"),
                    CleanupPath("~/Library/pnpm/store"),
                    CleanupPath("~/.composer/cache"),
                ],
                detector: ["~/.gradle", "~/.m2", "~/.cargo", "~/Library/Caches/CocoaPods",
                           "~/.cache/yarn", "~/Library/pnpm", "~/.composer"]
            ),
            CleanupCategory(
                id: "dockerData",
                name: "Docker Data",
                icon: "cube.box",
                detail: "Docker build cache. Images stay intact.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/Library/Containers/com.docker.docker/Data/cache"),
                ],
                detector: [
                    "~/Library/Containers/com.docker.docker",
                    "/Applications/Docker.app"
                ]
            ),
            CleanupCategory(
                id: "ideCaches",
                name: "IDE Caches",
                icon: "chevrons.left.right.dotted",
                detail: "VS Code, Cursor, JetBrains performance caches.",
                defaultEnabled: false,
                paths: [
                    CleanupPath("~/Library/Application Support/Code/Cache"),
                    CleanupPath("~/Library/Application Support/Code/CachedData"),
                    CleanupPath("~/Library/Application Support/Code/CachedExtensions"),
                    CleanupPath("~/Library/Application Support/Cursor/Cache"),
                    CleanupPath("~/Library/Application Support/Cursor/CachedData"),
                    CleanupPath("~/.cache/JetBrains"),
                ],
                detector: [
                    "~/Library/Application Support/Code",
                    "~/Library/Application Support/Cursor",
                    "~/.cache/JetBrains",
                    "/Applications/Visual Studio Code.app"
                ]
            ),
        ]
    }
}
