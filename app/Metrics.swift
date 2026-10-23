// Metrics.swift — raw system readings from Mach, sysctl, libproc and IOKit.
// No shelling out: these are the same sources ps/vm_stat/pmset read.
import AppKit
import Darwin
import IOKit

struct Battery {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var minutesLeft: Int?   // to empty on battery, to full when charging
    var cycles: Int
    var health: Int?        // % of design capacity still available
    var watts: Double?      // whole-system draw, the "why is it hot" number
}

/// A process holding a listening TCP socket.
struct Listener: Identifiable {
    var id: pid_t { pid }
    var pid: pid_t
    var ports: [UInt16]
    var name: String
    var bundlePath: String?
    var path: String        // executable
    var dir: String         // working directory
    var project: String?    // git repo (or folder) it was started from
    var command: String     // argv with paths shortened: "node next dev"
    var started: Date
    var memory: UInt64
    // ponytail: "dev" = a bare binary that isn't macOS's own, plus container runtimes whose ports are your containers.
    var isDev: Bool {
        if ["Docker", "OrbStack", "Rancher Desktop"].contains(name) { return true }
        return bundlePath == nil && !["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}

struct Snapshot {
    var apps: [AppUsage]
    var listeners: [Listener]
    var cpu: [pid_t: UInt64]
}

struct AppUsage: Identifiable {
    var id: String { name }
    var name: String
    var bundlePath: String?
    var pids: [pid_t]
    var memory: UInt64      // phys footprint, what Activity Monitor calls "Memory"
    var cpu: Double         // % of one core, can exceed 100 like Activity Monitor
}

enum Pressure: Int { case normal = 1, warning = 2, critical = 4 }

// MARK: - CPU

/// Cumulative (busy, total) ticks across all cores; diff two reads for a %.
func cpuTicks() -> (busy: UInt64, total: UInt64) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    let (user, system, idle, nice) = info.cpu_ticks
    let busy = UInt64(user) + UInt64(system) + UInt64(nice)
    return (busy, busy + UInt64(idle))
}

// MARK: - Memory

func memoryUsed() -> UInt64 {
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    // Activity Monitor's "Memory Used" = app memory + wired + compressed.
    let pages = UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count)
        + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
    return pages * UInt64(getpagesize())
}

func sysctlValue<T: BitwiseCopyable>(_ name: String, _ value: T) -> T {
    var v = value
    var size = MemoryLayout<T>.size
    return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : value
}

func memoryPressure() -> Pressure {
    Pressure(rawValue: Int(sysctlValue("kern.memorystatus_vm_pressure_level", Int32(1)))) ?? .normal
}

func swapUsed() -> UInt64 { sysctlValue("vm.swapusage", xsw_usage()).xsu_used }

// MARK: - Battery

func readBattery() -> Battery? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }   // desktop Mac
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
    func int(_ k: String, in dict: [String: Any] = d) -> Int? { dict[k] as? Int }

    let charging = d["IsCharging"] as? Bool ?? false
    let data = d["BatteryData"] as? [String: Any] ?? [:]
    var health: Int?
    if let design = int("DesignCapacity", in: data), design > 0,
       let nominal = int("NominalChargeCapacity", in: data) ?? int("AppleRawMaxCapacity") {
        health = min(100, nominal * 100 / design)
    }
    let minutes = int(charging ? "AvgTimeToFull" : "AvgTimeToEmpty").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
    // SystemLoad (mW) is total system draw on any power source; V×A only covers the battery.
    var watts: Double?
    if let mw = int("SystemLoad", in: d["PowerTelemetryData"] as? [String: Any] ?? [:]), mw > 0 {
        watts = Double(mw) / 1000
    } else if let mv = int("Voltage"), let ma = int("Amperage"), ma != 0 {
        watts = abs(Double(mv) * Double(ma)) / 1_000_000
    }
    return Battery(
        percent: (int("CurrentCapacity") ?? 0) * 100 / max(int("MaxCapacity") ?? 100, 1),
        charging: charging,
        pluggedIn: d["ExternalConnected"] as? Bool ?? false,
        minutesLeft: minutes,
        cycles: int("CycleCount") ?? 0,
        health: health,
        watts: watts)
}

// MARK: - Processes

/// Bundle that owns an executable path: the outermost `.app`, so every
/// Chrome Helper rolls up into "Google Chrome" (same rule as bin/memtop).
func appBundle(for path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
    return String(path[..<r.lowerBound]) + ".app"
}

/// Bare binaries named by version (~/.local/share/claude/versions/2.1.309)
/// get the nearest meaningful directory instead: "claude".
func displayName(_ path: String) -> String {
    let parts = path.split(separator: "/").reversed()
    return String(parts.first { $0.contains(where: \.isLetter) && !["versions", "bin", "libexec"].contains($0) }
                  ?? parts.first ?? "?")
}

private let timebase: (numer: UInt64, denom: UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(tb.denom))
}()

/// One pass over every process we're allowed to inspect: memory, CPU and
/// listening sockets. Root-owned processes (WindowServer, kernel_task) fail
/// proc_pid_rusage without privileges; they still count in the system totals,
/// and we couldn't kill them anyway. `prevCPU` maps pid → CPU ns last pass.
// ponytail: full rescan (~1.4k pids incl. sockets ≈ 40 ms) every 10 s, 2 s while the panel is open.
func scanProcesses(prevCPU: [pid_t: UInt64], elapsedNs: UInt64) -> Snapshot {
    let me = getpid()
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var groups: [String: AppUsage] = [:]
    var listeners: [Listener] = []
    var cpuNow: [pid_t: UInt64] = [:]
    var buf = [UInt8](repeating: 0, count: 4096)

    for pid in pids.prefix(max(n, 0)) where pid > 1 && pid != me {
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { continue }
        // rusage times are Mach ticks on Apple silicon, not ns.
        let ns = (ri.ri_user_time + ri.ri_system_time) * timebase.numer / timebase.denom
        cpuNow[pid] = ns
        let cpu = prevCPU[pid].map { ns >= $0 && elapsedNs > 0 ? Double(ns - $0) / Double(elapsedNs) * 100 : 0 } ?? 0

        let len = Int(proc_pidpath(pid, &buf, UInt32(buf.count)))
        guard len > 0 else { continue }
        let path = String(decoding: buf[..<len], as: UTF8.self)
        let bundle = appBundle(for: path)
        let name = bundle.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? displayName(path)
        groups[name, default: AppUsage(name: name, bundlePath: bundle, pids: [], memory: 0, cpu: 0)].pids.append(pid)
        groups[name]!.memory += ri.ri_phys_footprint
        groups[name]!.cpu += cpu

        let ports = listeningPorts(pid)
        if !ports.isEmpty {
            let dir = workingDirectory(pid)
            listeners.append(Listener(
                pid: pid, ports: ports, name: name, bundlePath: bundle, path: path, dir: dir,
                project: projectName(dir), command: shortCommand(arguments(pid)),
                started: startTime(pid), memory: ri.ri_phys_footprint))
        }
    }
    return Snapshot(apps: Array(groups.values), listeners: listeners, cpu: cpuNow)
}

func listeningPorts(_ pid: pid_t) -> [UInt16] {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
    let got = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)) / MemoryLayout<proc_fdinfo>.stride
    var ports = Set<UInt16>()
    for fd in fds.prefix(max(got, 0)) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
        var si = socket_fdinfo()
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
              si.psi.soi_kind == SOCKINFO_TCP,
              si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
        ports.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
    }
    return ports.sorted()
}

func workingDirectory(_ pid: pid_t) -> String {
    var vi = proc_vnodepathinfo()
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return "" }
    return withUnsafeBytes(of: vi.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

func startTime(_ pid: pid_t) -> Date {
    var bi = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return .now }
    return Date(timeIntervalSince1970: TimeInterval(bi.pbi_start_tvsec))
}

/// argv via KERN_PROCARGS2: [argc][exec path][NULs][argv…][env…].
func arguments(_ pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    return buf[4..<size].split(separator: 0).dropFirst().prefix(Int(argc)).map { String(decoding: $0, as: UTF8.self) }
}

/// "/opt/homebrew/bin/node /x/node_modules/.bin/next dev -p 3000" → "node next dev -p 3000"
func shortCommand(_ argv: [String]) -> String {
    argv.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).lastPathComponent : $0 }
        .joined(separator: " ").prefix(80).description
}

/// The repo a server was started from: nearest ancestor with `.git`, else the folder itself.
/// Nil outside your home folder (brew services run in /opt/homebrew), for $HOME
/// itself and for app data under ~/Library — none of those name a project.
func projectName(_ dir: String) -> String? {
    let home = NSHomeDirectory()
    guard dir.hasPrefix(home + "/"), !dir.hasPrefix(home + "/Library/") else { return nil }
    var url = URL(fileURLWithPath: dir)
    while url.path.count > home.count {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.lastPathComponent }
        url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: dir).lastPathComponent
}

/// Graceful first: a running app gets a normal Quit (it may ask to save).
/// Returns false when nothing could be signalled (e.g. another user's process).
@MainActor
func quit(_ app: AppUsage, force: Bool) -> Bool {
    if let path = app.bundlePath,
       let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
        return force ? running.forceTerminate() : running.terminate()
    }
    let sig = force ? SIGKILL : SIGTERM
    return app.pids.reduce(false) { kill($1, sig) == 0 || $0 }
}

// MARK: - Self-test (`Perfmon --selftest`, run by test/smoke.sh)

func selfTest() -> Int32 {
    var failed = false
    func check(_ name: String, _ ok: Bool) { print(ok ? "ok   \(name)" : "FAIL \(name)"); if !ok { failed = true } }
    check("bundle: helper rolls up to outer app",
          appBundle(for: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
          == "/Applications/Google Chrome.app")
    check("bundle: bare binary has none", appBundle(for: "/usr/bin/ssh") == nil)
    check("name: versioned binary uses its tool dir", displayName("/Users/x/.local/share/claude/versions/2.1.309") == "claude")
    check("name: plain binary", displayName("/opt/homebrew/bin/mongod") == "mongod")
    check("command: paths shortened", shortCommand(["/opt/homebrew/bin/node", "/x/.bin/next", "dev"]) == "node next dev")
    check("project: home is no project", projectName(NSHomeDirectory()) == nil && projectName("/") == nil)
    check("project: brew/app data is no project",
          projectName("/opt/homebrew/var") == nil && projectName(NSHomeDirectory() + "/Library/Containers/x/Data") == nil)
    let t = cpuTicks()
    check("cpu ticks", t.total > t.busy && t.busy > 0)
    let used = memoryUsed()
    check("memory used within physical", used > 0 && used < ProcessInfo.processInfo.physicalMemory)
    let snap = scanProcesses(prevCPU: [:], elapsedNs: 0)
    check("process scan finds apps", snap.apps.count > 3 && !snap.cpu.isEmpty)
    check("process scan skips self", !snap.apps.contains { $0.pids.contains(getpid()) })

    // A listener we own must show up with its port, folder and argv.
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    server.arguments = ["-l", "127.0.0.1", "47999"]
    server.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
    if (try? server.run()) != nil {
        usleep(300_000)
        let found = scanProcesses(prevCPU: [:], elapsedNs: 0).listeners.first { $0.pid == server.processIdentifier }
        check("listener: port found", found?.ports == [47999])
        check("listener: argv read", found?.command == "nc -l 127.0.0.1 47999")
        check("listener: is dev", found?.isDev == true)
        server.terminate()
    } else { check("listener: nc started", false) }

    if let b = readBattery() { check("battery percent", (0...100).contains(b.percent)) }
    return failed ? 1 : 0
}
