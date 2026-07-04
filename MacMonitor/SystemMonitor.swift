import Foundation
import Darwin
import IOKit
import IOKit.ps
import SwiftUI
import UserNotifications

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
    @Published var diskUsed: Double = 0   // GB
    @Published var diskFree: Double = 0   // GB
    @Published var cpuTemp: Double = 0
    @Published var systemPowerW: Double = 0   // watts, 0 = no readable power key
    @Published var cpuPowerW: Double = 0      // CPU package watts (Thermals breakdown)
    @Published var dcInPowerW: Double = 0     // DC input watts (Thermals breakdown)
    @Published var swapUsedGB: Double = 0
    @Published var swapTotalGB: Double = -1   // -1 = sysctl unavailable, hide row
    @Published var memoryPressureLevel: Int = 0  // 0 unknown, 1 normal, 2 warning, 4 critical
    @Published var diskReadMBs: Double = -1   // -1 = no sample yet, hide row
    @Published var diskWriteMBs: Double = -1
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

    // Rolling CPU/RAM/temp/fan history for sparklines and detail graphs.
    // Separate observable object so per-tick appends only redraw the graphs.
    let history = HistoryStore()

    // Fan boost state
    @Published var fanBoostActive: Bool = false
    @Published var fanBoostSecondsRemaining: Int = 0
    @Published var fanBoostNoEffect: Bool = false

    // Battery (portable Macs only; stays false on desktops)
    @Published var batteryPresent = false
    @Published var batteryPercent: Double = 0
    @Published var batteryCharging = false
    @Published var batteryHealth: Double = 0   // percent of design capacity
    @Published var batteryCycles: Int = 0

    // Disk cleaner instance — shared with ContentView
    let diskCleaner = DiskCleaner()

    // Set by ContentView to auto-refresh process lists while detail is open
    var activeDetail: String = "none"

    // Theme — persisted in UserDefaults
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    private var timer: Timer?
    private var prevCPU: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64) = (0,0,0,0)
    private var lastCPUUsage: Double = 0
    private var smcConn: io_connect_t = 0
    private var smoothedTemp: Double = 0
    private var tickCount: Int = 0
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var lastNetworkTime: Date?
    private var prevDiskRead: UInt64 = 0
    private var prevDiskWrite: UInt64 = 0
    private var lastDiskIOTime: Date?

    // Cached SMC key info — dataSize and dataType per key, queried once
    private var smcKeyInfoCache: [UInt32: (dataSize: UInt32, dataType: UInt32)] = [:]
    private var fanCount: Int = -1  // -1 = not yet queried
    private var boostTimer: Timer?
    private static let boostPercent = 75   // percent into each fan's min-max band
    static let boostDurations = [15, 30, 45, 60, 120]  // seconds, user-selectable
    private var currentBoostDuration = 30
    private var boostBaselineRPM: Double = 0
    private var boostPeakRPM: Double = 0
    private var memoryPressureActive = false

    /// User-selected boost cycle length, persisted by the Thermals picker.
    var boostDuration: Int {
        let saved = UserDefaults.standard.integer(forKey: "boostDuration")
        return Self.boostDurations.contains(saved) ? saved : 30
    }

    init() {
        // Restore saved theme
        if let saved = UserDefaults.standard.string(forKey: "theme"),
           let t = AppTheme(rawValue: saved) {
            self.theme = t
        } else {
            self.theme = .ocean
        }
        openSMC()
        updateBattery()      // sync on main so the initial window height is right
        readBatteryHealth()
        update(diskToo: true)
        updateNetworkSpeed() // seed initial bytes
        updatePing()
        updateIPs()
        let tick = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tickCount += 1
            // Disk changes rarely — check every ~30s (every 6th tick)
            self.update(diskToo: self.tickCount % 6 == 0)
            self.updateNetworkSpeed()
            self.updatePing()
            // IPs and battery change rarely — check every ~60s (every 12th tick)
            if self.tickCount % 12 == 0 {
                self.updateIPs()
                self.updateBattery()
            }
            // Auto-refresh process list while detail view is open. Skipped
            // during quick purge so our own pressure allocation does not
            // show up as the top process mid-operation.
            if self.activeDetail == "cpu" { self.fetchTopCPUProcesses() }
            else if self.activeDetail == "ram" && !self.memoryPressureActive { self.fetchTopRAMProcesses() }
        }
        // Common mode keeps ticks firing while menus are open or the window is dragged
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    /// Delivers UI mutations on the main run loop in common modes. A plain
    /// main-queue dispatch stalls during NSMenu event tracking, which froze
    /// the menu bar stats while the menu was open.
    private func publishOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            RunLoop.main.perform(inModes: [.common], block: block)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    deinit {
        timer?.invalidate()
        boostTimer?.invalidate()
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
            let power = self.getPower()
            let swap = self.getSwap()
            let pressure = self.getMemoryPressureLevel()
            self.updateDiskIO()

            self.publishOnMain {
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
                    let roundedDiskUsed = disk.usedGB.rounded()
                    if self.diskUsed != roundedDiskUsed { self.diskUsed = roundedDiskUsed }
                    let roundedFree = disk.freeGB.rounded()
                    if self.diskFree != roundedFree { self.diskFree = roundedFree }
                }

                let roundedTemp = temp.rounded()
                if self.cpuTemp != roundedTemp { self.cpuTemp = roundedTemp }

                let roundedPower = (power.system * 10).rounded() / 10
                if self.systemPowerW != roundedPower { self.systemPowerW = roundedPower }
                let roundedCPUPower = (power.cpu * 10).rounded() / 10
                if self.cpuPowerW != roundedCPUPower { self.cpuPowerW = roundedCPUPower }
                let roundedDCIn = (power.dcIn * 10).rounded() / 10
                if self.dcInPowerW != roundedDCIn { self.dcInPowerW = roundedDCIn }

                if let swap = swap {
                    let roundedSwapUsed = (swap.used * 100).rounded() / 100
                    let roundedSwapTotal = (swap.total * 100).rounded() / 100
                    if self.swapUsedGB != roundedSwapUsed { self.swapUsedGB = roundedSwapUsed }
                    if self.swapTotalGB != roundedSwapTotal { self.swapTotalGB = roundedSwapTotal }
                }
                if self.memoryPressureLevel != pressure { self.memoryPressureLevel = pressure }

                // Update fan data only when it actually changed
                if self.fans != fanData { self.fans = fanData }

                // Track the peak RPM during a boost for honest feedback
                if self.fanBoostActive, let peak = fanData.map({ $0.actualRPM }).max() {
                    self.boostPeakRPM = max(self.boostPeakRPM, peak)
                }

                self.history.append(
                    cpu: roundedCPU,
                    ram: roundedUsed,
                    temp: roundedTemp,
                    fans: fanData.map { $0.actualRPM },
                    power: roundedPower
                )

                self.checkThresholds()
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
        guard result == KERN_SUCCESS, let info = cpuInfo else { return lastCPUUsage }

        // Sum into 64-bit: the per-core kernel tick counters are 32-bit and
        // wrap on long uptimes; summing into UInt32 would overflow and trap.
        var totalUser: UInt64 = 0, totalSys: UInt64 = 0
        var totalIdle: UInt64 = 0, totalNice: UInt64 = 0

        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            totalUser += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            totalSys  += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            totalIdle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            totalNice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }

        vm_deallocate(mach_task_self_,
                      vm_address_t(bitPattern: info),
                      vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))

        let prev = prevCPU
        prevCPU = (totalUser, totalSys, totalIdle, totalNice)

        // A wrapped per-core counter can make a sum go backwards; skip that sample
        guard totalUser >= prev.user, totalSys >= prev.sys,
              totalIdle >= prev.idle, totalNice >= prev.nice else { return lastCPUUsage }

        let diffUser = totalUser - prev.user
        let diffSys  = totalSys  - prev.sys
        let diffIdle = totalIdle - prev.idle
        let diffNice = totalNice - prev.nice
        let total    = diffUser + diffSys + diffIdle + diffNice

        guard total > 0 else { return lastCPUUsage }
        lastCPUUsage = Double(diffUser + diffSys + diffNice) / Double(total) * 100.0
        return lastCPUUsage
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

    // MARK: - Swap & Memory Pressure
    private func getSwap() -> (used: Double, total: Double)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        let gb = 1024.0 * 1024.0 * 1024.0
        return (Double(usage.xsu_used) / gb, Double(usage.xsu_total) / gb)
    }

    private func getMemoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        return Int(level)
    }

    // MARK: - Disk
    private func getDisk() -> (label: String, percent: Double, usedGB: Double, freeGB: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? Int64,
              let free  = attrs[.systemFreeSize] as? Int64 else {
            return ("—", 0, 0, 0)
        }
        let used    = total - free
        let percent = Double(used) / Double(total) * 100.0
        let usedGB  = Double(used) / 1_073_741_824
        let totalGB = Double(total) / 1_073_741_824
        let freeGB  = Double(free) / 1_073_741_824
        return (String(format: "%.0f/%.0fG", usedGB, totalGB), percent, usedGB, freeGB)
    }

    // MARK: - Quick Purge (Memory Pressure)
    func quickPurgeRAM(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let usedBefore = self.getRAM().used

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

            // Allocate and touch memory in chunks to create pressure.
            // mmap/munmap instead of malloc/free: munmap returns the pages
            // to the OS immediately, so MacMonitor's own footprint drops
            // right back and it does not linger atop its own process list.
            self.memoryPressureActive = true
            let chunkSize = 64 * 1024 * 1024 // 64 MB
            var regions: [UnsafeMutableRawPointer] = []
            var allocated = 0
            while allocated < targetBytes {
                let ptr = mmap(nil, chunkSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
                guard let region = ptr, region != MAP_FAILED else { break }
                memset(region, 0xFF, chunkSize)
                regions.append(region)
                allocated += chunkSize
            }

            // Release all allocated memory back to the OS
            for region in regions { munmap(region, chunkSize) }
            self.memoryPressureActive = false

            // Brief pause for the OS to reclaim pages
            Thread.sleep(forTimeInterval: 0.5)

            // Measure the actual effect instead of assuming success
            let freedGB = max(0, usedBefore - self.getRAM().used)
            let detail = freedGB >= 0.1 ? String(format: "%.1f GB", freedGB) : nil

            self.update(diskToo: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.fetchTopRAMProcesses()
                self.purgeJustCompleted = true
            }
            self.publishOnMain { completion(true, detail) }
        }
    }

    // MARK: - Deep Purge (Admin)
    func purgeRAM(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let usedBefore = self.getRAM().used

            // Opens macOS admin password prompt via osascript
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
            do { try task.run() } catch {
                self.publishOnMain { completion(false, nil) }
                return
            }
            task.waitUntilExit()
            let success = task.terminationStatus == 0

            // Refresh data after purge and measure the actual effect
            var detail: String? = nil
            if success {
                Thread.sleep(forTimeInterval: 0.5)
                let freedGB = max(0, usedBefore - self.getRAM().used)
                if freedGB >= 0.1 { detail = String(format: "%.1f GB", freedGB) }
                self.update(diskToo: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.fetchTopRAMProcesses()
                    self.purgeJustCompleted = true
                }
            }
            self.publishOnMain { completion(success, detail) }
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
                .prefix(10)
            self.publishOnMain { self.topRAMProcesses = Array(result) }
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
                .prefix(10)
            self.publishOnMain { self.topCPUProcesses = Array(result) }
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
            publishOnMain {
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

    // MARK: - Disk I/O Speed
    private func getDiskIOBytes() -> (read: UInt64, write: UInt64)? {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iter) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var found = false
        while case let drive = IOIteratorNext(iter), drive != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(drive, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                if let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value {
                    totalRead += read
                    found = true
                }
                if let write = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value {
                    totalWrite += write
                    found = true
                }
            }
            IOObjectRelease(drive)
        }
        return found ? (totalRead, totalWrite) : nil
    }

    private func updateDiskIO() {
        let now = Date()
        guard let bytes = getDiskIOBytes() else { return }
        if let last = lastDiskIOTime {
            let elapsed = now.timeIntervalSince(last)
            // Skip the tick when counters went backwards (drive ejected or
            // counters reset); the next tick recovers with fresh baselines.
            if elapsed > 0, bytes.read >= prevDiskRead, bytes.write >= prevDiskWrite {
                let readMBs = Double(bytes.read - prevDiskRead) / elapsed / (1024 * 1024)
                let writeMBs = Double(bytes.write - prevDiskWrite) / elapsed / (1024 * 1024)
                publishOnMain {
                    let r = (readMBs * 10).rounded() / 10
                    let w = (writeMBs * 10).rounded() / 10
                    if self.diskReadMBs != r { self.diskReadMBs = r }
                    if self.diskWriteMBs != w { self.diskWriteMBs = w }
                }
            }
        }
        prevDiskRead = bytes.read
        prevDiskWrite = bytes.write
        lastDiskIOTime = now
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
                self?.publishOnMain { self?.ping = -1 }
                return
            }
            // Parse "time=12.345 ms"
            if let range = output.range(of: "time="),
               let msRange = output.range(of: " ms", range: range.upperBound..<output.endIndex) {
                let timeStr = String(output[range.upperBound..<msRange.lowerBound])
                if let ms = Double(timeStr) {
                    self?.publishOnMain {
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
        publishOnMain {
            if self.localIP != local { self.localIP = local }
        }
        // External IP — async network request
        getExternalIP { [weak self] ip in
            self?.publishOnMain {
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

    // MARK: - Battery

    private func updateBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else {
            return
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?
                    .takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let percent = maxCap > 0 ? Double(current) / Double(maxCap) * 100 : 0

            publishOnMain {
                if !self.batteryPresent { self.batteryPresent = true }
                if self.batteryPercent != percent { self.batteryPercent = percent }
                if self.batteryCharging != charging { self.batteryCharging = charging }
            }
            return
        }
    }

    private func readBatteryHealth() {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return }
        defer { IOObjectRelease(entry) }

        func intProp(_ key: String) -> Int? {
            guard let ref = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
                return nil
            }
            return (ref.takeRetainedValue() as? NSNumber)?.intValue
        }

        let cycles = intProp("CycleCount") ?? 0
        let design = intProp("DesignCapacity") ?? 0
        let nominal = intProp("NominalChargeCapacity") ?? intProp("AppleRawMaxCapacity") ?? 0
        let health = (design > 0 && nominal > 0) ? min(Double(nominal) / Double(design) * 100, 100) : 0

        publishOnMain {
            if cycles > 0 { self.batteryCycles = cycles }
            if health > 0 { self.batteryHealth = health }
        }
    }

    // MARK: - Threshold Alerts

    var alertsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "alertsEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "alertsEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "alertsEnabled") }
    }

    private var lastAlertDates: [String: Date] = [:]
    private static let alertCooldown: TimeInterval = 3600

    private func checkThresholds() {
        guard alertsEnabled else { return }
        if cpuTemp >= 100 {
            maybeAlert(
                key: "temp",
                title: "High CPU Temperature",
                body: String(format: "CPU is at %.0f°C. Heavy workloads or blocked vents can cause this.", cpuTemp)
            )
        }
        if diskPercent >= 90 {
            maybeAlert(
                key: "disk",
                title: "Disk Almost Full",
                body: String(format: "Startup disk is %.0f%% full. Open Disk Cleanup in MacMonitor to free space.", diskPercent)
            )
        }
    }

    private func maybeAlert(key: String, title: String, body: String) {
        let now = Date()
        if let last = lastAlertDates[key], now.timeIntervalSince(last) < Self.alertCooldown { return }
        lastAlertDates[key] = now
        postNotification(title: title, body: body)
    }

    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - GPU (read on demand, menu bar only)

    func readGPUUsage() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let ref = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                         kCFAllocatorDefault, 0),
               let stats = ref.takeRetainedValue() as? [String: Any] {
                for key in ["Device Utilization %", "GPU Activity(%)"] {
                    if let value = stats[key] as? Int {
                        IOObjectRelease(entry)
                        return Double(value)
                    }
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    // MARK: - Uptime & Load

    func uptimeText() -> String {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return "--" }
        let uptime = Int(Date().timeIntervalSince1970) - Int(tv.tv_sec)
        let days = uptime / 86400
        let hours = (uptime % 86400) / 3600
        let mins = (uptime % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    func loadText() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "--" }
        return String(format: "%.2f  %.2f  %.2f", loads[0], loads[1], loads[2])
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

    // Candidate CPU temperature keys across chip generations. Valid keys are
    // discovered once at runtime and cached; a fixed list broke on Intel and
    // on Apple Silicon generations newer than M1.
    private static let tempKeyCandidates: [String] = [
        // Apple Silicon M1
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        // M2
        "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j", "Tp0n", "Tp0r",
        // M3 / M4 efficiency and performance clusters
        "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tp0V", "Tp0Y", "Tp0e", "Tp02", "Tp0A",
        // Intel
        "TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TC1C", "TC2C", "TC3C", "TC4C"
    ]
    private var validTempKeys: [String]?

    private func getTemp() -> Double {
        if validTempKeys == nil {
            validTempKeys = Self.tempKeyCandidates.filter { readSMCFloat($0) != nil }
        }
        guard let keys = validTempKeys, !keys.isEmpty else { return 0 }

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

    // MARK: - Power (SMC)
    // Candidate keys per slot, discovered once at launch like temperature
    // keys. Verified by SMC probe on an M4 Mac mini: PSTR (system total),
    // PHPC (CPU package), PDTR and PD0R (DC input). Missing keys simply
    // leave their published value at 0 and the UI hides the row.
    private static let systemPowerCandidates = ["PSTR"]
    private static let cpuPowerCandidates = ["PHPC"]
    private static let dcInPowerCandidates = ["PDTR", "PD0R"]
    private var powerKeysProbed = false
    private var systemPowerKey: String?
    private var cpuPowerKey: String?
    private var dcInPowerKey: String?

    // Power-specific SMC read with plausibility validation
    private func readSMCPower(_ key: String) -> Double? {
        guard let val = readSMCValue(key) else { return nil }
        return (val >= 0 && val < 1000) ? val : nil
    }

    private func getPower() -> (system: Double, cpu: Double, dcIn: Double) {
        if !powerKeysProbed {
            powerKeysProbed = true
            systemPowerKey = Self.systemPowerCandidates.first { readSMCPower($0) != nil }
            cpuPowerKey = Self.cpuPowerCandidates.first { readSMCPower($0) != nil }
            dcInPowerKey = Self.dcInPowerCandidates.first { readSMCPower($0) != nil }
            // Cache availability so the next launch can size the window
            // correctly before the first async tick publishes a value.
            UserDefaults.standard.set(systemPowerKey != nil, forKey: "powerKeyAvailable")
        }
        let system = systemPowerKey.flatMap { readSMCPower($0) } ?? 0
        let cpu = cpuPowerKey.flatMap { readSMCPower($0) } ?? 0
        let dcIn = dcInPowerKey.flatMap { readSMCPower($0) } ?? 0
        return (system, cpu, dcIn)
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
        guard !fanBoostActive else {
            completion(false)
            return
        }
        guard !fans.isEmpty else {
            completion(false)
            return
        }
        // Find the pre-compiled FanHelper binary in the app bundle
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "FanHelper") else {
            completion(false)
            return
        }
        let duration = boostDuration
        currentBoostDuration = duration

        // Quote the helper path for the shell, then escape for the AppleScript literal.
        // The trailing "&" detaches the helper so osascript returns right after auth,
        // which lets us tell a cancelled password prompt apart from a running boost.
        // The helper computes per-fan targets from the percent and ramps gently.
        let quotedPath = "'" + helperURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let shellCmd = "\(quotedPath) boost \(Self.boostPercent) \(duration) > /dev/null 2>&1 &"
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
        fanBoostNoEffect = false
        fanBoostSecondsRemaining = currentBoostDuration
        boostBaselineRPM = fans.map { $0.actualRPM }.max() ?? 0
        boostPeakRPM = boostBaselineRPM
        boostTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.fanBoostSecondsRemaining -= 1
            if self.fanBoostSecondsRemaining <= 0 {
                timer.invalidate()
                self.finishBoost()
            }
        }
        // Common mode keeps the countdown running while menus are open
        RunLoop.main.add(timer, forMode: .common)
        boostTimer = timer
    }

    private func finishBoost() {
        fanBoostActive = false
        // Honest feedback: if the fans never sped up, say so briefly.
        // No cooldown afterwards: the admin prompt on every boost is enough
        // of a rate limiter, and high fan speed itself is not harmful.
        if boostPeakRPM < boostBaselineRPM + 150 {
            fanBoostNoEffect = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.fanBoostNoEffect = false
            }
        }
    }
}
