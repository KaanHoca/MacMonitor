import SwiftUI

enum DetailMode {
    case none, cpu, ram
}

struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var detail: DetailMode = .none

    private var tc: ThemeColors { monitor.theme.colors }

    var body: some View {
        Group {
            switch detail {
            case .none:
                gaugeGrid
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            case .ram:
                ProcessListView(
                    title: "Memory Usage",
                    subtitle: String(format: "%.1f/%.0f GB", monitor.usedRAM, monitor.totalRAM),
                    processes: monitor.topRAMProcesses,
                    formatValue: { formatMB($0) },
                    barColor: { self.processBarColor($0, thresholds: (200, 500)) },
                    maxValue: monitor.totalRAM * 1024,
                    accent: tc.accent,
                    onBack: {
                        monitor.activeDetail = "none"
                        withAnimation(.easeInOut(duration: 0.25)) { detail = .none }
                    },
                    actionIcon: "arrow.triangle.2.circlepath",
                    onAction: { done in monitor.purgeRAM(completion: done) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .cpu:
                ProcessListView(
                    title: "CPU Usage",
                    subtitle: String(format: "%%%.0f", monitor.cpuUsage),
                    processes: monitor.topCPUProcesses,
                    formatValue: { String(format: "%.1f%%", $0) },
                    barColor: { self.processBarColor($0, thresholds: (15, 50)) },
                    maxValue: 100,
                    accent: tc.accent,
                    onBack: {
                        monitor.activeDetail = "none"
                        withAnimation(.easeInOut(duration: 0.25)) { detail = .none }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    var gaugeGrid: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                GaugeCell(
                    icon: "cpu",
                    label: "CPU",
                    value: String(format: "%.0f%%", monitor.cpuUsage),
                    percent: monitor.cpuUsage / 100,
                    gradient: tintGradient(monitor.cpuUsage),
                    tappable: true
                )
                .onTapGesture {
                    monitor.fetchTopCPUProcesses()
                    monitor.activeDetail = "cpu"
                    withAnimation(.easeInOut(duration: 0.25)) { detail = .cpu }
                }

                GaugeCell(
                    icon: "memorychip",
                    label: "Memory",
                    value: String(format: "%.1fG", monitor.usedRAM),
                    percent: monitor.totalRAM > 0 ? monitor.usedRAM / monitor.totalRAM : 0,
                    gradient: tintGradient(monitor.totalRAM > 0 ? monitor.usedRAM / monitor.totalRAM * 100 : 0),
                    tappable: true,
                    dropBounce: monitor.purgeJustCompleted
                )
                .onTapGesture {
                    monitor.fetchTopRAMProcesses()
                    monitor.activeDetail = "ram"
                    withAnimation(.easeInOut(duration: 0.25)) { detail = .ram }
                }
                .onChange(of: monitor.purgeJustCompleted) { newVal in
                    if newVal {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            monitor.purgeJustCompleted = false
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                GaugeCell(
                    icon: "internaldrive",
                    label: "Disk",
                    value: monitor.diskLabel,
                    percent: monitor.diskPercent / 100,
                    gradient: Gradient(colors: [tc.disk.0, tc.disk.0])
                )
                GaugeCell(
                    icon: "thermometer.medium",
                    label: "Temp",
                    value: String(format: "%.0f°C", monitor.cpuTemp),
                    percent: min(monitor.cpuTemp / 100, 1.0),
                    gradient: tempGradient(monitor.cpuTemp)
                )
            }
        }
        .padding(20)
    }

    // Ring is a single solid color at low values.
    // As value rises, only the tip gradually warms up.
    // low → solid base | mid → base..warm tip | high → base..hot tip
    func tintGradient(_ pct: Double) -> Gradient {
        let tip = blendedTip(pct, midStart: 40, highStart: 70)
        return Gradient(colors: [tc.low.0, tip])
    }

    func tempGradient(_ temp: Double) -> Gradient {
        if temp <= 50 {
            return Gradient(colors: [tc.temp, tc.temp])
        } else if temp <= 75 {
            let t = (temp - 50) / 25.0
            let tip = lerp(tc.temp, .orange, t)
            return Gradient(colors: [tc.temp, tip])
        } else {
            let t = min((temp - 75) / 25.0, 1.0)
            let tip = lerp(.orange, .red, t)
            return Gradient(colors: [tc.temp, tip])
        }
    }

    private func blendedTip(_ value: Double, midStart: Double, highStart: Double) -> Color {
        // Below midStart → tip = base color (solid ring, no gradient visible)
        if value <= midStart {
            return tc.low.0
        } else if value <= highStart {
            let t = (value - midStart) / (highStart - midStart)
            return lerp(tc.low.0, tc.mid.0, t)
        } else {
            let t = min((value - highStart) / (100.0 - highStart), 1.0)
            return lerp(tc.mid.0, tc.high.0, t)
        }
    }

    // Linear interpolation between two SwiftUI Colors via RGB
    private func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        let ra = NSColor(a).usingColorSpace(.sRGB) ?? NSColor.white
        let rb = NSColor(b).usingColorSpace(.sRGB) ?? NSColor.white
        return Color(
            red:   ra.redComponent   + (rb.redComponent   - ra.redComponent)   * t,
            green: ra.greenComponent + (rb.greenComponent - ra.greenComponent) * t,
            blue:  ra.blueComponent  + (rb.blueComponent  - ra.blueComponent)  * t
        )
    }

    func processBarColor(_ value: Double, thresholds: (Double, Double)) -> Color {
        if value >= thresholds.1 { return tc.high.0 }
        if value >= thresholds.0 { return tc.mid.0 }
        return tc.accent
    }

    func formatMB(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

// MARK: - Process List View
struct ProcessListView: View {
    let title: String
    let subtitle: String
    let processes: [ProcessEntry]
    let formatValue: (Double) -> String
    let barColor: (Double) -> Color
    var maxValue: Double = 1
    var accent: Color = .cyan
    var onBack: () -> Void
    var actionIcon: String? = nil
    var onAction: ((@escaping (Bool) -> Void) -> Void)? = nil
    @State private var actionState: ActionState = .idle
    @State private var spinAngle: Double = 0

    enum ActionState { case idle, running, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()

                Text(subtitle)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))

                if let icon = actionIcon {
                    Button {
                        guard actionState == .idle else { return }
                        withAnimation { actionState = .running }
                        // Start spin
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            spinAngle = 360
                        }
                        onAction? { success in
                            withAnimation {
                                spinAngle = 0
                                actionState = success ? .done : .idle
                            }
                            if success {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation { actionState = .idle }
                                }
                            }
                        }
                    } label: {
                        Group {
                            switch actionState {
                            case .idle:
                                Image(systemName: icon)
                                    .foregroundStyle(accent)
                            case .running:
                                Image(systemName: icon)
                                    .foregroundStyle(accent)
                                    .rotationEffect(.degrees(spinAngle))
                            case .done:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(actionState == .running)
                }
            }
            .padding(.bottom, 12)

            if processes.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.6)
                        .colorScheme(.dark)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(Array(processes.enumerated()), id: \.element.id) { index, proc in
                            HStack(spacing: 8) {
                                // Rank number
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.25))
                                    .frame(width: 14)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(proc.name)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.75))
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        Spacer()

                                        Text(formatValue(proc.value))
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }

                                    // Progress bar
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                .fill(Color.white.opacity(0.06))
                                                .frame(height: 3)

                                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                .fill(barColor(proc.value))
                                                .frame(width: max(4, geo.size.width * CGFloat(proc.value / maxValue)), height: 3)
                                        }
                                    }
                                    .frame(height: 3)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Gauge Cell
struct GaugeCell: View {
    let icon: String
    let label: String
    let value: String
    let percent: Double
    let gradient: Gradient
    var tappable: Bool = false
    var dropBounce: Bool = false

    @State private var glowPhase: Bool = false
    @State private var isHovered = false
    @State private var bounceOffset: CGFloat = 0
    @State private var bounceScale: CGFloat = 1.0

    // Primary color from gradient for glow
    private var glowColor: Color { gradient.stops.first?.color ?? .cyan }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Soft glow behind ring for tappable gauges
                if tappable {
                    Circle()
                        .fill(glowColor.opacity(glowPhase ? 0.12 : 0.04))
                        .frame(width: 88, height: 88)
                        .blur(radius: glowPhase ? 18 : 10)
                        .animation(
                            .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                            value: glowPhase
                        )
                }

                // Hover: full circle outline glow
                if tappable {
                    Circle()
                        .stroke(glowColor.opacity(isHovered ? 0.35 : 0), lineWidth: 2)
                        .frame(width: 96, height: 96)
                        .blur(radius: 6)
                        .animation(.easeOut(duration: 0.3), value: isHovered)

                    Circle()
                        .stroke(glowColor.opacity(isHovered ? 0.15 : 0), lineWidth: 1)
                        .frame(width: 102, height: 102)
                        .blur(radius: 10)
                        .animation(.easeOut(duration: 0.4), value: isHovered)
                }

                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 8)

                Circle()
                    .trim(from: 0, to: CGFloat(min(max(percent, 0), 1.0)))
                    .stroke(
                        AngularGradient(
                            gradient: gradient,
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(-90 + 360 * min(max(percent, 0.01), 1.0))
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: percent)
                    // Ring glow
                    .shadow(color: tappable ? glowColor.opacity(glowPhase ? 0.5 : 0.2) : .clear, radius: glowPhase ? 8 : 4)

                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(value)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            .frame(width: 90, height: 90)
            .scaleEffect(isHovered && tappable ? 1.06 : bounceScale)
            .offset(y: bounceOffset)
            .animation(.easeOut(duration: 0.2), value: isHovered)

            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            if tappable {
                glowPhase = true
            }
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
