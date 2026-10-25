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
    var id: String { container ?? String(pid) }
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
    var container: String? = nil   // Docker container id; pid is then the runtime's
    var status: String? = nil      // Docker's "Up 3 days"
    // ponytail: "dev" = a bare binary that isn't macOS's own, plus containers. An .app nested in a
    // framework (Python.framework/…/Python.app) is an interpreter, not an app, so it counts as bare.
    var isDev: Bool {
        if container != nil || containerRuntimes.contains(name) { return true }
        let bare = bundlePath.map { $0.contains(".framework/") } ?? true
        return bare && !["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
    /// Docker Desktop's own row (ports no container claims): stopping it would stop Docker.
    var stoppable: Bool { container != nil || !containerRuntimes.contains(name) }
}

struct Snapshot {
    var apps: [AppUsage]
    var listeners: [Listener]
    var memory: ScanMemory
}

/// What one scan hands the next, so it only does work that changed.
struct ScanMemory {
    /// Per pid: its start time (guards pid reuse), CPU ns so far, its resolved name and,
    /// once it listens, what the server row shows (argv, folder, repo don't change).
    var seen: [pid_t: (start: UInt64, cpu: UInt64, path: String, bundle: String?, name: String, server: Server?)] = [:]
    struct Server { var dir: String, project: String?, command: String, started: Date }
    /// The last Docker answer and the runtime ports it was asked for.
    var docker: (ports: [UInt16], at: Date, containers: [Container])?
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
/// and we couldn't kill them anyway.
// ponytail: rusage + sockets for every pid each pass (~8 ms for 1.6k pids); names come from `memory`.
func scanProcesses(_ memory: ScanMemory, elapsedNs: UInt64) -> Snapshot {
    let me = getpid()
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var groups: [String: AppUsage] = [:]
    var listeners: [Listener] = []
    var next = ScanMemory(docker: memory.docker)
    var buf = [UInt8](repeating: 0, count: 4096)

    for pid in pids.prefix(max(n, 0)) where pid > 1 && pid != me {
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { continue }
        // rusage times are Mach ticks on Apple silicon, not ns.
        let ns = (ri.ri_user_time + ri.ri_system_time) * timebase.numer / timebase.denom
        var known = memory.seen[pid].flatMap { $0.start == ri.ri_proc_start_abstime ? $0 : nil }
        let cpu = known.map { ns >= $0.cpu && elapsedNs > 0 ? Double(ns - $0.cpu) / Double(elapsedNs) * 100 : 0 } ?? 0
        if known == nil {   // new process: resolve its name once
            let len = Int(proc_pidpath(pid, &buf, UInt32(buf.count)))
            guard len > 0 else { continue }
            let path = String(decoding: buf[..<len], as: UTF8.self)
            let bundle = appBundle(for: path)
            known = (ri.ri_proc_start_abstime, ns, path, bundle,
                     bundle.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? displayName(path), nil)
        }
        known!.cpu = ns
        let (_, _, path, bundle, name, _) = known!
        groups[name, default: AppUsage(name: name, bundlePath: bundle, pids: [], memory: 0, cpu: 0)].pids.append(pid)
        groups[name]!.memory += ri.ri_phys_footprint
        groups[name]!.cpu += cpu

        let ports = listeningPorts(pid)
        if !ports.isEmpty {
            if known!.server == nil {
                let dir = workingDirectory(pid)
                known!.server = .init(dir: dir, project: projectName(dir), command: shortCommand(arguments(pid)), started: startTime(pid))
            }
            let s = known!.server!
            listeners.append(Listener(
                pid: pid, ports: ports, name: name, bundlePath: bundle, path: path, dir: s.dir,
                project: s.project, command: s.command, started: s.started, memory: ri.ri_phys_footprint))
        }
        next.seen[pid] = known
    }
    let shown = withContainers(listeners, cache: &next.docker)
    return Snapshot(apps: Array(groups.values), listeners: shown, memory: next)
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

// MARK: - Docker

let containerRuntimes: Set<String> = ["Docker", "OrbStack", "Rancher Desktop"]

/// A row of `GET /containers/json` (field names are the Engine API's).
/// ponytail: rows are re-fetched when the runtime's ports change or after 60 s (for "Up 3 days").
struct Container: Decodable {
    let Id: String
    let Names: [String]
    let Image: String
    let Created: Double
    let Status: String
    let Labels: [String: String]?
    let Ports: [Port]
    struct Port: Decodable { let PublicPort: UInt16? }

    /// Compose service ("db") when there is one, else the container name.
    var name: String {
        Labels?["com.docker.compose.service"] ?? Names.first.map { String($0.drop { $0 == "/" }) } ?? String(Id.prefix(12))
    }
    var publicPorts: [UInt16] { Set(Ports.compactMap(\.PublicPort)).sorted() }
    var project: String? { Labels?["com.docker.compose.project"] }
    var workingDir: String? { Labels?["com.docker.compose.project.working_dir"] }
}

/// The runtime's process listens for every published port; swap those ports
/// for one row per container: name, compose project, image.
func withContainers(_ listeners: [Listener], cache: inout (ports: [UInt16], at: Date, containers: [Container])?) -> [Listener] {
    guard let runtime = listeners.first(where: { containerRuntimes.contains($0.name) }) else { return listeners }
    let ports = listeners.filter { containerRuntimes.contains($0.name) }.flatMap(\.ports).sorted()
    if cache == nil || cache!.ports != ports || cache!.at.timeIntervalSinceNow < -60 {
        guard let data = dockerAPI("GET", "/containers/json"),
              let fresh = try? JSONDecoder().decode([Container].self, from: data) else { return listeners }
        cache = (ports, .now, fresh)
    }
    let containers = cache!.containers
    let published = Set(containers.flatMap(\.publicPorts))
    var out = listeners.compactMap { l -> Listener? in
        guard containerRuntimes.contains(l.name) else { return l }
        var l = l
        l.ports.removeAll(where: published.contains)
        return l.ports.isEmpty ? nil : l
    }
    for c in containers where !c.publicPorts.isEmpty {
        out.append(Listener(
            pid: runtime.pid, ports: c.publicPorts, name: c.name, bundlePath: runtime.bundlePath, path: runtime.path,
            dir: c.workingDir ?? "", project: c.project ?? c.name, command: c.Image,
            started: Date(timeIntervalSince1970: c.Created), memory: 0, container: c.Id, status: c.Status))
    }
    return out
}

private let dockerSockets = ["/.docker/run/docker.sock", "/.orbstack/run/docker.sock"].map { NSHomeDirectory() + $0 }
    + ["/var/run/docker.sock"]

/// One HTTP/1.0 request to the Docker Engine socket; the body on 2xx, else nil.
/// HTTP/1.0 means no chunked encoding: read to EOF and split off the headers.
func dockerAPI(_ method: String, _ path: String, timeout: Int = 2) -> Data? {
    for sock in dockerSockets where FileManager.default.fileExists(atPath: sock) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { strlcpy($0, sock, capacity) }
        }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { continue }
        let request = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"
        guard write(fd, request, request.utf8.count) == request.utf8.count else { continue }
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while case let n = read(fd, &buf, buf.count), n > 0 { response.append(contentsOf: buf[..<n]) }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let status = String(decoding: response.prefix(12), as: UTF8.self)   // "HTTP/1.0 200"
        return status.dropFirst(9).hasPrefix("2") ? Data(response[split.upperBound...]) : nil
    }
    return nil
}

/// The pids that are still the processes we saw: a reused pid has a different start time.
func unchanged(_ pids: [pid_t], started: [TimeInterval]) -> [pid_t] {
    zip(pids, started).filter { startTime($0.0).timeIntervalSince1970 == $0.1 }.map(\.0)
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
    let snap = scanProcesses(ScanMemory(), elapsedNs: 0)
    check("process scan finds apps", snap.apps.count > 3 && !snap.memory.seen.isEmpty)
    let again = scanProcesses(snap.memory, elapsedNs: 1_000_000_000)
    let kept = again.memory.seen.filter { snap.memory.seen[$0.key] != nil }
    check("rescan keeps cached names", kept.count > 100 && kept.allSatisfy { snap.memory.seen[$0.key]!.name == $0.value.name })
    check("process scan skips self", !snap.apps.contains { $0.pids.contains(getpid()) })

    // A listener we own must show up with its port, folder and argv.
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    server.arguments = ["-l", "127.0.0.1", "61999"]   // ephemeral: never lands in the port ledger
    server.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
    if (try? server.run()) != nil {
        usleep(300_000)
        let found = scanProcesses(ScanMemory(), elapsedNs: 0).listeners.first { $0.pid == server.processIdentifier }
        check("listener: port found", found?.ports == [61999])
        check("listener: argv read", found?.command == "nc -l 127.0.0.1 61999")
        check("listener: is dev", found?.isDev == true)
        let first = scanProcesses(ScanMemory(), elapsedNs: 0)
        let cached = scanProcesses(first.memory, elapsedNs: 1).memory.seen[server.processIdentifier]?.server
        check("listener: details cached across scans", cached?.command == "nc -l 127.0.0.1 61999" && cached?.dir != nil)
        server.terminate()
    } else { check("listener: nc started", false) }

    func listener(_ bundle: String?, _ path: String) -> Listener {
        Listener(pid: 1, ports: [1], name: "", bundlePath: bundle, path: path, dir: "", project: "repo",
                 command: "", started: .now, memory: 0)
    }
    let py = "/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app"
    check("dev: framework Python counts", listener(py, py + "/Contents/MacOS/Python").isDev)
    check("dev: an app in a repo folder doesn't", !listener("/Applications/Warp.app", "/Applications/Warp.app/Contents/MacOS/stable").isDev)
    var runtime = listener("/Applications/Docker.app", "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
    runtime.name = "Docker"
    check("stop: Docker's own row can't be stopped", !runtime.stoppable)
    runtime.container = "abc"
    check("stop: a container can", runtime.stoppable && listener(nil, "/opt/homebrew/bin/node").stoppable)

    let me = getpid(), born = startTime(me).timeIntervalSince1970
    check("quit: a live pid is kept", unchanged([me], started: [born]) == [me])
    check("quit: a reused pid is dropped", unchanged([me], started: [born - 60]).isEmpty)

    let fixture = #"[{"Id":"abc123def4567890","Names":["/supabase_db"],"Image":"postgres:15","Created":1700000000,"Status":"Up 3 days","Labels":{"com.docker.compose.project":"super-invoices"},"Ports":[{"PrivatePort":5432,"PublicPort":54322,"Type":"tcp"},{"PrivatePort":5432,"PublicPort":54322,"Type":"tcp"},{"PrivatePort":9000,"Type":"tcp"}]}]"#
    let parsed = try? JSONDecoder().decode([Container].self, from: Data(fixture.utf8))
    check("docker: container row parsed",
          parsed?.first?.name == "supabase_db" && parsed?.first?.publicPorts == [54322] && parsed?.first?.project == "super-invoices")
    if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.docker.docker").isEmpty {
        let live = dockerAPI("GET", "/containers/json").flatMap { try? JSONDecoder().decode([Container].self, from: $0) }
        check("docker: engine API answers", live != nil)
    }

    func minute(_ t: Date) -> Minute {
        Minute(t: t, cpu: 0, mem: 0, swap: 0, pressure: 1, thermal: 0, watts: nil, battery: nil,
               topMem: "", topMemGB: 0, topCPU: "", topCPUPct: 0)
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    check("history: a re-saved minute isn't duplicated",
          appending(minute(t0), to: [minute(t0 - 60), minute(t0)], now: t0).map(\.t) == [t0 - 60, t0])
    check("history: past 24 h dropped", appending(minute(t0), to: [minute(t0 - 90_000)], now: t0).count == 1)
    check("chart: a sleep gap starts a new run", runs([t0, t0 + 60, t0 + 3600, t0 + 3660]) == [0, 0, 1, 1])

    if let b = readBattery() { check("battery percent", (0...100).contains(b.percent)) }
    return failed ? 1 : 0
}
