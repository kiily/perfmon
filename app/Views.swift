// Views.swift — the panel under the menu bar item.
import Charts
import ServiceManagement
import SwiftUI

enum SortKey: String, CaseIterable { case memory = "Memory", cpu = "CPU" }
enum Tab: String, CaseIterable { case apps = "Apps", servers = "Servers" }
enum Metric: String { case cpu = "CPU", memory = "Memory", thermal = "Power", battery = "Battery" }

struct Panel: View {
    let monitor: Monitor
    @AppStorage("sort") private var sort = SortKey.memory
    @AppStorage("tab") private var tab = Tab.apps
    @State private var chart: Metric?
    @AppStorage("menuBattery") private var menuBattery = false
    @AppStorage("alerts") private var alerts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { cpuTile; memoryTile }
                GridRow { thermalTile; batteryTile }
            }
            if let chart {
                HistoryChart(metric: chart, history: monitor.history, memTotal: monitor.memTotal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            listHeader
            CappedScroll(maxHeight: listMaxHeight) {
                switch tab {
                case .apps: AppList(monitor: monitor, sort: sort)
                case .servers: ServerList(monitor: monitor)
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .animation(.smooth(duration: 0.25), value: chart)
        .animation(.smooth(duration: 0.25), value: tab)
        // The panel is this app's only window, so key status == panel open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in monitor.panelOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in monitor.panelOpen = false }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            TimelineView(.everyMinute) { ctx in
                VStack(alignment: .leading, spacing: 0) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(ctx.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Label(monitor.status.text, systemImage: monitor.status.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(monitor.status.tint)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    /// Whatever the screen has left once the header, tiles and an open chart are drawn.
    private var listMaxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(160, screen - (chart == nil ? 330 : 440))
    }

    // MARK: Tiles — each one opens its 24 h history

    private func toggle(_ m: Metric) { chart = chart == m ? nil : m }

    private var cpuTile: some View {
        Tile(title: "CPU", symbol: "cpu", value: "\(Int(monitor.cpu.rounded()))%",
             tint: monitor.cpu > 85 ? .orange : .primary, selected: chart == .cpu) { toggle(.cpu) } detail: {
            Sparkline(values: monitor.cpuRecent).frame(height: 16)
        }
    }

    private var memoryTile: some View {
        let (pressure, tint): (String, Color) = switch monitor.pressure {
        case .normal: ("normal", .green)
        case .warning: ("high", .orange)
        case .critical: ("critical", .red)
        }
        return Tile(title: "Memory", symbol: "memorychip", value: "\(gb(monitor.memUsed)) of \(gb(monitor.memTotal))",
                    tint: monitor.pressure == .normal ? .primary : tint, selected: chart == .memory) { toggle(.memory) } detail: {
            Gauge(value: Double(monitor.memUsed), in: 0...Double(monitor.memTotal)) {}
                .gaugeStyle(.linearCapacity).tint(tint).controlSize(.mini)
            Text("Pressure \(pressure) · \(gb(monitor.swap)) swap")
        }
    }

    private var thermalTile: some View {
        let (label, tint): (String, Color) = switch monitor.thermal {
        case .nominal: ("Cool", .primary)
        case .fair: ("Warm", .orange)
        case .serious: ("Hot", .red)
        case .critical: ("Throttling", .red)
        @unknown default: ("Unknown", .secondary)
        }
        return Tile(title: "Thermal", symbol: "thermometer.medium", value: label, tint: tint,
                    selected: chart == .thermal) { toggle(.thermal) } detail: {
            if let w = monitor.battery?.watts { Text("Drawing \(w, format: .number.precision(.fractionLength(1))) W") }
        }
    }

    @ViewBuilder private var batteryTile: some View {
        if let b = monitor.battery {
            Tile(title: "Battery", symbol: batterySymbol(b),
                 value: "\(b.percent)%", tint: !b.pluggedIn && b.percent <= 15 ? .orange : .primary,
                 selected: chart == .battery) { toggle(.battery) } detail: {
                Group {
                    if let m = b.minutesLeft { Text("\(m / 60)h \(m % 60)m to \(b.charging ? "full" : "empty")") }
                    else if b.pluggedIn { Text(b.charging ? "Charging" : "Plugged in") }
                    else { Text("On battery") }
                }
                .help("\(b.health.map { "\($0)% health · " } ?? "")\(b.cycles) cycles")
            }
        } else {
            Tile(title: "Power", symbol: "powerplug", value: "AC", tint: .primary, selected: false) {} detail: {
                Text("No battery")
            }
        }
    }

    // MARK: List

    private var listHeader: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t == .servers && !monitor.listeners.isEmpty
                         ? "Servers \(monitor.listeners.filter(\.isDev).count)" : t.rawValue)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            if tab == .apps {
                Picker("Sort by", selection: $sort) {
                    ForEach(SortKey.allCases, id: \.self) { Text("By \($0.rawValue)") }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
            }
            if monitor.hasSampled {
                RefreshRing(from: monitor.lastSample, to: monitor.nextSample).id(monitor.lastSample)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Spacer()
            if monitor.battery != nil {
                Toggle("Low Power", isOn: Binding(get: { monitor.lowPower }, set: { monitor.setLowPower($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Low Power Mode — macOS asks for your password to change it")
            }
            Menu {
                Toggle("Show Battery in Menu Bar", isOn: $menuBattery)
                Toggle("Alerts for Memory and Heat", isOn: $alerts)
                Toggle("Open at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
                Divider()
                Button("Quit Perfmon") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

// MARK: - Tiles

struct Tile<Detail: View>: View {
    let title: String
    let symbol: String
    let value: String
    let tint: Color
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let detail: Detail
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(value)
                    .font(.headline).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)   // shrink only for width, never height
                Group { detail }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.quaternary.opacity(hovering || selected ? 0.9 : 0.5), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Last 24 hours")
        .accessibilityHint("Shows the last 24 hours")
    }
}

struct Sparkline: View {
    let values: [Double]   // 0...100

    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard values.count > 1 else { return }
                let step = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - min(v, 100) / 100))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Fills over the sampling interval, so you can see when the numbers last moved and when they'll move next.
struct RefreshRing: View {
    let from: Date
    let to: Date
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle().trim(from: 0, to: progress)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .onAppear { withAnimation(.linear(duration: max(to.timeIntervalSince(from), 0.1))) { progress = 1 } }
        .help("Updated \(from.formatted(date: .omitted, time: .standard))")
        .accessibilityLabel("Live, updated \(from.formatted(date: .omitted, time: .standard))")
    }
}

// MARK: - History chart

struct HistoryChart: View {
    let metric: Metric
    let history: [Minute]
    let memTotal: UInt64
    @State private var hover: Date?

    private func value(_ m: Minute) -> Double? {
        switch metric {
        case .cpu: m.cpu
        case .memory: m.mem
        case .thermal: m.watts
        case .battery: m.battery.map(Double.init)
        }
    }

    private var unit: String {
        switch metric { case .cpu, .battery: "%"; case .memory: " GB"; case .thermal: " W" }
    }

    private var yMax: Double {
        switch metric {
        case .cpu, .battery: 100
        case .memory: Double(memTotal) / 1_073_741_824
        case .thermal: max(10, (history.compactMap(\.watts).max() ?? 0) * 1.15)
        }
    }

    private var selected: Minute? {
        guard let hover else { return nil }
        return history.min { abs($0.t.timeIntervalSince(hover)) < abs($1.t.timeIntervalSince(hover)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(metric.rawValue) · 24 hours").font(.caption.weight(.semibold))
                Spacer()
                if let m = selected { readout(m) }
            }
            if history.count < 2 {
                Text("History fills in while Perfmon runs — \(history.count) min so far.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                chart
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    private var chart: some View {
        Chart {
            ForEach(history, id: \.t) { m in
                if let v = value(m) {
                    AreaMark(x: .value("Time", m.t), y: .value(metric.rawValue, v))
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", m.t), y: .value(metric.rawValue, v))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    // Mark the minutes the Mac ran warm, on the power chart.
                    if metric == .thermal, m.thermal >= 1 {
                        PointMark(x: .value("Time", m.t), y: .value(metric.rawValue, v))
                            .foregroundStyle(m.thermal >= 2 ? .red : .orange).symbolSize(12)
                    }
                }
            }
            if let m = selected, let v = value(m) {
                RuleMark(x: .value("Time", m.t)).foregroundStyle(.secondary.opacity(0.4))
                PointMark(x: .value("Time", m.t), y: .value(metric.rawValue, v)).symbolSize(36)
            }
        }
        .chartXScale(domain: Date.now.addingTimeInterval(-86_400)...Date.now)
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
        .chartXSelection(value: $hover)
        .frame(height: 64)
    }

    /// "15:02 · 82% · Brave 28 GB" — the value and who caused it.
    private func readout(_ m: Minute) -> some View {
        let v = value(m).map { $0.formatted(.number.precision(.fractionLength(0...1))) + unit } ?? "–"
        let who = metric == .memory
            ? "\(m.topMem) \(m.topMemGB.formatted(.number.precision(.fractionLength(0...1)))) GB"
            : "\(m.topCPU) \(Int(m.topCPUPct))%"
        return Text("\(m.t.formatted(date: .omitted, time: .shortened)) · \(v) · \(who)")
            .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
    }
}

// MARK: - Apps

struct AppList: View {
    let monitor: Monitor
    let sort: SortKey

    var body: some View {
        let sorted = monitor.apps.sorted { sort == .memory ? $0.memory > $1.memory : $0.cpu > $1.cpu }.prefix(8)
        let top = sorted.first.map { sort == .memory ? Double($0.memory) : $0.cpu } ?? 1
        VStack(alignment: .leading, spacing: 2) {
            if !monitor.hasSampled {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).frame(width: 18, height: 18)
                        Text("Application name")
                        Spacer()
                        Text("0.0 GB")
                    }
                    .font(.callout).padding(.horizontal, 6).padding(.vertical, 4)
                }
                .redacted(reason: .placeholder)
            }
            ForEach(sorted) { app in
                AppRow(app: app, sort: sort, share: (sort == .memory ? Double(app.memory) : app.cpu) / max(top, 1)) { force in
                    if !quit(app, force: force) { NSSound.beep() }
                    monitor.refreshSoon()
                }
            }
        }
    }
}

struct AppRow: View {
    let app: AppUsage
    let sort: SortKey
    let share: Double
    let quit: (_ force: Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 18)
            Text(app.name).lineLimit(1).truncationMode(.middle)
            if app.pids.count > 1 {
                Text("\(app.pids.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hovering {
                Button { quit(NSEvent.modifierFlags.contains(.option)) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit \(app.name) (⌥-click to force quit)")
            }
            Text(sort == .memory ? bytes(app.memory) : app.cpu.formatted(.number.precision(.fractionLength(1))) + "%")
                .monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 64, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(alignment: .leading) {
            // Share of the top row: the culprit is the longest bar.
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(hovering ? 0.22 : 0.12))
                    .frame(width: geo.size.width * min(max(share, 0), 1))
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Quit") { quit(false) }
            Button("Force Quit") { quit(true) }
            Divider()
            if let path = app.bundlePath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Button("Copy PID\(app.pids.count > 1 ? "s" : "")") { copy(app.pids.map(String.init).joined(separator: " ")) }
        }
    }

    @ViewBuilder private var icon: some View {
        if let path = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: "terminal").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Servers

struct ServerList: View {
    let monitor: Monitor
    @State private var showApps = false

    var body: some View {
        let dev = monitor.listeners.filter(\.isDev).sorted { $0.ports[0] < $1.ports[0] }
        let other = monitor.listeners.filter { !$0.isDev }.sorted { $0.name < $1.name }
        let live = Set(dev.flatMap(\.ports))
        let past = monitor.ports.filter { !live.contains($0.port) }.sorted { $0.lastSeen > $1.lastSeen }.prefix(6)

        VStack(alignment: .leading, spacing: 2) {
            if dev.isEmpty {
                Text(monitor.hasSampled ? "No dev servers running" : "Looking for servers…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            ForEach(dev) { ServerRow(listener: $0, monitor: monitor) }
            if !other.isEmpty {
                DisclosureGroup(isExpanded: $showApps) {
                    ForEach(other) { ServerRow(listener: $0, monitor: monitor) }
                } label: {
                    Text("\(other.count) apps with open ports").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            if !past.isEmpty {
                Text("Recently used").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 8).padding(.horizontal, 6)
                ForEach(past) { PortRow(use: $0, monitor: monitor) }
            }
        }
    }
}

struct ServerRow: View {
    let listener: Listener
    let monitor: Monitor
    @State private var hovering = false

    private var url: URL { URL(string: "http://localhost:\(listener.ports[0])")! }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Text(String(listener.ports[0])).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.tint)
                if listener.ports.count > 1 {
                    Text("+\(listener.ports.count - 1)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if listener.container != nil {
                        Image(systemName: "shippingbox").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(listener.container != nil && listener.project != listener.name
                         ? "\(listener.project ?? "") · \(listener.name)" : listener.project ?? listener.name)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(listener.command).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hovering {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                    .help("Open \(url.absoluteString)")
                Button { stop(force: NSEvent.modifierFlags.contains(.option)) } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .help("Stop (⌥-click to force)")
            } else {
                // Docker's "Up 7 days (healthy)" → "7 days"
                Text(listener.status.map { String($0.replacingOccurrences(of: "Up ", with: "").prefix { $0 != "(" }) } ?? age(since: listener.started))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .font(.callout)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.quaternary.opacity(hovering ? 0.6 : 0), in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help(listener.container != nil
              ? "Docker container · \(listener.command)\nports \(listener.ports.map(String.init).joined(separator: ", "))"
              : "\(listener.dir)\nPID \(listener.pid) · \(bytes(listener.memory)) · ports \(listener.ports.map(String.init).joined(separator: ", "))")
        .contextMenu {
            ForEach(listener.ports, id: \.self) { p in
                Button("Open localhost:\(String(p))") { NSWorkspace.shared.open(URL(string: "http://localhost:\(p)")!) }
            }
            Button("Copy URL") { copy(url.absoluteString) }
            Divider()
            if !listener.dir.isEmpty {
                Button("Show Folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: listener.dir)) }
            }
            if let id = listener.container {
                Button("Copy Container ID") { copy(String(id.prefix(12))) }
            } else {
                Button("Copy PID") { copy(String(listener.pid)) }
            }
            Divider()
            Button("Stop") { stop(force: false) }
            Button("Force Stop") { stop(force: true) }
        }
    }

    private func stop(force: Bool) {
        if let id = listener.container {
            Task {
                let stopped = await Task.detached { dockerAPI("POST", "/containers/\(id)/\(force ? "kill" : "stop")", timeout: 15) != nil }.value
                if !stopped { NSSound.beep() }
                monitor.refreshSoon()
            }
            return
        }
        if kill(listener.pid, force ? SIGKILL : SIGTERM) != 0 { NSSound.beep() }
        monitor.refreshSoon()
    }
}

struct PortRow: View {
    let use: PortUse
    let monitor: Monitor

    var body: some View {
        HStack(spacing: 10) {
            Text(String(use.port)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(use.project).lineLimit(1)
                Text(use.command).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(use.lastSeen, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .contentShape(.rect)
        .help("\(use.dir)\nFirst seen \(use.firstSeen.formatted())")
        .contextMenu {
            Button("Copy Port") { copy(String(use.port)) }
            if !use.dir.isEmpty {
                Button("Show Folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: use.dir)) }
            }
            Divider()
            Button("Forget") { monitor.forget(use) }
        }
    }
}

/// Lays content out at its natural height, scrolling only past `maxHeight`.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(max(height, 1), maxHeight))
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Formatting

func batterySymbol(_ b: Battery) -> String {
    if b.charging { return "battery.100percent.bolt" }
    let level = [100, 75, 50, 25, 0].first { b.percent >= $0 - 12 } ?? 0
    return "battery.\(level)percent"
}

func bytes(_ n: UInt64) -> String { Int64(n).formatted(.byteCount(style: .memory)) }
func gb(_ n: UInt64) -> String { "\((Double(n) / 1_073_741_824).formatted(.number.precision(.fractionLength(0...1)))) GB" }

func age(since date: Date) -> String {
    let s = max(0, Int(-date.timeIntervalSinceNow))
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
    return "\(s / 86_400)d"
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
