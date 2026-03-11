import SwiftUI

enum DetailMode {
    case none, cpu, ram
}

struct ContentView: View {
    @StateObject private var monitor = SystemMonitor()
    @State private var detail: DetailMode = .none

    var body: some View {
        Group {
            switch detail {
            case .none:
                gaugeGrid
            case .ram:
                ProcessListView(
                    title: "Memory Usage",
                    subtitle: String(format: "%.1f/%.0f GB", monitor.usedRAM, monitor.totalRAM),
                    processes: monitor.topRAMProcesses,
                    formatValue: { formatMB($0) },
                    barColor: { $0 >= 500 ? .red : $0 >= 200 ? .orange : .cyan },
                    onBack: { withAnimation(.easeInOut(duration: 0.2)) { detail = .none } },
                    actionIcon: "arrow.triangle.2.circlepath",
                    onAction: { monitor.purgeRAM() }
                )
            case .cpu:
                ProcessListView(
                    title: "CPU Usage",
                    subtitle: String(format: "%%%.0f", monitor.cpuUsage),
                    processes: monitor.topCPUProcesses,
                    formatValue: { String(format: "%.1f%%", $0) },
                    barColor: { $0 >= 50 ? .red : $0 >= 15 ? .orange : .cyan },
                    onBack: { withAnimation(.easeInOut(duration: 0.2)) { detail = .none } }
                )
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
                    tint: tint(monitor.cpuUsage),
                    tappable: true
                )
                .onTapGesture {
                    monitor.fetchTopCPUProcesses()
                    withAnimation(.easeInOut(duration: 0.2)) { detail = .cpu }
                }

                GaugeCell(
                    icon: "memorychip",
                    label: "Memory",
                    value: String(format: "%.1fG", monitor.usedRAM),
                    percent: monitor.totalRAM > 0 ? monitor.usedRAM / monitor.totalRAM : 0,
                    tint: tint(monitor.totalRAM > 0 ? monitor.usedRAM / monitor.totalRAM * 100 : 0),
                    tappable: true
                )
                .onTapGesture {
                    monitor.fetchTopRAMProcesses()
                    withAnimation(.easeInOut(duration: 0.2)) { detail = .ram }
                }
            }
            HStack(spacing: 16) {
                GaugeCell(
                    icon: "internaldrive",
                    label: "Disk",
                    value: monitor.diskLabel,
                    percent: monitor.diskPercent / 100,
                    tint: tint(monitor.diskPercent)
                )
                GaugeCell(
                    icon: "thermometer.medium",
                    label: "Temp",
                    value: String(format: "%.0f°C", monitor.cpuTemp),
                    percent: min(monitor.cpuTemp / 100, 1.0),
                    tint: tempTint(monitor.cpuTemp)
                )
            }
        }
        .padding(20)
    }

    func tint(_ pct: Double) -> Color {
        if pct > 80 { return .red }
        if pct > 55 { return .orange }
        return .cyan
    }

    func tempTint(_ temp: Double) -> Color {
        if temp > 85 { return .red }
        if temp > 65 { return .orange }
        return .cyan
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
    var onBack: () -> Void
    var actionIcon: String? = nil
    var onAction: (() -> Void)? = nil
    @State private var actionDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
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
                        onAction?()
                        withAnimation { actionDone = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { actionDone = false }
                        }
                    } label: {
                        Image(systemName: actionDone ? "checkmark.circle.fill" : icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(actionDone ? .green : .cyan)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
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
                    VStack(spacing: 6) {
                        ForEach(processes) { proc in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(barColor(proc.value))
                                    .frame(width: 3, height: 20)

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
    let tint: Color
    var tappable: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 6)

                Circle()
                    .trim(from: 0, to: CGFloat(min(max(percent, 0), 1.0)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: percent)

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
    }
}