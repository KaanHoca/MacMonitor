import SwiftUI
import AppKit

enum DetailMode {
    case none, cpu, ram, disk, fan
}

struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var detail: DetailMode = .none
    @Namespace private var ringNS

    private var tc: ThemeColors { monitor.theme.colors }
    private let detailAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)

    var body: some View {
        Group {
            switch detail {
            case .none:
                gaugeGrid
                    .transition(.opacity)
            case .ram:
                ProcessListView(
                    title: "Memory",
                    subtitle: String(format: "%.1f / %.0f GB", monitor.usedRAM, monitor.totalRAM),
                    percent: monitor.totalRAM > 0 ? monitor.usedRAM / monitor.totalRAM : 0,
                    ringColor: tc.ring,
                    matchID: "ring-ram",
                    ns: ringNS,
                    processes: monitor.topRAMProcesses,
                    formatValue: { formatMB($0) },
                    barColor: { self.processBarColor($0, thresholds: (200, 500)) },
                    maxValue: monitor.totalRAM * 1024,
                    accent: tc.accent,
                    onBack: { closeDetail() },
                    actionIcon: "bolt.fill",
                    actionLabel: "Quick",
                    onAction: { done in monitor.quickPurgeRAM(completion: done) },
                    secondaryIcon: "lock.fill",
                    secondaryLabel: "Purge",
                    onSecondaryAction: { done in monitor.purgeRAM(completion: done) }
                )
                .transition(.opacity)
            case .cpu:
                ProcessListView(
                    title: "CPU",
                    subtitle: String(format: "%.0f%%", monitor.cpuUsage),
                    percent: monitor.cpuUsage / 100,
                    ringColor: tc.ring,
                    matchID: "ring-cpu",
                    ns: ringNS,
                    processes: monitor.topCPUProcesses,
                    formatValue: { String(format: "%.1f%%", $0) },
                    barColor: { self.processBarColor($0, thresholds: (15, 50)) },
                    maxValue: 100,
                    accent: tc.accent,
                    onBack: { closeDetail() }
                )
                .transition(.opacity)
            case .disk:
                DiskCleanupView(
                    cleaner: monitor.diskCleaner,
                    accent: tc.accent,
                    diskColor: tc.disk,
                    diskPercent: monitor.diskPercent / 100,
                    diskLabel: monitor.diskLabel,
                    matchID: "ring-disk",
                    ns: ringNS,
                    onBack: { closeDetail() },
                    onCleanComplete: { monitor.refreshDisk() }
                )
                .transition(.opacity)
            case .fan:
                ThermalsView(
                    fans: monitor.fans,
                    history: monitor.history,
                    accent: tc.accent,
                    tempColor: tc.temp,
                    currentTemp: monitor.cpuTemp,
                    boostActive: monitor.fanBoostActive,
                    boostSeconds: monitor.fanBoostSecondsRemaining,
                    boostNoEffect: monitor.fanBoostNoEffect,
                    matchID: "ring-temp",
                    ns: ringNS,
                    onBack: { closeDetail() },
                    onBoost: { done in monitor.boostFans(completion: done) }
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onChange(of: detail) { newDetail in
            let isDetail = newDetail != .none
            let height = isDetail
                ? UILayout.detailHeight
                : UILayout.mainHeight(hasBattery: monitor.batteryPresent)
            NotificationCenter.default.post(
                name: .mmResizeWindow, object: nil,
                userInfo: ["height": height, "isDetail": isDetail]
            )
        }
        .onAppear {
            // Dev hook: open MacMonitor.app --args -debugDetail cpu|ram|disk|fan
            switch UserDefaults.standard.string(forKey: "debugDetail") {
            case "cpu":
                monitor.fetchTopCPUProcesses()
                monitor.activeDetail = "cpu"
                detail = .cpu
            case "ram":
                monitor.fetchTopRAMProcesses()
                monitor.activeDetail = "ram"
                detail = .ram
            case "disk":
                detail = .disk
            case "fan":
                detail = .fan
            default:
                break
            }
            // Optional companion hook: -debugReturnAfter <seconds> closes the
            // detail again, used to verify window position restore.
            let returnAfter = UserDefaults.standard.integer(forKey: "debugReturnAfter")
            if returnAfter > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(returnAfter)) {
                    closeDetail()
                }
            }
        }
    }

    private func closeDetail() {
        monitor.activeDetail = "none"
        withAnimation(detailAnimation) { detail = .none }
    }

    var gaugeGrid: some View {
        VStack(spacing: 0) {
            // Two symmetric dial rows; captions live inside the dials
            VStack(spacing: 24) {
                HStack {
                    gaugeColumn(
                        help: "CPU usage. Click for top processes.",
                        a11y: String(format: "CPU usage %.0f percent", monitor.cpuUsage),
                        onTap: {
                            monitor.fetchTopCPUProcesses()
                            monitor.activeDetail = "cpu"
                            withAnimation(detailAnimation) { detail = .cpu }
                        },
                        gauge: {
                            GaugeCell(
                                icon: "cpu",
                                value: String(format: "%.0f%%", monitor.cpuUsage),
                                percent: monitor.cpuUsage / 100,
                                color: tc.ring,
                                warnAt: 0.85,
                                critAt: 0.95,
                                tappable: true,
                                matchID: "ring-cpu",
                                ns: ringNS
                            )
                        }
                    )

                    gaugeColumn(
                        help: "Memory usage. Click for top processes and cleanup.",
                        a11y: String(format: "Memory %.1f of %.0f gigabytes", monitor.usedRAM, monitor.totalRAM),
                        onTap: {
                            monitor.fetchTopRAMProcesses()
                            monitor.activeDetail = "ram"
                            withAnimation(detailAnimation) { detail = .ram }
                        },
                        gauge: {
                            GaugeCell(
                                icon: "memorychip",
                                value: String(format: "%.1fG", monitor.usedRAM),
                                percent: monitor.totalRAM > 0 ? monitor.usedRAM / monitor.totalRAM : 0,
                                color: tc.ring,
                                warnAt: 0.85,
                                critAt: 0.95,
                                tappable: true,
                                dropBounce: monitor.purgeJustCompleted,
                                matchID: "ring-ram",
                                ns: ringNS
                            )
                        }
                    )
                    .onChange(of: monitor.purgeJustCompleted) { newVal in
                        if newVal {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                monitor.purgeJustCompleted = false
                            }
                        }
                    }
                }

                HStack {
                    gaugeColumn(
                        help: "Disk usage. Click to scan and clean junk files.",
                        a11y: String(format: "Disk %.0f percent full", monitor.diskPercent),
                        onTap: {
                            withAnimation(detailAnimation) { detail = .disk }
                        },
                        gauge: {
                            GaugeCell(
                                icon: "internaldrive",
                                value: String(format: "%.0fG", monitor.diskUsed),
                                percent: monitor.diskPercent / 100,
                                color: tc.disk,
                                warnAt: 0.90,
                                critAt: 0.97,
                                tappable: true,
                                caption: diskCaption,
                                captionIcon: diskShowsCleanable ? "sparkles" : nil,
                                captionColor: diskShowsCleanable ? tc.accent.opacity(0.8) : Color.white.opacity(0.35),
                                matchID: "ring-disk",
                                ns: ringNS
                            )
                        }
                    )

                    gaugeColumn(
                        help: "CPU temperature. Click for thermals and fan control.",
                        a11y: monitor.cpuTemp > 0
                            ? String(format: "CPU temperature %.0f degrees", monitor.cpuTemp)
                            : "CPU temperature unavailable",
                        onTap: {
                            withAnimation(detailAnimation) { detail = .fan }
                        },
                        gauge: {
                            GaugeCell(
                                icon: "thermometer.medium",
                                value: monitor.cpuTemp > 0 ? String(format: "%.0f°C", monitor.cpuTemp) : "--",
                                percent: monitor.cpuTemp > 0 ? min(monitor.cpuTemp / 100, 1.0) : 0,
                                color: tc.temp,
                                warnAt: 0.85,
                                critAt: 0.95,
                                tappable: true,
                                caption: monitor.fans.isEmpty
                                    ? nil
                                    : String(format: "%d rpm", Int(avgFanRPM.rounded())),
                                captionIcon: monitor.fans.isEmpty ? nil : "fan.fill",
                                captionColor: tc.temp.opacity(0.7),
                                matchID: "ring-temp",
                                ns: ringNS
                            )
                        }
                    )
                }
            }

            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            // Network stats row
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(tc.accent.opacity(0.6))
                    Text(formatSpeed(monitor.downloadSpeed))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 11))
                        .foregroundStyle(pingColor(monitor.ping).opacity(0.6))
                    Text(monitor.ping < 0 ? "---" : String(format: "%.0fms", monitor.ping))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(tc.accent.opacity(0.6))
                    Text(formatSpeed(monitor.uploadSpeed))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)

            Spacer().frame(height: 10)

            // IP addresses row
            HStack(spacing: 8) {
                CopyableIPCell(
                    icon: "globe",
                    ip: monitor.externalIP,
                    accent: tc.accent
                )

                CopyableIPCell(
                    icon: "wifi",
                    ip: monitor.localIP,
                    accent: tc.accent
                )
            }
            .padding(.horizontal, 4)

            // Battery row (portable Macs only)
            if monitor.batteryPresent {
                Spacer().frame(height: 8)
                HStack(spacing: 5) {
                    Image(systemName: batteryIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(tc.accent.opacity(0.6))
                    Text(String(format: "%.0f%%", monitor.batteryPercent))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                    if monitor.batteryCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow.opacity(0.8))
                    }

                    Spacer()

                    if monitor.batteryHealth > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "heart")
                                .font(.system(size: 9))
                            Text(String(format: "%.0f%%", monitor.batteryHealth))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.45))
                        .help("Battery health relative to design capacity")
                    }
                    if monitor.batteryCycles > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9))
                            Text(String(format: "%d", monitor.batteryCycles))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.45))
                        .help("Battery cycle count")
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(20)
    }

    private var batteryIcon: String {
        if monitor.batteryCharging { return "battery.100.bolt" }
        switch monitor.batteryPercent {
        case 80...: return "battery.100"
        case 55..<80: return "battery.75"
        case 30..<55: return "battery.50"
        case 10..<30: return "battery.25"
        default: return "battery.0"
        }
    }

    // One dial column: a single tap target and accessibility element.
    private func gaugeColumn<G: View>(
        help: String,
        a11y: String,
        onTap: @escaping () -> Void,
        @ViewBuilder gauge: () -> G
    ) -> some View {
        gauge()
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11y)
            .accessibilityAddTraits(.isButton)
    }

    private var avgFanRPM: Double {
        guard !monitor.fans.isEmpty else { return 0 }
        return monitor.fans.map { $0.actualRPM }.reduce(0, +) / Double(monitor.fans.count)
    }

    // Disk dial caption: cleanable size once a scan ran, free space otherwise
    private var diskShowsCleanable: Bool {
        monitor.diskCleaner.hasScanned && monitor.diskCleaner.totalCleanableSize > 100_000_000
    }

    private var diskCaption: String? {
        if diskShowsCleanable {
            return DiskCleaner.formatSize(monitor.diskCleaner.totalCleanableSize)
        }
        return monitor.diskFree > 0 ? String(format: "%.0fG free", monitor.diskFree) : nil
    }

    func processBarColor(_ value: Double, thresholds: (Double, Double)) -> Color {
        if value >= thresholds.1 { return Color(red: 0.9, green: 0.3, blue: 0.3) }
        if value >= thresholds.0 { return Color(red: 0.95, green: 0.65, blue: 0.3) }
        return tc.accent
    }

    func formatMB(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    // KB/s value → formatted string
    func formatSpeed(_ kbps: Double) -> String {
        if kbps < 1 { return "0 K/s" }
        if kbps >= 1024 { return String(format: "%.1f M/s", kbps / 1024) }
        return String(format: "%.0f K/s", kbps)
    }

    func pingColor(_ ms: Double) -> Color {
        if ms < 0 { return .gray }
        if ms < 50 { return .green }
        if ms < 100 { return .yellow }
        return .orange
    }
}

// MARK: - Process List View
struct ProcessListView: View {
    let title: String
    let subtitle: String
    let percent: Double
    let ringColor: Color
    let matchID: String
    let ns: Namespace.ID
    let processes: [ProcessEntry]
    let formatValue: (Double) -> String
    let barColor: (Double) -> Color
    var maxValue: Double = 1
    var accent: Color = .cyan
    var onBack: () -> Void
    var actionIcon: String? = nil
    var actionLabel: String? = nil
    var onAction: ((@escaping (Bool, String?) -> Void) -> Void)? = nil
    var secondaryIcon: String? = nil
    var secondaryLabel: String? = nil
    var onSecondaryAction: ((@escaping (Bool, String?) -> Void) -> Void)? = nil
    @State private var actionState: ActionState = .idle
    @State private var actionDetail: String? = nil
    @State private var spinAngle: Double = 0
    @State private var secondaryState: ActionState = .idle
    @State private var secondaryDetail: String? = nil
    @State private var secondarySpinAngle: Double = 0

    enum ActionState { case idle, running, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(
                title: title,
                value: subtitle,
                percent: percent,
                color: ringColor,
                matchID: matchID,
                ns: ns,
                onBack: onBack
            )

            // Section label
            Text("TOP PROCESSES")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.leading, 2)
                .padding(.bottom, 8)

            // Process list
            if processes.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .colorScheme(.dark)
                    Text("Loading...")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(Array(processes.enumerated()), id: \.element.id) { index, proc in
                            processRow(index: index, proc: proc)
                        }
                    }
                }
            }

            // Action bar
            if actionIcon != nil || actionLabel != nil || secondaryIcon != nil || secondaryLabel != nil {
                actionBar
            }
        }
        .padding(16)
    }

    private func processRow(index: Int, proc: ProcessEntry) -> some View {
        HStack(spacing: 8) {
            // Rank badge
            Text("\(index + 1)")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 16, height: 16)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(proc.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(formatValue(proc.value))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(barColor(proc.value).opacity(0.9))
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [barColor(proc.value).opacity(0.6), barColor(proc.value)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, geo.size.width * CGFloat(proc.value / maxValue)), height: 3)
                            .animation(.easeInOut(duration: 0.4), value: proc.value)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.vertical, 2)
    }

    private func actionButton(
        icon: String, label: String?,
        state: ActionState, detail: String?, spin: Double,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Group {
                    switch state {
                    case .idle:
                        Image(systemName: icon)
                            .foregroundStyle(.white)
                    case .running:
                        Image(systemName: icon)
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(spin))
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.system(size: 10, weight: .semibold))

                if let label = label {
                    // When finished, show the measured result (e.g. "1.2 GB") if available
                    Text(state == .done ? (detail ?? "Done") : label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(state == .done ? Color.green.opacity(0.3) : accent.opacity(0.3))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(state == .running)
    }

    private var actionBar: some View {
        HStack {
            Spacer()

            if let icon = actionIcon {
                actionButton(icon: icon, label: actionLabel, state: actionState, detail: actionDetail, spin: spinAngle) {
                    guard actionState == .idle else { return }
                    withAnimation { actionState = .running }
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        spinAngle = 360
                    }
                    onAction? { success, detail in
                        withAnimation {
                            spinAngle = 0
                            actionDetail = detail
                            actionState = success ? .done : .idle
                        }
                        if success {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { actionState = .idle }
                            }
                        }
                    }
                }
            }

            if let icon = secondaryIcon {
                actionButton(icon: icon, label: secondaryLabel, state: secondaryState, detail: secondaryDetail, spin: secondarySpinAngle) {
                    guard secondaryState == .idle else { return }
                    withAnimation { secondaryState = .running }
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        secondarySpinAngle = 360
                    }
                    onSecondaryAction? { success, detail in
                        withAnimation {
                            secondarySpinAngle = 0
                            secondaryDetail = detail
                            secondaryState = success ? .done : .idle
                        }
                        if success {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { secondaryState = .idle }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 10)
    }
}

// MARK: - Gauge Cell

/// One dial of the grid. Geometry is fixed and identical for every cell:
/// hover feedback only brightens the unlit ticks and the icon, it never
/// scales, blurs or shadows the dial, so all four always render equal.
struct GaugeCell: View {
    let icon: String
    let value: String
    let percent: Double
    let color: Color
    var warnAt: Double? = nil
    var critAt: Double? = nil
    var tappable: Bool = false
    var dropBounce: Bool = false
    var caption: String? = nil
    var captionIcon: String? = nil
    var captionColor: Color = Color.white.opacity(0.35)
    let matchID: String
    let ns: Namespace.ID

    @State private var isHovered = false
    @State private var bounceOffset: CGFloat = 0
    @State private var bounceScale: CGFloat = 1.0

    private let dialSize: CGFloat = 100

    var body: some View {
        ZStack {
            TickGauge(
                percent: percent,
                color: color,
                warnAt: warnAt,
                critAt: critAt,
                highlight: isHovered && tappable
            )
            .matchedGeometryEffect(id: matchID, in: ns)
            .animation(.easeOut(duration: 0.7), value: percent)

            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(isHovered && tappable ? 0.8 : 0.5))
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let caption = caption {
                    HStack(spacing: 2) {
                        if let captionIcon = captionIcon {
                            Image(systemName: captionIcon)
                                .font(.system(size: 7))
                        }
                        Text(caption)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(captionColor)
                    .padding(.top, 1)
                }
            }
            // Capped to the dial's inner circle so text can never touch the ticks
            .frame(maxWidth: 64)
            .animation(.easeOut(duration: 0.2), value: isHovered)
        }
        .frame(width: dialSize, height: dialSize)
        .scaleEffect(bounceScale)
        .offset(y: bounceOffset)
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: dropBounce) { newVal in
            if newVal {
                // Drop down + squish
                withAnimation(.easeIn(duration: 0.25)) {
                    bounceOffset = 8
                    bounceScale = 0.92
                }
                // Bounce back up with spring
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 8)) {
                        bounceOffset = 0
                        bounceScale = 1.0
                    }
                }
            }
        }
    }
}


// MARK: - Copyable IP Cell
struct CopyableIPCell: View {
    let icon: String
    var label: String = ""
    let ip: String
    let accent: Color

    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: copied ? "checkmark.circle.fill" : icon)
                .font(.system(size: 10))
                .foregroundStyle(copied ? .green : accent.opacity(0.5))
            Text(copied ? "Copied!" : ip)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(copied ? .green.opacity(0.8) : .white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .scaleEffect(copied ? 1.03 : 1.0)
        .onTapGesture {
            guard ip != "---" && ip != "—" && !copied else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            withAnimation(.easeOut(duration: 0.2)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeIn(duration: 0.2)) { copied = false }
            }
        }
    }
}

// MARK: - Thermals View

struct ThermalsView: View {
    let fans: [FanInfo]
    @ObservedObject var history: HistoryStore
    let accent: Color
    let tempColor: Color
    let currentTemp: Double
    let boostActive: Bool
    let boostSeconds: Int
    let boostNoEffect: Bool
    let matchID: String
    let ns: Namespace.ID
    let onBack: () -> Void
    let onBoost: (@escaping (Bool) -> Void) -> Void

    @State private var boostState: BoostButtonState = .idle
    @State private var spinAngle: Double = 0
    @AppStorage("boostDuration") private var boostDuration = 30

    enum BoostButtonState { case idle, running, done, failed }

    private var maxRPM: Double {
        fans.map { $0.maxRPM }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(
                title: "Thermals",
                value: currentTemp > 0 ? String(format: "%.0f°C", currentTemp) : "--",
                percent: currentTemp > 0 ? min(currentTemp / 100, 1.0) : 0,
                color: tempColor,
                matchID: matchID,
                ns: ns,
                onBack: onBack
            )

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // Temperature history
                    if history.temp.count > 1 {
                        sectionLabel("CPU TEMPERATURE")
                        HistoryGraph(series: [history.temp], maxValue: 0, color: tempColor)
                            .frame(height: 56)
                        HStack {
                            Text(String(format: "min %.0f°", history.temp.min() ?? 0))
                            Spacer()
                            Text(String(format: "max %.0f°", history.temp.max() ?? 0))
                        }
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                    } else if currentTemp <= 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "thermometer.medium.slash")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.25))
                            Text("No readable temperature sensor on this Mac.")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.vertical, 6)
                    }

                    if fans.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "fan.slash")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.25))
                            Text("This Mac is passively cooled (no fans).")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.top, 4)
                    } else {
                        sectionLabel("FANS")
                            .padding(.top, 4)
                        ForEach(fans) { fan in
                            fanCard(fan)
                        }

                        if history.fanRPM.first?.count ?? 0 > 1 {
                            sectionLabel("RPM HISTORY")
                                .padding(.top, 4)
                            HistoryGraph(series: history.fanRPM, maxValue: maxRPM, color: accent)
                                .frame(height: 56)
                        }
                    }
                }
            }

            if !fans.isEmpty {
                actionBar
            }
        }
        .padding(16)
        .onChange(of: boostActive) { active in
            if !active && boostState == .running {
                withAnimation { boostState = boostNoEffect ? .failed : .done }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation { boostState = .idle }
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.25))
            .padding(.leading, 2)
    }

    private func fanCard(_ fan: FanInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "fan.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(accent.opacity(0.7))
                Text("Fan \(fan.id + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                Text(String(format: "%.0f RPM", fan.actualRPM))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }

            // RPM bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent.opacity(0.6))
                        .frame(width: max(4, geo.size.width * CGFloat(fan.maxRPM > 0 ? fan.actualRPM / fan.maxRPM : 0)))
                        .animation(.easeInOut(duration: 0.4), value: fan.actualRPM)
                }
            }
            .frame(height: 3)

            // Min / Max labels
            HStack {
                Text(String(format: "Min: %.0f", fan.minRPM))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                Text(String(format: "Max: %.0f", fan.maxRPM))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
    }

    private var actionBar: some View {
        HStack {
            // Countdown while boosting, duration picker otherwise
            if boostActive {
                Text(countdownText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent.opacity(0.7))
            } else {
                durationMenu
            }

            Spacer()

            Button {
                guard boostState == .idle, !boostActive else { return }
                withAnimation { boostState = .running }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
                onBoost { success in
                    if !success {
                        withAnimation {
                            spinAngle = 0
                            boostState = .idle
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Group {
                        switch boostState {
                        case .idle:
                            Image(systemName: "wind")
                                .foregroundStyle(.white)
                        case .running:
                            Image(systemName: "fan.fill")
                                .foregroundStyle(.white)
                                .rotationEffect(.degrees(spinAngle))
                        case .done:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))

                    Text(boostLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(boostBackground)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(boostState != .idle || boostActive)
        }
        .padding(.top, 10)
    }

    private var countdownText: String {
        boostSeconds >= 60
            ? String(format: "%d:%02d", boostSeconds / 60, boostSeconds % 60)
            : "\(boostSeconds)s"
    }

    private func durationLabel(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60)m" : "\(seconds)s"
    }

    private var durationMenu: some View {
        Menu {
            ForEach(SystemMonitor.boostDurations, id: \.self) { d in
                Button {
                    boostDuration = d
                } label: {
                    if d == boostDuration {
                        Label(durationLabel(d), systemImage: "checkmark")
                    } else {
                        Text(durationLabel(d))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.system(size: 8, weight: .semibold))
                Text(durationLabel(boostDuration))
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06))
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(boostState != .idle)
        .help("Boost duration")
    }

    private var boostLabel: String {
        if boostState == .done { return "Done" }
        if boostState == .failed { return "No effect" }
        if boostActive { return "Boosting" }
        return "Boost"
    }

    private var boostBackground: Color {
        if boostState == .done { return Color.green.opacity(0.3) }
        if boostState == .failed { return Color.orange.opacity(0.2) }
        return accent.opacity(0.3)
    }
}

// MARK: - Disk Cleanup View

struct DiskCleanupView: View {
    @ObservedObject var cleaner: DiskCleaner
    let accent: Color
    let diskColor: Color
    let diskPercent: Double
    let diskLabel: String
    let matchID: String
    let ns: Namespace.ID
    let onBack: () -> Void
    var onCleanComplete: (() -> Void)? = nil

    @State private var showResetConfirm = false

    // Split categories into recommended (default on) and optional (default off)
    private var recommendedCategories: [CleanupCategory] {
        cleaner.categories.filter { $0.defaultEnabled && cleaner.isCategoryAvailable($0) }
    }
    private var optionalCategories: [CleanupCategory] {
        cleaner.categories.filter { !$0.defaultEnabled && cleaner.isCategoryAvailable($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            diskCleanupHeader

            if cleaner.isScanning || cleaner.isCleaning {
                // Progress state
                progressSection
            } else if cleaner.cleanJustCompleted {
                // Completion state
                completionSection
            } else if !cleaner.hasScanned {
                // Initial state — prompt to scan
                scanPromptSection
            } else {
                // Category list
                categoryListSection
            }
        }
        .padding(16)
    }

    // MARK: - Header

    private var headerValue: String {
        if cleaner.hasScanned && !cleaner.isScanning && !cleaner.isCleaning && !cleaner.cleanJustCompleted {
            return DiskCleaner.formatSize(cleaner.totalCleanableSize)
        }
        return diskLabel
    }

    private var diskCleanupHeader: some View {
        DetailHeader(
            title: "Disk Cleanup",
            value: headerValue,
            percent: diskPercent,
            color: diskColor,
            matchID: matchID,
            ns: ns,
            onBack: {
                cleaner.cleanJustCompleted = false
                onBack()
            }
        )
    }

    // MARK: - Scan Prompt

    private var scanPromptSection: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(accent.opacity(0.5))

            Text("Scan your disk to find\ncleanable files.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)

            Button {
                cleaner.scanAll()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Scan")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .background(accent.opacity(0.3))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 14) {
            Spacer()

            // Spinning indicator
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 4)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: cleaner.isScanning ? cleaner.scanProgress : cleaner.cleanProgress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: cleaner.isScanning ? cleaner.scanProgress : cleaner.cleanProgress)

                Image(systemName: cleaner.isCleaning ? "trash" : "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(accent.opacity(0.7))
            }

            Text(cleaner.isScanning ? "Scanning..." : "Cleaning...")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            if cleaner.isCleaning && cleaner.lastCleanedSize > 0 {
                Text(DiskCleaner.formatSize(cleaner.lastCleanedSize) + " freed")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(accent.opacity(0.7))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Completion

    private var completionSection: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text(DiskCleaner.formatSize(cleaner.lastCleanedSize))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            Text("cleaned successfully")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))

            if cleaner.lastTrashedSize > 0 {
                Text(DiskCleaner.formatSize(cleaner.lastTrashedSize) + " of it is in the Trash, recoverable")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }

            Button {
                cleaner.cleanJustCompleted = false
            } label: {
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 7)
                    .background(accent.opacity(0.3))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Category List

    private var categoryListSection: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    // Recommended section
                    sectionHeader("Recommended")
                    ForEach(recommendedCategories) { cat in
                        CategoryRow(category: cat, cleaner: cleaner, accent: accent)
                    }

                    // Optional section
                    if !optionalCategories.isEmpty {
                        sectionHeader("Optional")
                            .padding(.top, 6)
                        ForEach(optionalCategories) { cat in
                            CategoryRow(category: cat, cleaner: cleaner, accent: accent)
                        }
                    }
                }
            }

            // Bottom action bar
            bottomActionBar
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.3))
            .textCase(.uppercase)
            .padding(.leading, 2)
            .padding(.bottom, 2)
    }

    private var bottomActionBar: some View {
        HStack(spacing: 6) {
            // Reset all toggles to defaults
            Button {
                cleaner.resetAllToDefaults()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Reset")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Re-scan disk
            Button {
                cleaner.scanAll()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Rescan")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Spacer()

            // Clean selected categories
            Button {
                cleaner.cleanEnabled { _ in onCleanComplete?() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                    Text("Clean")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(cleaner.totalCleanableSize > 0 ? accent.opacity(0.4) : Color.white.opacity(0.08))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(cleaner.totalCleanableSize <= 0)
        }
        .padding(.top, 10)
    }
}

// MARK: - Category Row

struct CategoryRow: View {
    let category: CleanupCategory
    @ObservedObject var cleaner: DiskCleaner
    let accent: Color

    @State private var showInfo: Bool = false
    private var size: Int64 { cleaner.sizes[category.id] ?? 0 }
    private var isDefault: Bool { cleaner.isDefaultValue(category.id) }
    private var isOn: Bool { cleaner.isEnabled(category.id) }

    // Bound straight to the cleaner so Reset buttons update rows immediately;
    // local @State would survive redraws and keep showing stale values.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { cleaner.isEnabled(category.id) },
            set: { cleaner.setEnabled(category.id, $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Toggle
                Toggle("", isOn: toggleBinding)
                    .toggleStyle(CleanupToggleStyle(accent: accent))
                    .labelsHidden()

                // Icon
                Image(systemName: category.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(isOn ? accent.opacity(0.8) : .white.opacity(0.3))
                    .frame(width: 14)

                // Name
                Text(category.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isOn ? .white.opacity(0.8) : .white.opacity(0.4))
                    .lineLimit(1)

                // Info button
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showInfo.toggle() }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(showInfo ? 0.5 : 0.2))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 2)

                // Changed from default indicator
                if !isDefault {
                    Circle()
                        .fill(accent.opacity(0.5))
                        .frame(width: 4, height: 4)
                }

                // Size
                Text(size > 0 ? DiskCleaner.formatSize(size) : "---")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(size > 1_073_741_824 ? .orange : (size > 104_857_600 ? accent : .white.opacity(0.4)))
                    .frame(width: 52, alignment: .trailing)
            }

            // Info detail text
            if showInfo {
                Text(category.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 50)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }
}

// MARK: - Custom Toggle Style

struct CleanupToggleStyle: ToggleStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(configuration.isOn ? accent.opacity(0.4) : Color.white.opacity(0.08))
                .frame(width: 28, height: 16)
                .overlay(
                    Circle()
                        .fill(configuration.isOn ? accent : Color.white.opacity(0.4))
                        .frame(width: 12, height: 12)
                        .offset(x: configuration.isOn ? 6 : -6)
                        .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
                )
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}
