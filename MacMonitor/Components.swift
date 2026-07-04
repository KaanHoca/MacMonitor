import SwiftUI

// MARK: - Layout Constants

enum UILayout {
    static let width: CGFloat = 300
    static let detailHeight: CGFloat = 440

    // Grid section: 20 top padding + two 100pt dial rows with 24 spacing
    // + separator block (1pt line with 12pt vertical padding) + 20 bottom
    // padding, plus the small slack the original 340pt window carried.
    static let gridBase: CGFloat = 293
    static let infoRowSpacing: CGFloat = 10
    static let powerRowHeight: CGFloat = 14
    static let networkRowHeight: CGFloat = 14
    static let ipRowHeight: CGFloat = 24
    static let batteryRowHeight: CGFloat = 14

    static func mainHeight(hasBattery: Bool, showPower: Bool, showNetwork: Bool, showIP: Bool) -> CGFloat {
        var rows: [CGFloat] = []
        if showPower { rows.append(powerRowHeight) }
        if showNetwork { rows.append(networkRowHeight) }
        if showIP { rows.append(ipRowHeight) }
        if hasBattery { rows.append(batteryRowHeight) }
        guard !rows.isEmpty else { return gridBase }
        return gridBase + rows.reduce(0, +) + CGFloat(rows.count - 1) * infoRowSpacing
    }
}

extension Notification.Name {
    // Posted by ContentView when switching between grid and detail views;
    // AppDelegate animates the borderless window to the requested height.
    static let mmResizeWindow = Notification.Name("MacMonitorResizeWindow")
}

// MARK: - Tick Gauge

/// Instrument-style dial: discrete radial tick marks lit up to the current
/// value, with brightness ramping toward the tip. Drawn in a single Canvas
/// so every gauge renders with pixel-identical geometry; there is no blur,
/// no shadow and no round-cap arc that could make dials read as unequal.
/// Ticks turn orange past `warnAt` and red past `critAt`.
struct TickGauge: View, Animatable {
    var percent: Double
    let color: Color
    var tickCount: Int = 44
    var warnAt: Double? = nil
    var critAt: Double? = nil
    var highlight: Bool = false

    var animatableData: Double {
        get { percent }
        set { percent = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let clamped = min(max(percent, 0), 1)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 1
            let tickLength = max(outer * 0.20, 3)
            let inner = outer - tickLength
            let lineWidth = max(outer * 0.055, 1.1)
            let lit = clamped * Double(tickCount)

            let activeColor: Color = {
                if let crit = critAt, clamped >= crit { return Color(red: 0.90, green: 0.30, blue: 0.30) }
                if let warn = warnAt, clamped >= warn { return Color(red: 0.95, green: 0.65, blue: 0.30) }
                return color
            }()

            for i in 0..<tickCount {
                let angle = Double(i) / Double(tickCount) * 2 * .pi - .pi / 2
                let cosA = CGFloat(cos(angle))
                let sinA = CGFloat(sin(angle))
                var path = Path()
                path.move(to: CGPoint(x: center.x + inner * cosA, y: center.y + inner * sinA))
                path.addLine(to: CGPoint(x: center.x + outer * cosA, y: center.y + outer * sinA))

                // Fractional fill of the newest tick keeps the sweep smooth
                let fill = min(max(lit - Double(i), 0), 1)
                let tickColor: Color
                if fill > 0 {
                    let positionInArc = (Double(i) + 0.5) / max(lit, 0.001)
                    let ramp = 0.55 + 0.45 * min(positionInArc, 1)
                    tickColor = activeColor.opacity(ramp * fill + 0.09 * (1 - fill))
                } else {
                    tickColor = Color.white.opacity(highlight ? 0.16 : 0.09)
                }
                context.stroke(path, with: .color(tickColor),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
    }
}

// MARK: - History Store

/// Rolling metric history kept outside SystemMonitor's published values, so
/// per-tick appends only redraw the small views that observe this store.
final class HistoryStore: ObservableObject {
    static let capacity = 60  // 5 minutes at one sample per 5s

    @Published private(set) var cpu: [Double] = []
    @Published private(set) var ram: [Double] = []
    @Published private(set) var temp: [Double] = []
    @Published private(set) var fanRPM: [[Double]] = []
    @Published private(set) var power: [Double] = []

    func append(cpu: Double, ram: Double, temp: Double, fans: [Double], power: Double) {
        appendValue(&self.cpu, cpu)
        appendValue(&self.ram, ram)
        if temp > 0 { appendValue(&self.temp, temp) }
        if power > 0 { appendValue(&self.power, power) }
        if !fans.isEmpty {
            if fanRPM.count != fans.count { fanRPM = fans.map { _ in [] } }
            for (i, rpm) in fans.enumerated() {
                appendValue(&fanRPM[i], rpm)
            }
        }
    }

    private func appendValue(_ series: inout [Double], _ value: Double) {
        series.append(value)
        if series.count > Self.capacity { series.removeFirst() }
    }
}

// MARK: - History Graph

/// Multi-series line graph with faint horizontal grid lines, used in the
/// Thermals detail view for temperature and fan RPM history.
struct HistoryGraph: View {
    let series: [[Double]]
    let maxValue: Double   // 0 = autoscale across all series
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let y = geo.size.height * CGFloat(i) / 2.0
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                }

                let (lo, hi) = bounds()
                ForEach(0..<series.count, id: \.self) { idx in
                    let data = series[idx]
                    if data.count > 1 {
                        Path { p in
                            let stepX = geo.size.width / CGFloat(max(HistoryStore.capacity - 1, 1))
                            for (i, v) in data.enumerated() {
                                let x = geo.size.width - stepX * CGFloat(data.count - 1 - i)
                                let norm = hi > lo ? min(max((v - lo) / (hi - lo), 0), 1) : 0.5
                                let y = geo.size.height - geo.size.height * CGFloat(norm)
                                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                                else { p.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(
                            color.opacity(series.count > 1 ? (idx == 0 ? 0.8 : 0.4) : 0.8),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
            }
        }
        .background(Color.white.opacity(0.02))
        .cornerRadius(6)
    }

    private func bounds() -> (Double, Double) {
        if maxValue > 0 { return (0, maxValue) }
        let all = series.flatMap { $0 }
        let lo = all.min() ?? 0
        let hi = all.max() ?? 1
        let pad = max((hi - lo) * 0.15, 2)
        return (max(lo - pad, 0), hi + pad)
    }
}

// MARK: - Detail Header

/// Shared detail view header. The small ring carries the same matched
/// geometry id as the tapped gauge, so the ring visually flies into the
/// header and keeps showing live data while the detail view is open.
struct DetailHeader: View {
    let title: String
    let value: String
    let percent: Double
    let color: Color
    let matchID: String
    let ns: Namespace.ID
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TickGauge(percent: percent, color: color, tickCount: 28)
                .matchedGeometryEffect(id: matchID, in: ns)
                .frame(width: 22, height: 22)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.leading, 2)

            Spacer()

            Text(value)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.bottom, 10)
    }
}
