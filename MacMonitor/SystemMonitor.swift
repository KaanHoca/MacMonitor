import Foundation
import Darwin
import IOKit
import SwiftUI

// MARK: - Theme

struct ThemeColors {
    let ring: Color       // primary ring color for CPU & RAM gauges
    let accent: Color     // UI highlights, buttons, process bars
    let disk: Color       // disk gauge ring color
    let temp: Color       // temperature gauge ring color
}

enum AppTheme: String, CaseIterable {
    case ocean    = "Ocean"
    case purple   = "Lavender"
    case green    = "Emerald"
    case sunset   = "Sunset"
    case rose     = "Sakura"
    case mono     = "Mono"

    var colors: ThemeColors {
        switch self {
        case .ocean:
            return ThemeColors(
                ring:   Color(red: 0.35, green: 0.72, blue: 0.95),
                accent: Color(red: 0.35, green: 0.72, blue: 0.95),
                disk:   Color(red: 0.38, green: 0.55, blue: 0.85),
                temp:   Color(red: 0.28, green: 0.76, blue: 0.82)
            )
        case .purple:
            return ThemeColors(
                ring:   Color(red: 0.68, green: 0.48, blue: 0.93),
                accent: Color(red: 0.68, green: 0.48, blue: 0.93),
                disk:   Color(red: 0.52, green: 0.44, blue: 0.82),
                temp:   Color(red: 0.76, green: 0.56, blue: 0.86)
            )
        case .green:
            return ThemeColors(
                ring:   Color(red: 0.30, green: 0.78, blue: 0.55),
                accent: Color(red: 0.30, green: 0.78, blue: 0.55),
                disk:   Color(red: 0.24, green: 0.65, blue: 0.62),
                temp:   Color(red: 0.42, green: 0.82, blue: 0.65)
            )
        case .sunset:
            return ThemeColors(
                ring:   Color(red: 0.95, green: 0.62, blue: 0.30),
                accent: Color(red: 0.95, green: 0.62, blue: 0.30),
                disk:   Color(red: 0.84, green: 0.48, blue: 0.34),
                temp:   Color(red: 0.92, green: 0.72, blue: 0.38)
            )
        case .rose:
            return ThemeColors(
                ring:   Color(red: 0.92, green: 0.45, blue: 0.62),
                accent: Color(red: 0.92, green: 0.45, blue: 0.62),
                disk:   Color(red: 0.78, green: 0.38, blue: 0.55),
                temp:   Color(red: 0.95, green: 0.58, blue: 0.68)
            )
        case .mono:
            return ThemeColors(
                ring:   Color.white.opacity(0.68),
                accent: Color.white,
                disk:   Color.white.opacity(0.52),
                temp:   Color.white.opacity(0.58)
            )
        }
    }
}

struct ProcessEntry: Identifiable {
    var id: String { name }
    let name: String
    let value: Double  // MB (ram) or % (cpu)
}

struct FanInfo: Identifiable, Equatable {
    let id: Int          // fan index (0, 1, ...)
    var actualRPM: Double
    var minRPM: Double
    var maxRPM: Double
}

class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var usedRAM: Double = 0
    @Published var totalRAM: Double = 0
    @Published var diskPercent: Double = 0
    @Published var diskLabel: String = "—"
    @Published var cpuTemp: Double = 0
    @Published var topRAMProcesses: [ProcessEntry] = []
    @Published var topCPUProcesses: [ProcessEntry] = []
    @Published var purgeJustCompleted: Bool = false
    @Published var downloadSpeed: Double = 0  // bytes/sec
    @Published var uploadSpeed: Double = 0    // bytes/sec
    @Published var ping: Double = 0           // ms
    @Published var localIP: String = "—"
    @Published var externalIP: String = "—"

    // Fan monitoring
    @Published var fans: [FanInfo] = []
    @Published var fanHistory: [[Double]] = []   // RPM history per fan, last 60 readings

    // Fan boost state
    @Published var fanBoostActive: Bool = false
    @Published var fanBoostSecondsRemaining: Int = 0
    @Published var fanBoostCooldownRemaining: Int = 0

    // Disk cleaner instance — shared with ContentView
    let diskCleaner = DiskCleaner()

    // Set by ContentView to auto-refresh process lists while detail is open
    var activeDetail: String = "none"

    // Theme — persisted in UserDefaults
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    private var timer: Timer?
    private var prevCPU: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32) = (0,0,0,0)
    private var smcConn: io_connect_t = 0
    private var smoothedTemp: Double = 0
    private var tickCount: Int = 0
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var lastNetworkTime: Date?

    // Cached SMC key info — dataSize and dataType per key, queried once
    private var smcKeyInfoCache: [UInt32: (dataSize: UInt32, dataType: UInt32)] = [:]
    private var fanCount: Int = -1  // -1 = not yet queried
    private var boostTimer: Timer?
    private var cooldownTimer: Timer?
    private let cooldownKey = "fanBoostCooldownEnd"
    private static let boostDuration = 30  // seconds, matches the helper invocation

    init() {
        // Restore saved theme
        if let saved = UserDefaults.standard.string(forKey: "theme"),
           let t = AppTheme(rawValue: saved) {
            self.theme = t
        } else {
            self.theme = .ocean
        }
        openSMC()
        update(diskToo: true)
        updateNetworkSpeed() // seed initial bytes
        updatePing()
        updateIPs()
        restoreCooldownState()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tickCount += 1
            // Disk changes rarely — check every ~30s (every 6th tick)
            self.update(diskToo: self.tickCount % 6 == 0)
            self.updateNetworkSpeed()
            self.updatePing()
            // IPs change rarely — check every ~60s (every 12th tick)
            if self.tickCount % 12 == 0 { self.updateIPs() }
            // Auto-refresh process list while detail view is open
            if self.activeDetail == "cpu" { self.fetchTopCPUProcesses() }
            else if self.activeDetail == "ram" { self.fetchTopRAMProcesses() }
        }
    }

    deinit {
        timer?.invalidate()
        boostTimer?.invalidate()
        cooldownTimer?.invalidate()
        if smcConn != 0 { IOServiceClose(smcConn) }
    }

    /// Refresh disk stats after cleanup
    func refreshDisk() {
        update(diskToo: true)
    }

    private func update(diskToo: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cpu  = self.getCPU()
            let ram  = self.getRAM()
            let disk = diskToo ? self.getDisk() : nil
            let temp = self.getTemp()
            let fanData = self.getFans()

            DispatchQueue.main.async {
                // Only update published properties when values actually changed
                let roundedCPU = (cpu * 10).rounded() / 10
                if self.cpuUsage != roundedCPU { self.cpuUsage = roundedCPU }

                let roundedUsed = (ram.used * 100).rounded() / 100
                if self.usedRAM != roundedUsed { self.usedRAM = roundedUsed }

                if self.totalRAM != ram.total { self.totalRAM = ram.total }

                if let disk = disk {
                    let roundedDisk = (disk.percent * 10).rounded() / 10
                    if self.diskPercent != roundedDisk { self.diskPercent = roundedDisk }
                    if self.diskLabel != disk.label { self.diskLabel = disk.label }
                }

                let roundedTemp = temp.rounded()
                if self.cpuTemp != roundedTemp { self.cpuTemp = roundedTemp }

                // Update fan data only when it actually changed
                if self.fans != fanData { self.fans = fanData }

                // Append to history (keep last 60 readings), skip on fanless Macs
                if !fanData.isEmpty {
                    if self.fanHistory.count != fanData.count {
                        self.fanHistory = fanData.map { _ in [] }
                    }
                    for (i, fan) in fanData.enumerated() {
                        self.fanHistory[i].append(fan.actualRPM)
                        if self.fanHistory[i].count > 60 {
                            self.fanHistory[i].removeFirst()
                        }
                    }
                }
            }
        }
    }

    // MARK: - CPU
    private func getCPU() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }

        var totalUser: UInt32 = 0, totalSys: UInt32 = 0
        var totalIdle: UInt32 = 0, totalNice: UInt32 = 0

        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            totalUser += UInt32(info[base + Int(CPU_STATE_USER)])
            totalSys  += UInt32(info[base + Int(CPU_STATE_SYSTEM)])
            totalIdle += UInt32(info[base + Int(CPU_STATE_IDLE)])
            totalNice += UInt32(info[base + Int(CPU_STATE_NICE)])
        }

        vm_deallocate(mach_task_self_,
                      vm_address_t(bitPattern: info),
                      vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))

        let prev = prevCPU
        let diffUser = totalUser - prev.user
        let diffSys  = totalSys  - prev.sys
        let diffIdle = totalIdle - prev.idle
        let diffNice = totalNice - prev.nice
        let total    = diffUser + diffSys + diffIdle + diffNice

        prevCPU = (totalUser, totalSys, totalIdle, totalNice)
        guard total > 0 else { return 0 }
        return Double(diffUser + diffSys + diffNice) / Double(total) * 100.0
    }

    // MARK: - RAM
    private func getRAM() -> (used: Double, total: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }

        let pageSize   = Double(vm_page_size)
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let usedBytes  = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * pageSize

        return (usedBytes / 1_073_741_824, totalBytes / 1_073_741_824)
    }

    // MARK: - Disk
    private func getDisk() -> (label: String, percent: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? Int64,
              let free  = attrs[.systemFreeSize] as? Int64 else {
            return ("—", 0)
        }
        let used    = total - free
        let percent = Double(used) / Double(total) * 100.0
        let usedGB  = Double(used) / 1_073_741_824
        let totalGB = Double(total) / 1_073_741_824
        return (String(format: "%.0f/%.0fG", usedGB, totalGB), percent)
    }

    // MARK: - Quick Purge (Memory Pressure)
    func quickPurgeRAM(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Read VM stats to determine reclaimable memory
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
            )
            let kr = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }

            let pageSize = Int(vm_page_size)
            var targetBytes: Int
            if kr == KERN_SUCCESS {
                let reclaimable = Int(
                    stats.free_count + stats.inactive_count + stats.purgeable_count
                ) * pageSize
                targetBytes = reclaimable * 8 / 10
            } else {
                targetBytes = Int(ProcessInfo.processInfo.physicalMemory) / 2
            }
            let maxTarget = Int(ProcessInfo.processInfo.physicalMemory) * 3 / 4
            targetBytes = min(targetBytes, maxTarget)

            // Allocate and touch memory in chunks to create pressure
            let chunkSize = 64 * 1024 * 1024 // 64 MB
            var allocations: [UnsafeMutableRawPointer] = []
            var allocated = 0
            while allocated < targetBytes {
                guard let ptr = malloc(chunkSize) else { break }
                memset(ptr, 0xFF, chunkSize)
                allocations.append(ptr)
                allocated += chunkSize
            }

            // Release all allocated memory
            for ptr in allocations { free(ptr) }

            // Brief pause for the OS to reclaim pages
            Thread.sleep(forTimeInterval: 0.5)

            self?.update(diskToo: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.fetchTopRAMProcesses()
                self?.purgeJustCompleted = true
            }
            DispatchQueue.main.async { completion(true) }
        }
    }

    // MARK: - Deep Purge (Admin)
    func purgeRAM(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Opens macOS admin password prompt via osascript
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(false) }
                return
            }
            task.waitUntilExit()
            let success = task.terminationStatus == 0
            // Refresh data after purge
            if success {
                self?.update(diskToo: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.fetchTopRAMProcesses()
                    self?.purgeJustCompleted = true
                }
            }
            DispatchQueue.main.async { completion(success) }
        }
    }

    // MARK: - Process Name Grouping
    private func groupName(for path: String) -> String {
        // Known process groups
        if path.contains("CoreSimulator") || path.contains(".simruntime") {
            return "iOS Simulator"
        }
        if path.contains("Google Chrome Helper") {
            return "Chrome Helper"
        }
        if path.contains("Claude Helper") {
            return "Claude Helper"
        }
        if path.contains("Creative Cloud") {
            return "Creative Cloud"
        }
        if path.contains("Xcode") && path.contains("/PlugIns/") {
            return "Xcode"
        }
        return (path as NSString).lastPathComponent
    }

    // MARK: - Top Processes (RAM)
    func fetchTopRAMProcesses() {
        runPS(args: ["-eo", "rss,comm", "-r"]) { [weak self] lines in
            guard let self = self else { return }
            var merged: [String: Double] = [:]
            for line in lines {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let kb = Double(parts[0]) else { continue }
                let mb = kb / 1024
                guard mb >= 5 else { continue }
                let name = self.groupName(for: String(parts[1]))
                merged[name, default: 0] += mb
            }
            let result = merged
                .map { ProcessEntry(name: $0.key, value: $0.value) }
                .sorted { $0.value > $1.value }
                .prefix(8)
            DispatchQueue.main.async { self.topRAMProcesses = Array(result) }
        }
    }

    // MARK: - Top Processes (CPU)
    func fetchTopCPUProcesses() {
        runPS(args: ["-eo", "%cpu,comm", "-r"]) { [weak self] lines in
            guard let self = self else { return }
            var merged: [String: Double] = [:]
            for line in lines {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let cpu = Double(parts[0]), cpu > 0.1 else { continue }
                let name = self.groupName(for: String(parts[1]))
                merged[name, default: 0] += cpu
            }
            let result = merged
                .map { ProcessEntry(name: $0.key, value: $0.value) }
                .sorted { $0.value > $1.value }
                .prefix(8)
            DispatchQueue.main.async { self.topCPUProcesses = Array(result) }
        }
    }

    private func runPS(args: [String], completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = args
            // Force C locale for consistent decimal separator
            task.environment = ["LC_ALL": "C"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return }
            let lines = output.components(separatedBy: "\n").dropFirst().map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            completion(lines)
        }
    }

    // MARK: - Network Speed
    private func getNetworkBytes() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if (name.hasPrefix("en") || name.hasPrefix("bridge")),
               p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
               let data = p.pointee.ifa_data {
                let ifData = data.assumingMemoryBound(to: if_data.self)
                totalIn += UInt64(ifData.pointee.ifi_ibytes)
                totalOut += UInt64(ifData.pointee.ifi_obytes)
            }
            ptr = p.pointee.ifa_next
        }
        return (totalIn, totalOut)
    }

    private func updateNetworkSpeed() {
        let now = Date()
        let bytes = getNetworkBytes()

        if let lastTime = lastNetworkTime, prevBytesIn > 0 {
            let elapsed = now.timeIntervalSince(lastTime)
            guard elapsed > 0 else { return }
            let dlSpeed = Double(bytes.bytesIn.subtractingReportingOverflow(prevBytesIn).overflow ? 0 : bytes.bytesIn - prevBytesIn) / elapsed
            let ulSpeed = Double(bytes.bytesOut.subtractingReportingOverflow(prevBytesOut).overflow ? 0 : bytes.bytesOut - prevBytesOut) / elapsed
            DispatchQueue.main.async {
                let roundedDL = (dlSpeed / 1024 * 10).rounded() / 10
                let roundedUL = (ulSpeed / 1024 * 10).rounded() / 10
                if self.downloadSpeed != roundedDL { self.downloadSpeed = roundedDL }
                if self.uploadSpeed != roundedUL { self.uploadSpeed = roundedUL }
            }
        }
        prevBytesIn = bytes.bytesIn
        prevBytesOut = bytes.bytesOut
        lastNetworkTime = now
    }

    // MARK: - Ping
    private func updatePing() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/sbin/ping")
            task.arguments = ["-c", "1", "-t", "3", "8.8.8.8"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return }
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
                DispatchQueue.main.async { self?.ping = -1 }
                return
            }
            // Parse "time=12.345 ms"
            if let range = output.range(of: "time="),
               let msRange = output.range(of: " ms", range: range.upperBound..<output.endIndex) {
                let timeStr = String(output[range.upperBound..<msRange.lowerBound])
                if let ms = Double(timeStr) {
                    DispatchQueue.main.async {
                        let rounded = (ms * 10).rounded() / 10
                        if self?.ping != rounded { self?.ping = rounded }
                    }
                }
            }
        }
    }

    // MARK: - IP Addresses

    private func updateIPs() {
        // Local IP — synchronous, lightweight
        let local = getLocalIP()
        DispatchQueue.main.async {
            if self.localIP != local { self.localIP = local }
        }
        // External IP — async network request
        getExternalIP { [weak self] ip in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.externalIP != ip { self.externalIP = ip }
            }
        }
    }

    private func getLocalIP() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "—" }
        defer { freeifaddrs(ifaddr) }

        var result: String? = nil
        var fallback: String? = nil
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && isRunning && !isLoopback,
               p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: p.pointee.ifa_name)
                var addr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(p.pointee.ifa_addr,
                            socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                            &addr, socklen_t(addr.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: addr)
                // Prefer en0 (Wi-Fi / Ethernet primary)
                if name == "en0" { return ip }
                if name.hasPrefix("en") && result == nil { result = ip }
                if fallback == nil { fallback = ip }
            }
            ptr = p.pointee.ifa_next
        }
        return result ?? fallback ?? "—"
    }

    private func getExternalIP(completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://api.ipify.org") else {
            completion("—")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data = data,
                  let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ip.isEmpty else {
                completion("—")
                return
            }
            completion(ip)
        }.resume()
    }

    // MARK: - Temperature (SMC)
    private struct SMCKeyData {
        struct vers_t { var major: UInt8=0; var minor: UInt8=0; var build: UInt8=0; var reserved: UInt8=0; var release: UInt16=0 }
        struct pLimitData { var version: UInt16=0; var length: UInt16=0; var cpuPLimit: UInt32=0; var gpuPLimit: UInt32=0; var memPLimit: UInt32=0 }
        struct keyInfo_t { var dataSize: UInt32=0; var dataType: UInt32=0; var dataAttributes: UInt8=0 }
        var key: UInt32=0; var vers=vers_t(); var pLimitData=pLimitData(); var keyInfo=keyInfo_t()
        var padding: UInt16=0; var result: UInt8=0; var status: UInt8=0; var data8: UInt8=0; var data32: UInt32=0
        var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
                   (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for c in s.utf8 { r = (r << 8) | UInt32(c) }
        return r
    }

    private func openSMC() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        IOServiceOpen(svc, mach_task_self_, 0, &smcConn)
        IOObjectRelease(svc)
    }

    // General-purpose SMC read supporting multiple data types
    private func readSMCValue(_ key: String) -> Double? {
        guard smcConn != 0 else { return nil }
        let keyCode = fourCC(key)

        // Get key info (cached — never changes for a given key)
        let dataSize: UInt32
        let dataType: UInt32
        if let cached = smcKeyInfoCache[keyCode] {
            dataSize = cached.dataSize
            dataType = cached.dataType
        } else {
            var inData = SMCKeyData()
            var outData = SMCKeyData()
            inData.key = keyCode
            inData.data8 = 9 // kSMCGetKeyInfo
            var outSize = MemoryLayout<SMCKeyData>.size
            let kr = IOConnectCallStructMethod(smcConn, 2, &inData, MemoryLayout<SMCKeyData>.size, &outData, &outSize)
            guard kr == kIOReturnSuccess, outData.keyInfo.dataSize > 0 else { return nil }
            dataSize = outData.keyInfo.dataSize
            dataType = outData.keyInfo.dataType
            smcKeyInfoCache[keyCode] = (dataSize, dataType)
        }

        // Read value
        var inRead = SMCKeyData()
        var outRead = SMCKeyData()
        inRead.key = keyCode
        inRead.keyInfo.dataSize = dataSize
        inRead.data8 = 5 // kSMCReadKey
        var outSize = MemoryLayout<SMCKeyData>.size
        let kr = IOConnectCallStructMethod(smcConn, 2, &inRead, MemoryLayout<SMCKeyData>.size, &outRead, &outSize)
        guard kr == kIOReturnSuccess else { return nil }

        // Decode based on data type
        let fltType  = fourCC("flt ")
        let fpe2Type = fourCC("fpe2")
        let ui8Type  = fourCC("ui8 ")
        let ui16Type = fourCC("ui16")

        if dataType == fltType && dataSize == 4 {
            // IEEE 754 float (Apple Silicon)
            let val = withUnsafePointer(to: outRead.bytes) { ptr in
                ptr.withMemoryRebound(to: Float32.self, capacity: 1) { $0.pointee }
            }
            return Double(val)
        } else if dataType == fpe2Type && dataSize >= 2 {
            // Fixed-point 14.2 (Intel) — big-endian
            let raw = (UInt16(outRead.bytes.0) << 8) | UInt16(outRead.bytes.1)
            return Double(raw) / 4.0
        } else if dataType == ui8Type {
            return Double(outRead.bytes.0)
        } else if dataType == ui16Type && dataSize >= 2 {
            let raw = (UInt16(outRead.bytes.0) << 8) | UInt16(outRead.bytes.1)
            return Double(raw)
        } else if dataSize == 4 {
            // Fallback: try float
            let val = withUnsafePointer(to: outRead.bytes) { ptr in
                ptr.withMemoryRebound(to: Float32.self, capacity: 1) { $0.pointee }
            }
            return Double(val)
        }
        return nil
    }

    // Temperature-specific SMC read with range validation
    private func readSMCFloat(_ key: String) -> Double? {
        guard let val = readSMCValue(key) else { return nil }
        return (val > 0 && val < 130) ? val : nil
    }

    private func getTemp() -> Double {
        // Average across all cores
        let keys = ["Tp09", "Tp01", "Tp02", "Tp05", "Tp0A"]
        var sum: Double = 0
        var count: Double = 0
        for key in keys {
            if let t = readSMCFloat(key) {
                sum += t
                count += 1
            }
        }
        guard count > 0 else { return smoothedTemp }
        let avg = sum / count

        // Exponential moving average — smooth out spikes
        if smoothedTemp == 0 {
            smoothedTemp = avg
        } else {
            smoothedTemp = smoothedTemp * 0.6 + avg * 0.4
        }
        return smoothedTemp
    }

    // MARK: - Fan Reading
    private func getFans() -> [FanInfo] {
        // Query fan count once (FNum key)
        if fanCount < 0 {
            if let count = readSMCValue("FNum") {
                fanCount = Int(count)
            } else {
                fanCount = 0
            }
        }
        guard fanCount > 0 else { return [] }

        var result: [FanInfo] = []
        for i in 0..<fanCount {
            let actual = readSMCValue("F\(i)Ac") ?? 0
            let minRPM = readSMCValue("F\(i)Mn") ?? 0
            let maxRPM = readSMCValue("F\(i)Mx") ?? 0
            result.append(FanInfo(id: i, actualRPM: actual, minRPM: minRPM, maxRPM: maxRPM))
        }
        return result
    }

    // MARK: - Fan Boost
    func boostFans(completion: @escaping (Bool) -> Void) {
        guard !fanBoostActive, fanBoostCooldownRemaining <= 0 else {
            completion(false)
            return
        }
        guard let maxRPM = fans.map({ $0.maxRPM }).max(), maxRPM > 0 else {
            completion(false)
            return
        }
        // Find the pre-compiled FanHelper binary in the app bundle
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "FanHelper") else {
            completion(false)
            return
        }
        let targetRPM = Int(maxRPM * 0.9)

        // Quote the helper path for the shell, then escape for the AppleScript literal.
        // The trailing "&" detaches the helper so osascript returns right after auth,
        // which lets us tell a cancelled password prompt apart from a running boost.
        let quotedPath = "'" + helperURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let shellCmd = "\(quotedPath) boost \(targetRPM) \(Self.boostDuration) > /dev/null 2>&1 &"
        let scriptSrc = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(scriptSrc)\" with administrator privileges"]
        task.terminationHandler = { [weak self] process in
            let authorized = process.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(false)
                    return
                }
                if authorized {
                    self.startBoostCountdown()
                }
                completion(authorized)
            }
        }
        do {
            try task.run()
        } catch {
            task.terminationHandler = nil
            DispatchQueue.main.async { completion(false) }
        }
    }

    private func startBoostCountdown() {
        fanBoostActive = true
        fanBoostSecondsRemaining = Self.boostDuration
        boostTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.fanBoostSecondsRemaining -= 1
            if self.fanBoostSecondsRemaining <= 0 {
                timer.invalidate()
                self.fanBoostActive = false
                self.startCooldown()
            }
        }
        // Common mode keeps the countdown running while menus are open
        RunLoop.main.add(timer, forMode: .common)
        boostTimer = timer
    }

    private func startCooldown() {
        let cooldownDuration: TimeInterval = 15 * 60
        let cooldownEnd = Date().addingTimeInterval(cooldownDuration)
        UserDefaults.standard.set(cooldownEnd.timeIntervalSince1970, forKey: cooldownKey)
        fanBoostCooldownRemaining = Int(cooldownDuration)
        startCooldownTimer()
    }

    private func restoreCooldownState() {
        let savedEnd = UserDefaults.standard.double(forKey: cooldownKey)
        guard savedEnd > 0 else { return }
        let remaining = savedEnd - Date().timeIntervalSince1970
        if remaining > 0 {
            fanBoostCooldownRemaining = Int(remaining)
            startCooldownTimer()
        }
    }

    private func startCooldownTimer() {
        cooldownTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.fanBoostCooldownRemaining -= 1
            if self.fanBoostCooldownRemaining <= 0 {
                timer.invalidate()
                self.fanBoostCooldownRemaining = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cooldownTimer = timer
    }
}
