// PerfmonApp.swift — the menu bar extra and the model behind it.
import SwiftUI
import UserNotifications

@main
struct PerfmonApp: App {
    @State private var monitor = Monitor()
    @AppStorage("menuBattery") private var menuBattery = false

    init() {
        if CommandLine.arguments.contains("--selftest") { exit(selfTest()) }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(monitor: monitor)
        } label: {
            // Template image + number, like the system's own status items.
            if menuBattery, let b = monitor.battery {
                // A status item shows one image + one text; draw the pair of readouts as a single template image.
                Image(nsImage: templateImage(HStack(spacing: 4) {
                    Image(systemName: monitor.status.symbol)
                    Text("\(Int(monitor.cpu.rounded()))%")
                    Image(systemName: batterySymbol(b)).padding(.leading, 4)
                    Text("\(b.percent)%")
                }))
            } else {
                Image(systemName: monitor.status.symbol)
                Text("\(Int(monitor.cpu.rounded()))%")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
func templateImage(_ view: some View) -> NSImage {
    let renderer = ImageRenderer(content: view.font(.system(size: 13)).monospacedDigit())
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    let image = renderer.nsImage ?? NSImage()
    image.isTemplate = true   // the menu bar tints it for light/dark and highlight
    return image
}

// MARK: - Persistence types

/// One minute of history. Values are rounded so the JSON stays small (~300 KB/day).
struct Minute: Codable {
    var t: Date
    var cpu: Double          // average %
    var mem: Double          // GB used, peak
    var swap: Double         // GB
    var pressure: Int        // Pressure.rawValue, worst
    var thermal: Int         // ThermalState.rawValue, worst
    var watts: Double?       // average
    var battery: Int?
    var topMem: String       // biggest app at the peak
    var topMemGB: Double
    var topCPU: String       // busiest app at the peak
    var topCPUPct: Double
}

/// "Port 3000 was flown-web's `next dev`, last seen Tuesday."
struct PortUse: Codable, Identifiable {
    var id: String { "\(port)|\(project)" }
    var port: UInt16
    var project: String
    var command: String
    var dir: String
    var firstSeen: Date
    var lastSeen: Date
}

private struct SavedState: Codable {
    var history: [Minute]
    var ports: [PortUse]
}

// MARK: - Model

@MainActor @Observable
final class Monitor {
    var cpu = 0.0
    var cpuRecent: [Double] = []     // last ~2 min of samples, for the tile sparkline
    var memUsed: UInt64 = 0
    let memTotal = ProcessInfo.processInfo.physicalMemory
    var pressure = Pressure.normal
    var swap: UInt64 = 0
    var thermal = ProcessInfo.ThermalState.nominal
    var battery: Battery?
    var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    var apps: [AppUsage] = []
    var listeners: [Listener] = []
    var history: [Minute] = []
    var ports: [PortUse] = []

    /// When the current sample was taken and when the next one is due — drives the refresh ring.
    var lastSample = Date.now
    var nextSample = Date.now

    /// Open panel: sample every 2 s. Closed: every 10 s, enough for history and the port ledger.
    var panelOpen = false { didSet { if panelOpen != oldValue { restart() } } }
    private var interval: Double { panelOpen ? 2 : 10 }

    private var loop: Task<Void, Never>?
    private var scanning = false
    private var lastTicks = cpuTicks()
    private var memory = ScanMemory()
    private var recent: [Double] = []   // cpuRecent's backing, filled even while the panel is closed
    private var lastScanNs: UInt64 = 0
    private var pending: (cpu: [Double], watts: [Double], minute: Minute)?
    private var lastSave = Date.now
    private var alerting: Set<String> = []
    private var lastAlert: [String: Date] = [:]

    private static let stateURL = URL.applicationSupportDirectory.appending(path: "Perfmon/state.json")

    init() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            history = saved.history.filter { $0.t > .now.addingTimeInterval(-86_400) }
            ports = saved.ports
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.save() }
        }
        _ = Alerts.shared
        restart()
    }

    func restart() {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 4))
            }
        }
    }

    func tick() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        let now = DispatchTime.now().uptimeNanoseconds
        let prev = memory, elapsed = lastScanNs == 0 ? 0 : now - lastScanNs
        let snap = await Task.detached(priority: .utility) { scanProcesses(prev, elapsedNs: elapsed) }.value
        memory = snap.memory
        lastScanNs = now

        // What the menu bar label shows: always current.
        let t = cpuTicks()
        if t.total > lastTicks.total {
            cpu = Double(t.busy - lastTicks.busy) / Double(t.total - lastTicks.total) * 100
            recent = (recent + [cpu]).suffix(60)
        }
        lastTicks = t
        pressure = memoryPressure()
        thermal = ProcessInfo.processInfo.thermalState
        battery = readBattery()
        let used = memoryUsed(), swapped = swapUsed()
        record(snap.apps, used: used, swapped: swapped)
        recordPorts(snap.listeners)
        checkAlerts(snap.apps)
        if lastSave.timeIntervalSinceNow < -600 { save() }

        // Panel-only state: setting it re-renders the panel, so skip that while nobody can see it.
        guard panelOpen else { return }
        withAnimation(.smooth) {
            cpuRecent = recent
            memUsed = used
            swap = swapped
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            apps = snap.apps
            listeners = snap.listeners
        }
        lastSample = .now
        nextSample = .now.addingTimeInterval(interval)
    }

    // MARK: History

    /// Folds samples into the current minute; a new minute flushes the old one.
    private func record(_ apps: [AppUsage], used memUsed: UInt64, swapped swap: UInt64) {
        let gb = { (b: UInt64) in (Double(b) / 1_073_741_824 * 10).rounded() / 10 }
        let topMem = apps.max { $0.memory < $1.memory }
        let topCPU = apps.max { $0.cpu < $1.cpu }
        let start = Calendar.current.dateInterval(of: .minute, for: .now)!.start
        let sample = Minute(
            t: start, cpu: cpu, mem: gb(memUsed), swap: gb(swap),
            pressure: pressure.rawValue, thermal: thermal.rawValue,
            watts: battery?.watts, battery: battery?.percent,
            topMem: topMem?.name ?? "", topMemGB: gb(topMem?.memory ?? 0),
            topCPU: topCPU?.name ?? "", topCPUPct: (topCPU?.cpu ?? 0).rounded())

        if var p = pending, p.minute.t == start {
            p.cpu.append(cpu)
            if let w = sample.watts { p.watts.append(w) }
            if sample.mem >= p.minute.mem {
                p.minute.mem = sample.mem; p.minute.topMem = sample.topMem; p.minute.topMemGB = sample.topMemGB
            }
            if sample.topCPUPct >= p.minute.topCPUPct {
                p.minute.topCPU = sample.topCPU; p.minute.topCPUPct = sample.topCPUPct
            }
            p.minute.swap = sample.swap
            p.minute.pressure = max(p.minute.pressure, sample.pressure)
            p.minute.thermal = max(p.minute.thermal, sample.thermal)
            p.minute.battery = sample.battery
            pending = p
            return
        }
        if var p = pending {
            p.minute.cpu = (p.cpu.reduce(0, +) / Double(p.cpu.count)).rounded()
            p.minute.watts = p.watts.isEmpty ? nil : (p.watts.reduce(0, +) / Double(p.watts.count) * 10).rounded() / 10
            history = (history + [p.minute]).filter { $0.t > .now.addingTimeInterval(-86_400) }
        }
        pending = (cpu: [cpu], watts: sample.watts.map { [$0] } ?? [], minute: sample)
    }

    /// Every port a dev server listens on, remembered by project. Ephemeral ports (49152+,
    /// e.g. an OAuth callback) aren't worth remembering unless Docker published them.
    private func recordPorts(_ listeners: [Listener]) {
        let now = Date.now
        for l in listeners where l.isDev {
            let project = l.project ?? l.name
            for port in l.ports where port < 49152 || l.container != nil {
                if let i = ports.firstIndex(where: { $0.port == port && $0.project == project }) {
                    ports[i].lastSeen = now
                    ports[i].command = l.command
                } else {
                    ports.append(PortUse(port: port, project: project, command: l.command, dir: l.dir, firstSeen: now, lastSeen: now))
                }
            }
        }
        // ponytail: keep the 300 most recent; nobody scrolls further back than that.
        if ports.count > 300 { ports = Array(ports.sorted { $0.lastSeen > $1.lastSeen }.prefix(300)) }
    }

    // MARK: Alerts

    /// One notification per episode (condition turns on), at most every 15 min per kind,
    /// naming the app to blame with a Quit button.
    private func checkAlerts(_ apps: [AppUsage]) {
        guard UserDefaults.standard.object(forKey: "alerts") as? Bool ?? true else { return }
        let hog = apps.max { $0.memory < $1.memory }
        let busy = apps.max { $0.cpu < $1.cpu }
        alert("memory", when: pressure == .critical, title: "Memory is critically low",
              body: hog.map { "\($0.name) is using \(bytes($0.memory)). Quitting it frees the most." } ?? "", app: hog)
        alert("thermal", when: thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue, title: "Your Mac is running hot",
              body: busy.map { "\($0.name) is using \(Int($0.cpu))% CPU." } ?? "", app: busy)
    }

    private func alert(_ kind: String, when on: Bool, title: String, body: String, app: AppUsage?) {
        defer { if on { alerting.insert(kind) } else { alerting.remove(kind) } }
        guard on, !alerting.contains(kind), (lastAlert[kind] ?? .distantPast).timeIntervalSinceNow < -900 else { return }
        lastAlert[kind] = .now
        Alerts.shared.post(id: kind, title: title, body: body, app: app)
    }

    /// pmset needs root; AppleScript's admin prompt is the sanctioned way to ask for it.
    func setLowPower(_ on: Bool) {
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges")?
            .executeAndReturnError(&error)
        lowPower = error == nil ? on : ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func forget(_ use: PortUse) { ports.removeAll { $0.id == use.id } }

    func save() {
        lastSave = .now
        let state = SavedState(history: history, ports: ports)
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: Self.stateURL, options: .atomic)
    }

    /// After a quit/stop: give the process a second to exit, then resample.
    func refreshSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            await tick()
        }
    }

    var status: (text: String, symbol: String, tint: Color) {
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return ("Running hot", "thermometer.high", .red) }
        if pressure == .critical { return ("Out of memory", "memorychip.fill", .red) }
        if thermal == .fair { return ("Warm", "thermometer.medium", .orange) }
        if pressure == .warning { return ("Memory pressure", "memorychip", .orange) }
        if cpu > 85 { return ("CPU busy", "cpu", .orange) }
        if let b = battery, !b.pluggedIn, b.percent <= 15 { return ("Battery low", "battery.25percent", .orange) }
        return ("Healthy", "gauge.with.dots.needle.33percent", .green)
    }
}

// MARK: - Notifications

/// Posts the alerts; the Quit action quits the named app from the banner.
@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String, app: AppUsage?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let app {
            // ponytail: one category, retitled per post; an older banner's button shows the newest app name.
            center.setNotificationCategories([UNNotificationCategory(
                identifier: "hog", actions: [UNNotificationAction(identifier: "quit", title: "Quit \(app.name)")],
                intentIdentifiers: [])])
            content.categoryIdentifier = "hog"
            content.userInfo = ["pids": app.pids.map(Int.init), "bundle": app.bundlePath ?? "", "name": app.name]
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "quit" else { return }
        let info = response.notification.request.content.userInfo
        let pids = (info["pids"] as? [Int] ?? []).map { pid_t($0) }
        let bundle = (info["bundle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = info["name"] as? String ?? ""
        await MainActor.run {
            _ = quit(AppUsage(name: name, bundlePath: bundle, pids: pids, memory: 0, cpu: 0), force: false)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
