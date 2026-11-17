// dnsbench.swift v2 - sub-millisecond DNS latency probe, cross-platform (macOS + Linux)
//
// Measures the application-level RTT of a DNS query (send -> recv on a
// connected UDP socket), i.e. exactly what a real client experiences,
// separating cache-HIT from cache-MISS, and reporting exact percentiles.
// Every variable value lives in an external config file; this source holds none.
//
// No dependencies: raw POSIX sockets + a monotonic clock that is NOT NTP-slewed.
// Foundation is intentionally NOT imported.
//
// v2 changes vs v1 (see CHANGES.md):
//   - stale-reply drain: a late reply no longer cascades into false FAILs
//   - RCODE checked: SERVFAIL/REFUSED/... counted in a dedicated `err` column
//   - connected UDP sockets: cheaper send/recv path, ICMP errors surface fast
//   - zero-allocation hot path: prebuilt query templates, TXID/label patched
//     in place, non-crypto PRNG (xorshift64*)
//   - EINTR retried everywhere; per-batch randomized processing order in
//     parallel mode (removes the config-order bias on fast LANs)
//   - warm-up reads the answer min TTL and warns when a long run would
//     contaminate HIT with re-fetches
//   - anomalies report: per-resolver breakdown of timeouts / network errors /
//     invalid RCODEs (console section + HTML section + fail/err tooltips)
//   - --kts kernel RX timestamps (t1 stamped at packet arrival in the kernel),
//     --pin CPU pinning (Linux), richer --rt (Darwin time-constraint thread,
//     Linux SO_BUSY_POLL)
//   - v2.3: randomized visit order (sequential) and send order (parallel):
//     entries sharing a server no longer let the first-listed one absorb the
//     server wake-up ("first of the pair pays"); --fixed-order restores v2.2;
//     -4/-6 family filters and --order shuffle|conf|v4-first|v6-first
//   - new: --timeout-ms, --gap (pacing), --spin, --edns, --rt, --verbose
//   - v2.4: machine-readable output - --json (the whole run, versioned schema,
//     integer nanoseconds), --csv (the summary tables), --samples, --label
//   - v2.5: DNS over TCP - tcp://ADDR[:PORT] entries or --tcp for the whole
//     panel; persistent connections (warm) or --reconnect (handshake + query);
//     udp:// and tcp:// entries accept a port
//   - v2.5.1: HTML report - one colour per server (stable between the HIT
//     and MISS charts), line style per family/transport, several charts
//     beyond eight servers, X ticks that follow the range
//
// Build: see Makefile (swiftc -O dnsbench.swift -o dnsbench).
// Usage: ./dnsbench [-c FILE] [--rounds N] [--qtype A|AAAA|HTTPS|N] [--mode hit|miss|both]
//                   [--sort KEY] [--html FILE] [--json FILE] [--csv FILE]
//                   [--tcp] [--reconnect] [--gap MS] [--spin] [--edns] [--rt] [-v] [-h]

#if canImport(Darwin)
import Darwin
let SOCK_DGRAM_VAL = SOCK_DGRAM            // Int32 on Darwin
let SOCK_STREAM_VAL = SOCK_STREAM
let SEND_FLAGS: Int32 = 0                  // SIGPIPE is disabled per socket (SO_NOSIGPIPE)
#elseif canImport(Musl)
import Musl
let SOCK_DGRAM_VAL = SOCK_DGRAM            // plain Int32 on Musl (static SDK)
let SOCK_STREAM_VAL = SOCK_STREAM
let SEND_FLAGS = Int32(MSG_NOSIGNAL)       // no SIGPIPE on a connection the server closed
#elseif canImport(Glibc)
import Glibc
let SOCK_DGRAM_VAL = Int32(SOCK_DGRAM.rawValue)   // enum on Glibc
let SOCK_STREAM_VAL = Int32(SOCK_STREAM.rawValue)
let SEND_FLAGS = Int32(MSG_NOSIGNAL)
#endif

let VERSION = "2.5.1"

// ───────────────────────────── Monotonic clock ─────────────────────────────
@inline(__always)
func monotonicNanos() -> UInt64 {
#if canImport(Darwin)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)        // raw ns, excludes sleep
#else
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
#endif
}

func clockCalibration(_ costIters: Int = 1_000_000, _ resIters: Int = 100_000) -> (cost: UInt64, res: UInt64) {
    var sink: UInt64 = 0
    let s = monotonicNanos()
    for _ in 0..<costIters { sink = sink &+ monotonicNanos() }
    let e = monotonicNanos()
    let cost = costIters > 0 ? (e &- s) / UInt64(costIters) : 0
    var res = UInt64.max
    var prev = monotonicNanos()
    var seen = 0
    while seen < resIters {
        let now = monotonicNanos()
        let d = now &- prev
        prev = now
        if d > 0 { if d < res { res = d }; seen += 1 }
    }
    if res == UInt64.max { res = 0 }
    if sink == 0xDEAD_BEEF_CAFE { fputs("", stderr) }   // defeat dead-code elimination
    return (cost, res)
}

// ─────────────── Kernel RX timestamps (--kts) ───────────────
// With --kts, t1 is the kernel's own stamp on the datagram at network-stack
// entry: the scheduler wake-up and the parallel-mode batch-processing bias
// leave the measurement entirely. Default OFF: without it, the probe path is
// byte-identical to v2.1.
var ktsActive = false           // requested via --kts, may self-disable
var ktsChecked = false          // first-stamp sanity check done
var ktsRawIsNs = false          // Darwin: payload unit auto-detected
var busyPollWarned = false
enum VisitOrder { case shuffle, conf, v4First, v6First }
var visitOrder: VisitOrder = .shuffle   // --order / --fixed-order
var familyOnly: Int32? = nil            // -4 / -6 CLI filter
var baseOrder: [Int] = []               // visit order for non-shuffle modes
func orderMark() -> String {
    switch visitOrder {
    case .shuffle: return ""
    case .conf: return " (order: conf)"
    case .v4First: return " (order: v4-first)"
    case .v6First: return " (order: v6-first)"
    }
}
var ctrlBuf = [UInt8](repeating: 0, count: 64)   // cmsg scratch (single entry)
// Stream transport (TCP): per-entry reassembly state, allocated once at startup
// (left empty for datagram entries). See "Stream transport" below.
var streamBuf: [[UInt8]] = []
var streamHave: [Int] = []
#if canImport(Darwin)
let (tbNumer, tbDenom): (UInt64, UInt64) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(info.denom))
}()
#endif

@inline(__always)
func realtimeNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

// Clock used for probe timing. Without --kts this is exactly the v2.1 clock.
// With --kts on Linux, t0/deadlines/t1 all move to CLOCK_REALTIME to share the
// SO_TIMESTAMPNS domain (NTP slew <= 0.5 us per ms of RTT; do not step the
// clock mid-run). On Darwin, SCM_TIMESTAMP_MONOTONIC lives in the same
// mach/CLOCK_UPTIME_RAW domain as the default clock: nothing changes.
@inline(__always)
func probeNow() -> UInt64 {
#if canImport(Darwin)
    return monotonicNanos()
#else
    return ktsActive ? realtimeNanos() : monotonicNanos()
#endif
}

// ───────────────────────────── PRNG (non-crypto) ─────────────────────────────
// TXIDs and MISS labels do not need a CSPRNG; on Linux, SystemRandomNumberGenerator
// can cost a getrandom(2) syscall per draw. xorshift64* is a few ns, allocation-free.
struct XorShift64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state &* 0x2545_F491_4F6C_DD1D
    }
    mutating func nextId() -> UInt16 { UInt16(truncatingIfNeeded: next() >> 32) }
}

// Patch a fixed-width 12-hex-char label in place (48 bits of entropy per name).
@inline(__always)
func patchLabel(_ p: inout [UInt8], _ off: Int, _ rng: inout XorShift64) {
    var r = rng.next()
    for k in 0..<12 {
        let nib = UInt8(r & 0xF)
        p[off + k] = nib < 10 ? 48 &+ nib : 87 &+ nib     // '0'-'9', 'a'-'f'
        r >>= 4
    }
}

@inline(__always)
func patchId(_ p: inout [UInt8], _ id: UInt16) {
    p[0] = UInt8(id >> 8); p[1] = UInt8(id & 0xff)
}

// ───────────────────────────── Config ─────────────────────────────
enum Mode { case hit, miss, both }
func parseMode(_ s: String) -> Mode? {
    switch s { case "hit": return .hit; case "miss": return .miss; case "both": return .both; default: return nil }
}

struct Config {
    var rounds = 2000
    var timeoutMs = 1000
    var gapMs = 0
    var edns = false
    var hitDomains: [(name: String, qtype: UInt16?)] = []
    var missBase = "example.com"
    var qtype: UInt16 = 1
    var mode: Mode = .both
    var parallel = false
    var resolvers: [(ip: String, name: String)] = []
}

// Strict qtype parse: mnemonic or bare numeric. Returns nil on anything else
// (v1 silently mapped typos to A).
func parseQType(_ s: String) -> UInt16? {
    switch s.lowercased() {
    case "a": return 1
    case "aaaa": return 28
    case "https": return 65
    case "txt": return 16
    default:
        if let n = UInt16(s), n > 0 { return n }
        return nil
    }
}
func qtypeName(_ q: UInt16) -> String {
    switch q { case 1: return "A"; case 28: return "AAAA"; case 65: return "HTTPS"; case 16: return "TXT"; default: return "TYPE\(q)" }
}

func readFile(_ path: String) -> String? {
    let fd = open(path, O_RDONLY)
    if fd < 0 { return nil }
    defer { close(fd) }
    var data = [UInt8](); var buf = [UInt8](repeating: 0, count: 65536)
    while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; data.append(contentsOf: buf[0..<n]) }
    return String(decoding: data, as: UTF8.self)
}

func trim(_ s: Substring) -> Substring {
    var a = s.startIndex, b = s.endIndex
    while a < b, s[a] == " " || s[a] == "\t" || s[a] == "\r" { a = s.index(after: a) }
    while b > a { let p = s.index(before: b); if s[p] == " " || s[p] == "\t" || s[p] == "\r" { b = p } else { break } }
    return s[a..<b]
}

let settingKeys: Set<String> = ["rounds", "timeout_sec", "timeout_ms", "gap_ms", "edns", "hit_domain",
                                "miss_base", "qtype", "mode", "parallel"]

func loadConfig(_ path: String) -> Config? {
    guard let text = readFile(path) else { return nil }
    var c = Config()
    var timeoutMsExplicit = false
    var section = ""
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = raw
        if let h = line.firstIndex(of: "#") { line = line[line.startIndex..<h] }
        let t = trim(line)
        if t.isEmpty { continue }
        if t.first == "[" { section = String(t.dropFirst().dropLast()); continue }
        // A setting stays a setting wherever it sits. Up to 2.3 a section ran
        // to the next one whatever it held, so `miss_base = x` written after
        // [hit_domains] - as the 2.3 example file had it - became a hit domain
        // named "miss_base", and the MISS base silently kept its default.
        var isSetting = false
        if let eq = t.firstIndex(of: "=") {
            let key = String(trim(t[t.startIndex..<eq]))
            isSetting = settingKeys.contains(key)
            if isSetting && !section.isEmpty {
                fputs("dnsbench: config: '\(key)' sits inside [\(section)] - read as a setting (2.3 took it for an entry of that section); move it above the first [section]\n", stderr)
            }
        }
        if section == "resolvers" && !isSetting {
            let p = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if p.count >= 2 { c.resolvers.append((p[0], p[1])) } else if p.count == 1 { c.resolvers.append((p[0], p[0])) }
            continue
        }
        if section == "hit_domains" && !isSetting {
            let p = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if p.isEmpty { continue }
            if p.count >= 2 {
                if let q = parseQType(p[1]) { c.hitDomains.append((p[0], q)) }
                else { fputs("dnsbench: config: unknown qtype '\(p[1])' for \(p[0]), using global default\n", stderr); c.hitDomains.append((p[0], nil)) }
            } else {
                c.hitDomains.append((p[0], nil))
            }
            continue
        }
        guard let eq = t.firstIndex(of: "=") else { continue }
        let key = String(trim(t[t.startIndex..<eq]))
        let val = String(trim(t[t.index(after: eq)...]))
        switch key {
        case "rounds":      c.rounds = Int(val) ?? c.rounds
        case "timeout_sec": if !timeoutMsExplicit { c.timeoutMs = (Int(val) ?? (c.timeoutMs / 1000)) * 1000 }
        case "timeout_ms":  if let n = Int(val), n > 0 { c.timeoutMs = n; timeoutMsExplicit = true }
        case "gap_ms":      c.gapMs = Int(val) ?? c.gapMs
        case "edns":        c.edns = (val == "yes" || val == "true" || val == "1")
        case "hit_domain":  c.hitDomains.append((val, nil))
        case "miss_base":   c.missBase = val
        case "qtype":
            if let q = parseQType(val) { c.qtype = q }
            else { fputs("dnsbench: config: unknown qtype '\(val)', keeping \(qtypeName(c.qtype))\n", stderr) }
        case "mode":        c.mode = parseMode(val) ?? c.mode
        case "parallel":    c.parallel = (val == "yes" || val == "true" || val == "1")
        default:            break
        }
    }
    if c.hitDomains.isEmpty { c.hitDomains = [("www.apple.com", nil)] }
    return c
}

// ───────────────────────────── DNS query ─────────────────────────────
// Labels must be 1..63 bytes, full name <= 254 with length bytes: validated at
// startup so buildQuery can stay trap-free.
func validDNSName(_ name: String) -> Bool {
    var total = 0; var labels = 0
    for label in name.split(separator: ".") {
        let n = label.utf8.count
        if n > 63 { return false }
        total += n + 1; labels += 1
    }
    return labels > 0 && total <= 254
}

func buildQuery(id: UInt16, name: String, qtype: UInt16, edns: Bool) -> [UInt8] {
    var p = [UInt8](); p.reserveCapacity(48 + name.utf8.count)
    p += [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, edns ? 1 : 0]
    for label in name.split(separator: ".") { let b = Array(label.utf8); p.append(UInt8(b.count)); p += b }
    p.append(0x00)
    p += [UInt8(qtype >> 8), UInt8(qtype & 0xff), 0x00, 0x01]
    if edns {
        // OPT pseudo-RR: root name, TYPE=41, CLASS=UDP payload 1232 (Flag Day 2020),
        // TTL=0 (ext-rcode/version/flags), RDLEN=0.
        p += [0x00, 0x00, 0x29, 0x04, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    }
    return p
}

// ───────────────────────── Address resolution (v4/v6) ─────────────────────────
// [resolvers] address syntax. A bare IP literal is plain DNS over UDP, port 53
// (the historical form, unchanged). A scheme selects the transport and allows
// a port:   udp://192.0.2.1:5353   tcp://192.0.2.1   tcp://[2001:db8::1]:5353
// Any other scheme is refused here rather than silently probed over UDP.
enum Transport { case udp, tcp }

func parseTarget(_ spec: String) -> (transport: Transport, host: String, port: UInt16)? {
    var transport = Transport.udp
    let rest: Substring
    if spec.hasPrefix("udp://") { rest = spec.dropFirst(6) }
    else if spec.hasPrefix("tcp://") { transport = .tcp; rest = spec.dropFirst(6) }
    else if spec.utf8.contains(UInt8(ascii: "/")) { return nil }
    else { return (.udp, spec, 53) }                   // bare literal: never carries a port
    var host = rest
    var port: UInt16 = 53
    if rest.first == "[" {                             // [v6] or [v6]:port
        guard let close = rest.firstIndex(of: "]") else { return nil }
        host = rest[rest.index(after: rest.startIndex)..<close]
        let tail = rest[rest.index(after: close)...]
        if !tail.isEmpty {
            guard tail.first == ":", let p = UInt16(tail.dropFirst()), p > 0 else { return nil }
            port = p
        }
    } else if rest.utf8.filter({ $0 == UInt8(ascii: ":") }).count == 1, let c = rest.firstIndex(of: ":") {
        guard let p = UInt16(rest[rest.index(after: c)...]), p > 0 else { return nil }   // v4:port
        host = rest[..<c]; port = p
    }
    return host.isEmpty ? nil : (transport, String(host), port)
}

func resolveSockaddr(_ ip: String, _ port: UInt16) -> (sockaddr_storage, socklen_t, Int32)? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_DGRAM_VAL; hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    var res: UnsafeMutablePointer<addrinfo>? = nil
    guard getaddrinfo(ip, String(port), &hints, &res) == 0, let info = res else { return nil }
    defer { freeaddrinfo(res) }
    var ss = sockaddr_storage()
    memcpy(&ss, info.pointee.ai_addr, Int(info.pointee.ai_addrlen))
    return (ss, info.pointee.ai_addrlen, info.pointee.ai_family)
}

func setRcvTimeoutMs(_ fd: Int32, _ ms: Int) {
    var tv = timeval()
    tv.tv_sec = .init(ms / 1000)
    tv.tv_usec = .init((ms % 1000) * 1000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

// Connected UDP socket: send/recv instead of sendto/recvfrom (no address copy
// per call), kernel-side filtering of foreign datagrams, and ICMP errors
// (port/host unreachable) surfaced as ECONNREFUSED & co on the next call -
// a dead resolver fails fast instead of costing rounds x timeout.
func openConnectedSocket(addr: inout sockaddr_storage, addrlen: socklen_t, family: Int32,
                         timeoutMs: Int, nonblocking: Bool) -> Int32 {
    let fd = socket(family, SOCK_DGRAM_VAL, 0)
    if fd < 0 { return -1 }
    setRcvTimeoutMs(fd, timeoutMs)
    let rc = withUnsafePointer(to: &addr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            connect(fd, sap, addrlen)
        }
    }
    if rc != 0 { close(fd); return -1 }
    if nonblocking { let fl = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK) }
    return fd
}

// ───────────────────────────── Probing ─────────────────────────────
enum Probe { case ok(UInt64); case rcode(UInt64, UInt8); case timeout; case netErr; case closed }

// NOERROR and NXDOMAIN are valid latency samples (NXDOMAIN is the expected MISS
// answer). Anything else (SERVFAIL, REFUSED, ...) measures a failure path -
// e.g. Pi-hole FTL rate-limiting answers REFUSED - and lands in `err`.
// Timeouts and network errors (ICMP unreachable, send failures) land in
// `fail`, and so does `closed`: a stream query whose connection the server
// closed or reset twice - a first close only makes the probe ask again. Both
// are broken down per kind in the anomalies report.
@inline(__always) func rcodeValid(_ rc: UInt8) -> Bool { rc == 0 || rc == 3 }

func rcodeName(_ rc: Int) -> String {
    switch rc {
    case 1: return "FORMERR"; case 2: return "SERVFAIL"; case 4: return "NOTIMP"
    case 5: return "REFUSED"; default: return "RCODE\(rc)"
    }
}

// One receive; with --kts also returns the kernel RX timestamp converted into
// the probe clock domain. CMSG_* are C macros invisible to Swift, so the
// single control message is parsed by hand: Darwin cmsghdr is 12 bytes then a
// u64 of mach ticks (SCM_TIMESTAMP_MONOTONIC); Linux cmsghdr is 16 bytes then
// a timespec (SCM_TIMESTAMPNS, CLOCK_REALTIME). The first stamp is
// sanity-checked against the user clock; on domain mismatch kts self-disables
// and the run continues on the user-space clock.
func recvWithTS(fd: Int32, buf: inout [UInt8]) -> (Int, UInt64?) {
    if !ktsActive {
        let n = buf.withUnsafeMutableBytes { rb in recv(fd, rb.baseAddress, rb.count, 0) }
        return (n, nil)
    }
    var msg = msghdr()
    var iov = iovec()
    let n: Int = buf.withUnsafeMutableBytes { rb in
        ctrlBuf.withUnsafeMutableBytes { cb in
            iov.iov_base = rb.baseAddress
            iov.iov_len = rb.count
            return withUnsafeMutablePointer(to: &iov) { iovp -> Int in
                msg.msg_iov = iovp
                msg.msg_iovlen = numericCast(1)
                msg.msg_control = cb.baseAddress
                msg.msg_controllen = numericCast(cb.count)
                return recvmsg(fd, &msg, 0)
            }
        }
    }
    if n < 0 || Int(msg.msg_controllen) < MemoryLayout<cmsghdr>.size { return (n, nil) }
    let ts: UInt64? = ctrlBuf.withUnsafeBytes { cb in
        let ch = cb.loadUnaligned(fromByteOffset: 0, as: cmsghdr.self)
#if canImport(Darwin)
        guard ch.cmsg_level == SOL_SOCKET && ch.cmsg_type == SCM_TIMESTAMP_MONOTONIC && Int(ch.cmsg_len) >= 20 else { return nil }
        let raw = cb.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
        if !ktsChecked {
            ktsChecked = true
            let now = monotonicNanos()
            let conv = raw &* tbNumer / tbDenom
            let dConv = conv > now ? conv &- now : now &- conv
            let dRaw = raw > now ? raw &- now : now &- raw
            if dConv < 5_000_000_000 { ktsRawIsNs = false }
            else if dRaw < 5_000_000_000 { ktsRawIsNs = true; fputs("kts: kernel stamps already in ns\n", stderr) }
            else { ktsActive = false; fputs("kts: kernel timestamp domain mismatch, disabled (user clock fallback)\n", stderr); return nil }
        }
        return ktsRawIsNs ? raw : raw &* tbNumer / tbDenom
#else
        guard ch.cmsg_level == SOL_SOCKET && ch.cmsg_type == SCM_TIMESTAMPNS && Int(ch.cmsg_len) >= 32 else { return nil }
        let sec = cb.loadUnaligned(fromByteOffset: 16, as: Int64.self)
        let nsec = cb.loadUnaligned(fromByteOffset: 24, as: Int64.self)
        return UInt64(sec) &* 1_000_000_000 &+ UInt64(nsec)
#endif
    }
    return (n, ts)
}

// Send one query on a connected socket and wait for the matching reply.
// Mismatched or truncated datagrams (typically a stale reply from a previous
// timed-out round) are drained and the wait continues within the remaining
// budget, instead of failing: in v1 a single late reply cascaded into a chain
// of false FAILs on every subsequent round. EINTR is retried. In blocking mode
// the happy path is identical to v1 (one send + one recv, SO_RCVTIMEO); the
// timeout is only re-armed on the rare drain path, and restored afterwards.
// In spin mode (non-blocking socket) the wait is a recv busy-loop: no scheduler
// wake-up in the measurement, at the cost of one core at 100%.
func measureOnce(fd: Int32, query: [UInt8], expectId: UInt16,
                 timeoutMs: Int, spin: Bool, recvBuf: inout [UInt8]) -> Probe {
    let t0 = probeNow()
    let sent = query.withUnsafeBytes { qb in send(fd, qb.baseAddress, qb.count, 0) }
    if sent < 0 { return .netErr }
    let deadline = t0 &+ UInt64(timeoutMs) &* 1_000_000
    var shrunk = false
    defer { if shrunk { setRcvTimeoutMs(fd, timeoutMs) } }
    while true {
        let (n, kt) = recvWithTS(fd: fd, buf: &recvBuf)
        let t1 = probeNow()
        if n >= 12 {
            let rid = (UInt16(recvBuf[0]) << 8) | UInt16(recvBuf[1])
            if rid == expectId && (recvBuf[2] & 0x80) != 0 {
                let rc = recvBuf[3] & 0x0F
                let rx = kt ?? t1                  // kernel RX stamp when available
                return rcodeValid(rc) ? .ok(rx &- t0) : .rcode(rx &- t0, rc)
            }
        }
        if n < 0 {
            let e = errno
            let retryable = (e == EINTR) || (spin && (e == EAGAIN || e == EWOULDBLOCK))
            if !retryable {
                // Blocking-mode EAGAIN/EWOULDBLOCK is the SO_RCVTIMEO expiry;
                // anything else is a network error (ICMP unreachable & co).
                return (e == EAGAIN || e == EWOULDBLOCK) ? .timeout : .netErr
            }
        }
        if t1 >= deadline { return .timeout }
        if !spin {
            let remMs = Int((deadline &- t1) / 1_000_000)
            setRcvTimeoutMs(fd, remMs > 0 ? remMs : 1)
            shrunk = true
        }
    }
}

// Parallel fan-out / fan-in, zero-allocation: the caller-provided template gets
// its TXID (and MISS label) patched right before each send - send() copies the
// payload into the kernel, so one shared buffer serves all resolvers. One
// request stays in flight PER RESOLVER (no on-resolver contention); the
// wall-clock per round collapses from sum(latencies) to ~max(latency).
// Ready descriptors are processed in a per-batch random order: with several
// replies landing in the same poll() batch on a fast LAN, fixed ordering
// systematically favoured early [resolvers] entries by a few us. EINTR is
// retried; POLLERR (ICMP) counts as fail; RCODE handled as in sequential mode.
// Stream entries (TCP, persistent connections) ride the same fan-out: the
// template leaves length-prefixed, the reply is reassembled on POLLIN. A
// stream closed with its query in flight is redialled without blocking the
// batch (`stage`: 0 first attempt, 1 reconnecting, 2 query repeated) and its
// query repeated once, t0 unchanged - see "Stream transport".
func fanPhase(fds: inout [Int32], streams: [Bool], stage: inout [UInt8], template: inout [UInt8], labelOffset: Int?,
              rng: inout XorShift64, timeoutMs: Int, recvBuf: inout [UInt8],
              ids: inout [UInt16], t0: inout [UInt64], pfds: inout [pollfd],
              order: inout [Int], results: inout [Probe?]) {
    let n = fds.count
    var pending = 0
    // Send order: entries sharing a server must not let the first-listed one
    // systematically absorb the server wake-up (see --order).
    if visitOrder == .shuffle {
        for k in 0..<n { order[k] = k }
        if n > 1 {
            var k = n - 1
            while k > 0 { let j = Int(rng.next() % UInt64(k + 1)); order.swapAt(k, j); k -= 1 }
        }
    } else {
        for k in 0..<n { order[k] = baseOrder[k] }
    }
    for oi in 0..<n {
        let i = order[oi]
        results[i] = nil; stage[i] = 0
        pfds[i].fd = -1; pfds[i].events = Int16(POLLIN); pfds[i].revents = 0
        if fds[i] < 0 { results[i] = .netErr; continue }
        let id = rng.nextId()
        ids[i] = id
        patchId(&template, id)
        if let lo = labelOffset { patchLabel(&template, lo, &rng) }
        let sent: Bool
        if streams[i] {
            t0[i] = probeNow()
            sent = streamSend(fds[i], template)
            if !sent {                                 // closed under the send: redial, or give up
                let lost = streamReset(errno)
                close(fds[i]); fds[i] = -1
                if lost, let nfd = streamRedial(i) {
                    fds[i] = nfd; streamHave[i] = 0
                    pfds[i].fd = nfd; pfds[i].events = Int16(POLLOUT); stage[i] = 1
                    pending += 1
                } else {
                    results[i] = lost ? .closed : .netErr
                }
                continue
            }
        } else {
            t0[i] = probeNow()
            sent = template.withUnsafeBytes { qb in send(fds[i], qb.baseAddress, qb.count, 0) } >= 0
        }
        if sent { pfds[i].fd = fds[i]; pending += 1 } else { results[i] = .netErr }
    }
    let deadline = probeNow() &+ UInt64(timeoutMs) &* 1_000_000
    while pending > 0 {
        let now = probeNow()
        if now >= deadline { break }
        let remMs = Int32(min(UInt64(Int32.max), (deadline &- now) / 1_000_000))
        let rc = pfds.withUnsafeMutableBufferPointer { buf in
            poll(buf.baseAddress, nfds_t(buf.count), remMs > 0 ? remMs : 1)
        }
        if rc < 0 { if errno == EINTR { continue }; break }
        if rc == 0 { continue }                    // loop re-checks the deadline
        for k in 0..<n { order[k] = k }            // per-batch Fisher-Yates shuffle
        if n > 1 {
            var k = n - 1
            while k > 0 { let j = Int(rng.next() % UInt64(k + 1)); order.swapAt(k, j); k -= 1 }
        }
        for oi in 0..<n {
            let i = order[oi]
            if pfds[i].fd < 0 { continue }
            let rev = Int32(pfds[i].revents)
            if rev == 0 { continue }
            pfds[i].revents = 0
            if streams[i] {
                if stage[i] == 1 {                         // the redial completed, one way or the other
                    if connectDone(fds[i]) {
                        patchId(&template, ids[i])
                        if let lo = labelOffset { patchLabel(&template, lo, &rng) }
                        if streamSend(fds[i], template) {
                            pfds[i].events = Int16(POLLIN); stage[i] = 2
                            continue
                        }
                    }
                    results[i] = .netErr
                    close(fds[i]); fds[i] = -1         // reopened before the next phase
                    pfds[i].fd = -1; pending -= 1
                    continue
                }
                let m = streamFill(fds[i], &streamBuf[i], streamHave[i])
                let t1 = probeNow()
                if m > 0 {
                    streamHave[i] += m
                    if let r = streamTake(&streamBuf[i], &streamHave[i], ids[i], wantTTL: false) {
                        results[i] = rcodeValid(r.rcode) ? .ok(t1 &- t0[i]) : .rcode(t1 &- t0[i], r.rcode)
                        pfds[i].fd = -1; pending -= 1
                    }
                } else if m == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    let lost = m == 0 || streamReset(errno)
                    if lost && stage[i] == 0, let nfd = streamRedial(i) {
                        close(fds[i]); fds[i] = nfd; streamHave[i] = 0
                        pfds[i].fd = nfd; pfds[i].events = Int16(POLLOUT); stage[i] = 1
                    } else {
                        results[i] = lost ? .closed : .netErr
                        close(fds[i]); fds[i] = -1         // reopened before the next phase
                        pfds[i].fd = -1; pending -= 1
                    }
                }
                continue
            }
            if (rev & POLLIN) != 0 {
                let (m, kt) = recvWithTS(fd: fds[i], buf: &recvBuf)
                let t1 = kt ?? probeNow()
                if m >= 12 {
                    let rid = (UInt16(recvBuf[0]) << 8) | UInt16(recvBuf[1])
                    if rid == ids[i] && (recvBuf[2] & 0x80) != 0 {
                        let rcode = recvBuf[3] & 0x0F
                        results[i] = rcodeValid(rcode) ? .ok(t1 &- t0[i]) : .rcode(t1 &- t0[i], rcode)
                        pfds[i].fd = -1; pending -= 1
                    }
                    // mismatch: drained; poll fires again if the real reply is queued
                } else if m < 0 {
                    let e = errno
                    if e != EINTR && e != EAGAIN && e != EWOULDBLOCK {
                        results[i] = .netErr               // ICMP error surfaced on recv
                        pfds[i].fd = -1; pending -= 1
                    }
                }
            } else if (rev & (POLLERR | POLLHUP | POLLNVAL)) != 0 {
                let m = recvBuf.withUnsafeMutableBytes { rb in recv(fds[i], rb.baseAddress, rb.count, 0) }
                _ = m                                      // fetch & clear the socket error
                results[i] = .netErr
                pfds[i].fd = -1; pending -= 1
            }
        }
    }
    for i in 0..<n where results[i] == nil { results[i] = .timeout }   // no reply in budget
}

// ───────────────────────── Warm-up & TTL awareness ─────────────────────────
// Minimum TTL across the answer section, bounds-checked; nil on malformed or
// empty answers. Only used at warm-up (never in the timed path).
func minAnswerTTL(_ buf: [UInt8], _ n: Int) -> UInt32? {
    if n < 12 { return nil }
    let qdcount = Int(buf[4]) << 8 | Int(buf[5])
    let ancount = Int(buf[6]) << 8 | Int(buf[7])
    if ancount == 0 { return nil }
    var off = 12
    func skipName() -> Bool {
        var steps = 0
        while true {
            if off >= n { return false }
            let len = Int(buf[off])
            if len == 0 { off += 1; return true }
            if len & 0xC0 == 0xC0 { off += 2; return true }   // compression pointer
            off += 1 + len
            steps += 1
            if steps > 64 { return false }
        }
    }
    for _ in 0..<qdcount {
        if !skipName() { return nil }
        off += 4
        if off > n { return nil }
    }
    var minTTL: UInt32? = nil
    for _ in 0..<ancount {
        if !skipName() { return nil }
        if off + 10 > n { return nil }
        let ttl = UInt32(buf[off + 4]) << 24 | UInt32(buf[off + 5]) << 16
                | UInt32(buf[off + 6]) << 8  | UInt32(buf[off + 7])
        let rdlen = Int(buf[off + 8]) << 8 | Int(buf[off + 9])
        off += 10 + rdlen
        if off > n { return nil }
        if minTTL == nil || ttl < minTTL! { minTTL = ttl }
    }
    return minTTL
}

// One warm-up query; works on blocking and non-blocking sockets (1 ms naps on
// EAGAIN). Returns the answer's min TTL when a matching reply arrives.
func warmupProbe(fd: Int32, query: [UInt8], expectId: UInt16,
                 timeoutMs: Int, recvBuf: inout [UInt8]) -> UInt32? {
    let sent = query.withUnsafeBytes { qb in send(fd, qb.baseAddress, qb.count, 0) }
    if sent < 0 { return nil }
    let deadline = monotonicNanos() &+ UInt64(timeoutMs) &* 1_000_000
    while true {
        let (n, _) = recvWithTS(fd: fd, buf: &recvBuf)   // also triggers kts calibration
        if n >= 12 {
            let rid = (UInt16(recvBuf[0]) << 8) | UInt16(recvBuf[1])
            if rid == expectId { return minAnswerTTL(recvBuf, n) }
        }
        if monotonicNanos() >= deadline { return nil }
        if n < 0 {
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                var ts = timespec(); ts.tv_sec = .init(0); ts.tv_nsec = .init(1_000_000)
                nanosleep(&ts, nil)
            } else if e != EINTR {
                return nil
            }
        }
    }
}

// ───────────────────────── Stream transport (TCP) ─────────────────────────
// DNS over TCP (RFC 1035 4.2.2, RFC 7766): every message is preceded by a
// two-byte length. Two ways to sample it, because a client can experience two
// different things:
//   - warm (default): one persistent connection per resolver, as a forwarder
//     or a resolver library keeps it. The sample is send -> complete reply,
//     the same window as UDP. The server may close an idle connection at any
//     time (RFC 7766): an idle close is detected, and the connection reopened,
//     BEFORE t0.
//   - cold (--reconnect): a new connection per query. t0 is taken before
//     connect(): the sample is handshake + query, what a stub falling back
//     from a truncated UDP answer pays.
// When the server closes or resets a connection with a query in flight, the
// probe does what a client should (RFC 7766 6.2.4): it connects again and
// repeats the query - once, inside the same timed window and timeout budget. That sample
// spans the lost attempt, the handshake and the query, and the query is
// counted `retried`. A second close makes it a `closed` fail.
// Replies are reassembled across segments. A complete message that does not
// answer the current query (late reply to a query that timed out) is dropped,
// like stale datagrams on the UDP path. Kernel RX timestamps (--kts) remain a
// datagram facility: stream samples take t1 in user space.
let streamCap = 2 + 65535                              // length prefix + largest DNS message

enum ConnectResult { case ok, timeout, failed }

// Non-blocking TCP socket, not yet connected. TCP_NODELAY: the one small write
// of a query must leave at once.
func makeStreamSocket(family: Int32, busyPoll: Bool) -> Int32 {
    let fd = socket(family, SOCK_STREAM_VAL, 0)
    if fd < 0 { return -1 }
    var one: Int32 = 1
    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
#if canImport(Darwin)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
#else
    if busyPoll {
        var us: Int32 = 50
        setsockopt(fd, SOL_SOCKET, SO_BUSY_POLL, &us, socklen_t(MemoryLayout<Int32>.size))
    }
#endif
    let fl = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
    return fd
}

// Start a non-blocking connect; false when it fails at once. Completion shows
// as writability, and connectDone() then tells how it went.
func beginConnect(_ fd: Int32, _ addr: inout sockaddr_storage, _ addrlen: socklen_t) -> Bool {
    let rc = withUnsafePointer(to: &addr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            connect(fd, sap, addrlen)
        }
    }
    return rc == 0 || errno == EINPROGRESS || errno == EINTR
}

func connectDone(_ fd: Int32) -> Bool {
    var soErr: Int32 = 0
    var soLen = socklen_t(MemoryLayout<Int32>.size)
    return getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen) == 0 && soErr == 0
}

// Connect bounded by `deadline` (probe clock): a filtered port must cost the
// configured timeout, not the OS default of a minute or more. --spin
// busy-polls instead of sleeping, as on the receive side.
func connectStream(_ fd: Int32, _ addr: inout sockaddr_storage, _ addrlen: socklen_t,
                   deadline: UInt64, spin: Bool) -> ConnectResult {
    if !beginConnect(fd, &addr, addrlen) { return .failed }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    while true {
        let now = probeNow()
        if now >= deadline { return .timeout }
        let remMs = Int32(min(UInt64(Int32.max), (deadline &- now) / 1_000_000))
        let pr = poll(&pfd, 1, spin ? 0 : (remMs > 0 ? remMs : 1))
        if pr < 0 { if errno == EINTR { continue }; return .failed }
        if pr == 0 { continue }                        // loop re-checks the deadline
        return connectDone(fd) ? .ok : .failed
    }
}

// Leave a connected stream in the mode the run uses: blocking under
// SO_RCVTIMEO, or non-blocking (--parallel, --spin).
func settleStream(_ fd: Int32, timeoutMs: Int, nonblocking: Bool) {
    if nonblocking { return }
    let fl = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, fl & ~O_NONBLOCK)
    setRcvTimeoutMs(fd, timeoutMs)
}

// Open + connect within `timeoutMs`, outside any timed window.
func openStream(addr: inout sockaddr_storage, addrlen: socklen_t, family: Int32,
                timeoutMs: Int, nonblocking: Bool, busyPoll: Bool) -> (fd: Int32, result: ConnectResult) {
    let fd = makeStreamSocket(family: family, busyPoll: busyPoll)
    if fd < 0 { return (-1, .failed) }
    let r = connectStream(fd, &addr, addrlen, deadline: probeNow() &+ UInt64(timeoutMs) &* 1_000_000, spin: false)
    if r != .ok { close(fd); return (-1, r) }
    settleStream(fd, timeoutMs: timeoutMs, nonblocking: nonblocking)
    return (fd, .ok)
}

// A retry inside the parallel fan-out cannot block on a handshake: start a
// non-blocking connect to entry i's address; fanPhase resumes on writability.
func streamRedial(_ i: Int) -> Int32? {
    let fd = makeStreamSocket(family: fams[i], busyPoll: rtFlag)
    if fd < 0 { return nil }
    if !beginConnect(fd, &sas[i], salens[i]) { close(fd); return nil }
    return fd
}

// errno of a stream the peer has closed or reset (as opposed to a network error).
@inline(__always) func streamReset(_ e: Int32) -> Bool { e == ECONNRESET || e == EPIPE }

// Has the server closed this idle connection? Checked before t0. Pending bytes
// are a late reply, not a close: the next exchange drops them. The check
// cannot be airtight - a close that crosses the next query on the wire is
// only seen after the send: the exchange then reports `closed`, and the
// caller asks again on a new connection.
func streamStale(_ fd: Int32) -> Bool {
    var b: UInt8 = 0
    let n = recv(fd, &b, 1, Int32(MSG_PEEK) | Int32(MSG_DONTWAIT))
    if n > 0 { return false }
    if n == 0 { return true }                          // orderly close
    return !(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
}

// Length-prefixed send of the shared datagram template: prefix and message
// leave in one sendmsg(), hence one segment - no second template set.
@inline(__always)
func streamSend(_ fd: Int32, _ query: [UInt8]) -> Bool {
    var prefix: (UInt8, UInt8) = (UInt8(truncatingIfNeeded: query.count >> 8), UInt8(truncatingIfNeeded: query.count))
    return query.withUnsafeBytes { qb -> Bool in
        withUnsafeMutableBytes(of: &prefix) { pb -> Bool in
            var iov = (iovec(iov_base: pb.baseAddress, iov_len: 2),
                       iovec(iov_base: UnsafeMutableRawPointer(mutating: qb.baseAddress), iov_len: qb.count))
            return withUnsafeMutablePointer(to: &iov) { ip -> Bool in
                ip.withMemoryRebound(to: iovec.self, capacity: 2) { iovp -> Bool in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = numericCast(2)
                    return sendmsg(fd, &msg, SEND_FLAGS) == 2 + qb.count
                }
            }
        }
    }
}

// One recv() appended to the reassembly buffer; returns what recv returned.
@inline(__always)
func streamFill(_ fd: Int32, _ buf: inout [UInt8], _ have: Int) -> Int {
    buf.withUnsafeMutableBytes { rb in recv(fd, rb.baseAddress! + have, rb.count - have, 0) }
}

// Complete messages at the head of the buffer: the one answering `expectId`
// returns its RCODE (and, at warm-up, the answer's min TTL); any other is
// dropped. nil = the reply is not complete yet.
func streamTake(_ buf: inout [UInt8], _ have: inout Int, _ expectId: UInt16,
                wantTTL: Bool) -> (rcode: UInt8, ttl: UInt32?)? {
    while have >= 2 {
        let len = Int(buf[0]) << 8 | Int(buf[1])
        let total = 2 + len
        if have < total { return nil }
        let match = len >= 12 && (UInt16(buf[2]) << 8 | UInt16(buf[3])) == expectId && (buf[4] & 0x80) != 0
        let rcode = match ? buf[5] & 0x0F : 0
        let ttl = match && wantTTL ? minAnswerTTL(Array(buf[2..<total]), len) : nil
        let rest = have - total
        if rest > 0 { buf.withUnsafeMutableBytes { rb in _ = memmove(rb.baseAddress, rb.baseAddress! + total, rest) } }
        have = rest
        if match { return (rcode, ttl) }
    }
    return nil
}

// One query on a connected stream: send, then read until the matching reply is
// complete. `t0` is given when the timed window opened earlier (cold mode:
// before connect()), taken here otherwise. Blocking sockets sleep in recv()
// under SO_RCVTIMEO - the happy path is one send + one recv, like UDP - and
// the timeout is only re-armed when a reply arrives in pieces or a stale one
// is dropped. Non-blocking sockets poll(), or busy-loop under --spin.
// `alive` tells the caller whether the connection can carry the next query,
// `t0` when the window opened - a retry after a close keeps it.
func streamExchange(fd: Int32, query: [UInt8], expectId: UInt16, t0 opened: UInt64?,
                    timeoutMs: Int, nonblock: Bool, spin: Bool, wantTTL: Bool,
                    buf: inout [UInt8], have: inout Int) -> (probe: Probe, alive: Bool, ttl: UInt32?, t0: UInt64) {
    let t0 = opened ?? probeNow()
    if !streamSend(fd, query) { return (streamReset(errno) ? .closed : .netErr, false, nil, t0) }
    let deadline = t0 &+ UInt64(timeoutMs) &* 1_000_000
    var shrunk = false
    defer { if shrunk { setRcvTimeoutMs(fd, timeoutMs) } }
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        if nonblock && !spin {
            let now = probeNow()
            if now >= deadline { return (.timeout, true, nil, t0) }
            let remMs = Int32(min(UInt64(Int32.max), (deadline &- now) / 1_000_000))
            _ = poll(&pfd, 1, remMs > 0 ? remMs : 1)
        }
        let n = streamFill(fd, &buf, have)
        let t1 = probeNow()
        if n > 0 {
            have += n
            if let r = streamTake(&buf, &have, expectId, wantTTL: wantTTL) {
                return (rcodeValid(r.rcode) ? .ok(t1 &- t0) : .rcode(t1 &- t0, r.rcode), true, r.ttl, t0)
            }
        } else if n == 0 {
            return (.closed, false, nil, t0)           // closed by the server, query in flight
        } else {
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                if !nonblock { return (.timeout, true, nil, t0) } // SO_RCVTIMEO expiry
            } else if e != EINTR {
                return (streamReset(e) ? .closed : .netErr, false, nil, t0)
            }
        }
        if t1 >= deadline { return (.timeout, true, nil, t0) }
        if !nonblock {
            let remMs = Int((deadline &- t1) / 1_000_000)
            setRcvTimeoutMs(fd, remMs > 0 ? remMs : 1)
            shrunk = true
        }
    }
}

func sleepMs(_ ms: Int) {
    if ms <= 0 { return }
    var ts = timespec()
    ts.tv_sec = .init(ms / 1000)
    ts.tv_nsec = .init((ms % 1000) * 1_000_000)
    nanosleep(&ts, nil)
}

// Best-effort scheduling hints (--rt). Darwin: user-interactive QoS (favours
// P-cores on Apple Silicon; a default-QoS CLI can land on E-cores with slower,
// noisier syscalls). Linux: SCHED_FIFO + mlockall when privileges allow.
func applyRuntimeHints() {
#if canImport(Darwin)
    let rc = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    fputs(rc == 0 ? "rt: QoS user-interactive set\n" : "rt: QoS request failed (\(rc))\n", stderr)
    // Time-constraint (real-time) scheduling class, like audio threads:
    // tighter wake-up latency on the blocking recv path. Best-effort; the
    // thread mostly sleeps, so demotion for overrunning is not a concern.
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    func ticks(_ ns: UInt64) -> UInt32 { UInt32(ns &* UInt64(tb.denom) / UInt64(tb.numer)) }
    var pol = thread_time_constraint_policy_data_t(period: ticks(300_000),
        computation: ticks(50_000), constraint: ticks(300_000), preemptible: 1)
    let cnt = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &pol) { pp in
        pp.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { ip in
            thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), ip, cnt)
        }
    }
    fputs(kr == KERN_SUCCESS ? "rt: time-constraint thread policy set\n" : "rt: time-constraint policy refused (\(kr)), continuing\n", stderr)
#else
    var sp = sched_param()
    sp.sched_priority = 10
    if sched_setscheduler(0, Int32(SCHED_FIFO), &sp) == 0 {
        fputs("rt: SCHED_FIFO prio 10 set\n", stderr)
    } else {
        fputs("rt: SCHED_FIFO unavailable (needs CAP_SYS_NICE/root), continuing best-effort\n", stderr)
    }
    if mlockall(Int32(MCL_CURRENT | MCL_FUTURE)) != 0 {
        fputs("rt: mlockall failed, continuing\n", stderr)
    }
#endif
}

// ───────────────────────────── Statistics ─────────────────────────────
struct Acc {
    var samples: [UInt64] = []
    var timeouts = 0
    var netErrs = 0                                    // ICMP unreachable, send errors
    var closes = 0                                     // stream closed by the server, twice for one query
    var retried = 0                                    // stream queries repeated after a close (not a fail)
    var rcodeCounts = [Int](repeating: 0, count: 16)   // invalid RCODEs by value
    var fails: Int { timeouts + netErrs + closes }
    var rcodeErrs: Int { rcodeCounts.reduce(0, +) }
}

func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
    if sorted.isEmpty { return 0 }
    let rank = p / 100.0 * Double(sorted.count - 1)
    let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
    if lo == hi { return sorted[lo] }
    let frac = rank - Double(lo)
    return UInt64(Double(sorted[lo]) * (1 - frac) + Double(sorted[hi]) * frac)
}
func meanStd(_ s: [UInt64]) -> (UInt64, UInt64) {
    if s.isEmpty { return (0, 0) }
    let mean = Double(s.reduce(0, +)) / Double(s.count)
    let varr = s.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(s.count)
    return (UInt64(mean), UInt64(varr.squareRoot()))
}

enum SortKey { case min, p50, p90, p99, p999, max, mean }
func parseSort(_ s: String) -> SortKey? {
    switch s {
    case "min": return .min; case "p50", "median": return .p50; case "p90": return .p90
    case "p99": return .p99; case "p999", "p99.9": return .p999; case "max": return .max
    case "mean", "avg": return .mean; default: return nil
    }
}
func metricName(_ k: SortKey) -> String {
    switch k {
    case .min: return "min"; case .p50: return "p50"; case .p90: return "p90"; case .p99: return "p99"
    case .p999: return "p99.9"; case .max: return "max"; case .mean: return "mean"
    }
}
func sortValue(_ a: Acc, _ k: SortKey) -> UInt64 {
    if a.samples.isEmpty { return UInt64.max }
    var s = a.samples; s.sort()
    switch k {
    case .min: return percentile(s, 0); case .p50: return percentile(s, 50); case .p90: return percentile(s, 90)
    case .p99: return percentile(s, 99); case .p999: return percentile(s, 99.9); case .max: return percentile(s, 100)
    case .mean: return meanStd(s).0
    }
}
func ordering(_ accs: [Acc], _ k: SortKey?) -> [Int] {
    let idx = Array(accs.indices)
    guard let k = k else { return idx }
    let keys = accs.map { sortValue($0, k) }
    return idx.sorted { keys[$0] < keys[$1] }
}
func bestValue(_ accs: [Acc], _ k: SortKey) -> UInt64 {
    var best = UInt64.max
    for a in accs { let v = sortValue(a, k); if v < best { best = v } }
    return best
}

func pad2(_ v: UInt64) -> String { let s = String(v); return s.count >= 2 ? s : "0" + s }
func pad3(_ v: UInt64) -> String { let s = String(v); return String(repeating: "0", count: max(0, 3 - s.count)) + s }
func msStr(_ ns: UInt64) -> String { let us = ns / 1000; return "\(us / 1000).\(pad3(us % 1000))" }
func ratioStr(_ v: UInt64, _ best: UInt64) -> String {
    if best == 0 || best == UInt64.max || v == UInt64.max || v == 0 { return "-" }
    let scaled = UInt64((Double(v) / Double(best) * 100).rounded())
    return "\(scaled / 100).\(pad2(scaled % 100))x"
}
func col(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }

// Human-readable breakdown of everything excluded from the samples.
func failDesc(_ a: Acc) -> String? {
    var parts = [String]()
    if a.timeouts > 0 { parts.append("\(a.timeouts) timeout") }
    if a.netErrs > 0 { parts.append("\(a.netErrs) net-err") }
    if a.closes > 0 { parts.append("\(a.closes) closed") }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}
func rcodeDesc(_ a: Acc) -> String? {
    var parts = [String]()
    for rc in 0..<16 where a.rcodeCounts[rc] > 0 { parts.append("\(a.rcodeCounts[rc]) \(rcodeName(rc))") }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}
func anomalyDesc(_ a: Acc) -> String? {
    let parts = [failDesc(a), rcodeDesc(a)].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}

func printRow(_ name: String, _ a: Acc, _ vs: String, _ nameW: Int) {
    var s = a.samples; s.sort()
    let (mean, std) = meanStd(s)
    print(col(name, nameW) + col("\(s.count)", 7) + col("\(a.fails)", 6) + col("\(a.rcodeErrs)", 6)
        + col(msStr(percentile(s, 0)), 10) + col(msStr(percentile(s, 50)), 10)
        + col(msStr(percentile(s, 90)), 10) + col(msStr(percentile(s, 99)), 10)
        + col(msStr(percentile(s, 99.9)), 10) + col(msStr(percentile(s, 100)), 10)
        + col(msStr(mean), 10) + col(msStr(std), 10) + col(vs, 9))
}
func printTable(_ title: String, _ accs: [Acc], _ names: [String], _ ord: [Int], _ refMetric: SortKey) {
    let best = bestValue(accs, refMetric)
    let nameW = max(16, (names.map { $0.count }.max() ?? 0) + 2)
    let header = col("resolver", nameW) + col("n", 7) + col("fail", 6) + col("err", 6) + col("min", 10) + col("p50", 10)
        + col("p90", 10) + col("p99", 10) + col("p99.9", 10) + col("max", 10) + col("mean", 10)
        + col("std", 10) + col("vs", 9)
    print(title + "\n" + header)
    for i in ord { printRow(names[i], accs[i], ratioStr(sortValue(accs[i], refMetric), best), nameW) }
}

// ───────────────────────────── HTML report ─────────────────────────────
func nowString() -> String {
    var t = time(nil); var tmv = tm()
    localtime_r(&t, &tmv)
    var buf = [CChar](repeating: 0, count: 32)
    let n = strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tmv)
    return n > 0 ? String(cString: buf) : ""
}
func he(_ s: String) -> String {
    var o = ""
    for c in s { switch c { case "&": o += "&amp;"; case "<": o += "&lt;"; case ">": o += "&gt;"; default: o.append(c) } }
    return o
}
func n1(_ v: Double) -> String { let r = (v * 10).rounded() / 10; return "\(r)" }

// Fixed-point label without Foundation: fixed(12.5, 1) = "12.5" (v >= 0).
func fixed(_ v: Double, _ decimals: Int) -> String {
    var scale = 1; for _ in 0..<decimals { scale *= 10 }
    let n = Int((v * Double(scale)).rounded())
    if decimals == 0 { return "\(n)" }
    let frac = "\(n % scale)"
    return "\(n / scale)." + String(repeating: "0", count: decimals - frac.count) + frac
}

// Chart colours: eight hues in a fixed order, checked as a set on the white
// chart surface (lightness, chroma, contrast >= 3:1, and neighbours that stay
// apart under protanopia and deuteranopia). A colour is a server, not a rank:
// it is the same in the HIT and the MISS chart, and entries whose names differ
// only by a family or transport suffix share it - the line style tells them
// apart. Eight is the limit of what stays distinguishable: more servers go to
// a second chart on the same axes rather than to a ninth hue.
let palette = ["#2563eb", "#059669", "#9333ea", "#d97706", "#db2777", "#65a30d", "#0891b2", "#dc2626"]
let seriesSuffixes = ["-v6", "-v4", "-tcp", "-udp"]

// "ns1-v6-tcp" -> "ns1".
func seriesStem(_ name: String) -> String {
    var s = Substring(name.lowercased())
    var cut = true
    while cut {
        cut = false
        for suf in seriesSuffixes where s.count > suf.count && s.hasSuffix(suf) { s = s.dropLast(suf.count); cut = true }
    }
    return String(s)
}

// Colour slot of every entry, in configuration order. Two entries of one
// server that would also share a line style (same family, same transport)
// get separate slots.
func seriesSlots(_ names: [String], _ isV6: [Bool]) -> (slot: [Int], count: Int) {
    var slotOf: [String: Int] = [:]
    var taken = Set<Int>()
    var slot = [Int](repeating: 0, count: names.count)
    for i in names.indices {
        let variant = (isStream[i] ? 2 : 0) + (isV6[i] ? 1 : 0)
        var key = seriesStem(names[i])
        while let s = slotOf[key], taken.contains(s * 4 + variant) { key += "+" }
        let s = slotOf[key] ?? slotOf.count
        slotOf[key] = s; taken.insert(s * 4 + variant); slot[i] = s
    }
    return (slot, slotOf.count)
}

// v4 solid, v6 dashed. In a panel that mixes transports, TCP is dotted and v6
// over TCP dash-dot; a panel that is all TCP keeps the plain styles.
func seriesDash(_ v6: Bool, _ dotted: Bool) -> String {
    let d = dotted ? (v6 ? "7 3 2 3" : "2 3") : (v6 ? "5 3" : "")
    return d.isEmpty ? "" : " stroke-dasharray=\"\(d)\""
}

// X ticks of the log axis: the 1-2-5 series when at least four of its marks
// fall inside the range, otherwise evenly spaced round values - a MISS panel
// spanning 11 to 27 ms holds a single mark of the series ("20").
func cdfTicks(_ lo: Double, _ hi: Double) -> [(v: Double, label: String)] {
    func p10(_ e: Int) -> Double { var x = 1.0; for _ in 0..<abs(e) { x *= 10 }; return e < 0 ? 1 / x : x }
    var t: [(v: Double, label: String)] = []
    var e = Int(log10(lo).rounded(.down)) - 1
    while p10(e) <= hi {
        for m in [1.0, 2.0, 5.0] {
            let v = e < 0 ? m / p10(-e) : m * p10(e)
            if v >= lo && v <= hi { t.append((v, fixed(v, max(0, -e)))) }
        }
        e += 1
    }
    if t.count >= 4 { return t }
    t.removeAll()
    let raw = (hi - lo) / 6                                 // about six intervals
    e = Int(log10(raw).rounded(.down))
    let f = raw / p10(e)
    let step = p10(e) * (f < 1.5 ? 1 : (f < 3.5 ? 2 : (f < 7.5 ? 5 : 10)))
    if f >= 7.5 { e += 1 }
    var k = (lo / step).rounded(.up)
    while k * step <= hi + step * 1e-9 { t.append((k * step, fixed(k * step, max(0, -e)))); k += 1 }
    return t
}

func htmlTable(_ title: String, _ accs: [Acc], _ names: [String], _ ord: [Int], _ refMetric: SortKey) -> String {
    let best = bestValue(accs, refMetric)
    var maxP50 = 1.0
    for a in accs where !a.samples.isEmpty { var s = a.samples; s.sort(); let v = Double(percentile(s, 50)); if v > maxP50 { maxP50 = v } }
    let head = "<tr><th class=\"name\">resolver</th><th>n</th><th>fail</th><th>err</th><th>min</th><th>p50</th>"
        + "<th>p90</th><th>p99</th><th>p99.9</th><th>max</th><th>mean</th><th>std</th><th>vs</th>"
        + "<th class=\"bar\">p50</th></tr>"
    var rows = ""
    for i in ord {
        let a = accs[i]; var s = a.samples; s.sort()
        let (mean, std) = meanStd(s)
        let p50 = a.samples.isEmpty ? 0 : percentile(s, 50)
        let w = a.samples.isEmpty ? 0 : Int((Double(p50) / maxP50 * 100.0).rounded())
        let cls = a.samples.isEmpty ? " class=\"dead\"" : ""
        let ft = failDesc(a).map { " title=\"\(he($0))\"" } ?? ""
        let et = rcodeDesc(a).map { " title=\"\(he($0))\"" } ?? ""
        rows += "<tr\(cls)><td class=\"name\">\(he(names[i]))</td><td>\(a.samples.count)</td><td\(ft)>\(a.fails)</td><td\(et)>\(a.rcodeErrs)</td>"
            + "<td>\(msStr(percentile(s, 0)))</td><td>\(msStr(p50))</td><td>\(msStr(percentile(s, 90)))</td>"
            + "<td>\(msStr(percentile(s, 99)))</td><td>\(msStr(percentile(s, 99.9)))</td><td>\(msStr(percentile(s, 100)))</td>"
            + "<td>\(msStr(mean))</td><td>\(msStr(std))</td><td>\(ratioStr(sortValue(a, refMetric), best))</td>"
            + "<td class=\"bar\"><div class=\"track\"><div class=\"fill\" style=\"width:\(w)%\"></div></div></td></tr>"
    }
    return "<h2>\(title)</h2><table><thead>\(head)</thead><tbody>\(rows)</tbody></table>"
}

func log10safe(_ x: Double) -> Double { x > 0 ? log10(x) : 0 }

// Overlaid CDFs (one line per resolver), log-X. Colour = server, line style =
// family and transport; at most palette.count servers per chart.
func cdfChart(_ accs: [Acc], _ names: [String], _ isV6: [Bool], _ ord: [Int]) -> String {
    var xminNs = UInt64.max, xmaxNs: UInt64 = 0
    for a in accs where !a.samples.isEmpty {
        var s = a.samples; s.sort()
        let lo = percentile(s, 0), hi = percentile(s, 99)      // clip tail at p99 for readability
        if lo < xminNs { xminNs = lo }; if hi > xmaxNs { xmaxNs = hi }
    }
    if xmaxNs == 0 { return "<p class=\"foot\">(no data)</p>" }
    let xminMs = max(0.05, Double(xminNs) / 1_000_000.0)
    let xmaxMs = max(xminMs * 1.5, Double(xmaxNs) / 1_000_000.0)
    let logmin = log10safe(xminMs), logmax = log10safe(xmaxMs)
    let W = 760.0, H = 320.0, L = 44.0, Rr = 14.0, T = 14.0, Bb = 34.0
    let plotW = W - L - Rr, plotH = H - T - Bb
    func xpix(_ ms: Double) -> Double { let c = min(max(ms, xminMs), xmaxMs); return L + (log10safe(c) - logmin) / (logmax - logmin) * plotW }
    func ypix(_ pct: Double) -> Double { T + (1.0 - pct / 100.0) * plotH }

    // Axes and grid, shared by every chart of the panel.
    var axes = "<svg viewBox=\"0 0 \(Int(W)) \(Int(H))\" class=\"chart\" role=\"img\">"
    for g in stride(from: 0.0, through: 100.0, by: 25.0) {
        let y = ypix(g)
        axes += "<line x1=\"\(L)\" y1=\"\(n1(y))\" x2=\"\(L + plotW)\" y2=\"\(n1(y))\" class=\"grid\"/>"
        axes += "<text x=\"\(L - 5)\" y=\"\(n1(y + 3))\" class=\"ylab\">\(Int(g))%</text>"
    }
    var lastX = -100.0
    for tk in cdfTicks(xminMs, xmaxMs) {
        let x = xpix(tk.v)
        if x - lastX < 26 { continue }                      // two labels must not touch
        lastX = x
        axes += "<line x1=\"\(n1(x))\" y1=\"\(T)\" x2=\"\(n1(x))\" y2=\"\(n1(T + plotH))\" class=\"grid\"/>"
        axes += "<text x=\"\(n1(x))\" y=\"\(n1(T + plotH + 13))\" class=\"xlab\">\(tk.label)</text>"
    }
    axes += "<text x=\"\(n1(L + plotW / 2))\" y=\"\(Int(H) - 2)\" class=\"axt\">latency (ms, log scale)</text>"

    let (slot, slots) = seriesSlots(names, isV6)
    let charts = (slots + palette.count - 1) / palette.count
    let mixed = isStream.contains(true) && isStream.contains(false)
    var out = ""
    for c in 0..<charts {
        var svg = axes
        var legend = "<div class=\"legend\">"
        var drawn = 0
        for i in ord where slot[i] / palette.count == c {
            let a = accs[i]; if a.samples.isEmpty { continue }
            var s = a.samples; s.sort()
            let color = palette[slot[i] % palette.count]
            let dash = seriesDash(isV6[i], mixed && isStream[i])
            var pts = ""; var p = 0.0
            while p <= 100.0 { pts += "\(n1(xpix(Double(percentile(s, p)) / 1_000_000.0))),\(n1(ypix(p))) "; p += 2.0 }
            // The curve, then a wide transparent copy: a hover target that names it.
            svg += "<g><title>\(he(names[i])) - p50 \(msStr(percentile(s, 50))) ms, p99 \(msStr(percentile(s, 99))) ms</title>"
                + "<polyline points=\"\(pts)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"1.6\"\(dash)/>"
                + "<polyline points=\"\(pts)\" fill=\"none\" stroke=\"#000\" stroke-opacity=\"0\" stroke-width=\"9\"/></g>"
            legend += "<span class=\"lg\"><svg width=\"24\" height=\"8\"><line x1=\"1\" y1=\"4\" x2=\"23\" y2=\"4\" stroke=\"\(color)\" stroke-width=\"2\"\(dash)/></svg>\(he(names[i]))</span>"
            drawn += 1
        }
        if drawn == 0 { continue }
        if charts > 1 {
            out += "<p class=\"part\">servers \(c * palette.count + 1) to \(min(slots, (c + 1) * palette.count)) of \(slots), in configuration order</p>"
        }
        out += svg + "</svg>" + legend + "</div>"
    }
    return out
}

func writeHTML(_ path: String, _ cfg: Config, _ names: [String], _ isV6: [Bool],
               _ hit: [Acc], _ miss: [Acc], _ hOrd: [Int], _ mOrd: [Int],
               _ refMetric: SortKey, _ clkCost: UInt64, _ clkRes: UInt64) {
    let css = """
    body{font:14px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;margin:2rem;color:#1a1a2e;background:#fafafc}
    h1{font-size:1.4rem;margin:0 0 .2rem}.meta{color:#666;font-size:.8rem;margin:0 0 1.2rem}
    h2{font-size:1.05rem;margin:1.6rem 0 .5rem}
    table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
    th,td{padding:.25rem .55rem;text-align:right;border-bottom:1px solid #eee;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
    th{font-size:.7rem;color:#888;text-transform:uppercase;letter-spacing:.03em;font-family:inherit}
    td.name,th.name{text-align:left;font-weight:600;font-family:inherit}
    td.bar,th.bar{width:18%}
    .track{background:#ececf2;border-radius:3px;height:12px;overflow:hidden}.fill{background:#4f46e5;height:100%}
    tr.dead{opacity:.45}tr.dead .fill{background:#cc2222}
    .chart{width:100%;height:auto;margin:.3rem 0 .1rem;background:#fff;border:1px solid #eee;border-radius:6px}
    .grid{stroke:#eee;stroke-width:1}.ylab{fill:#999;font-size:10px;text-anchor:end}
    .xlab{fill:#999;font-size:10px;text-anchor:middle}.axt{fill:#888;font-size:11px;text-anchor:middle}
    .legend{display:flex;flex-wrap:wrap;gap:.3rem 1rem;font-size:.74rem;margin:.1rem 0 1rem}
    .legend svg{vertical-align:middle;margin-right:5px}
    .part{color:#888;font-size:.75rem;margin:.9rem 0 0}
    .foot{color:#888;font-size:.75rem;margin-top:1.4rem}
    td.anom,th.anom{text-align:left}
    """
    var d = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    d += "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>dnsbench results</title>"
    d += "<style>\(css)</style></head><body><h1>dnsbench results</h1>"
    d += "<p class=\"meta\">dnsbench v\(VERSION) &middot; \(nowString()) &middot; \(names.count) resolvers &middot; \(cfg.rounds) rounds/mode &middot; "
    d += "default qtype \(qtypeName(cfg.qtype)) &middot; timeout \(cfg.timeoutMs) ms\(cfg.gapMs > 0 ? " &middot; gap \(cfg.gapMs) ms" : "")\(cfg.edns ? " &middot; EDNS0" : "")\(ktsActive ? " &middot; kernel RX ts" : "")\(tcpFlag ? " &middot; TCP" : "")\(reconnectFlag && isStream.contains(true) ? " &middot; reconnect per query" : "")\(orderMark())\(familyOnly == AF_INET ? " &middot; IPv4 only" : (familyOnly == AF_INET6 ? " &middot; IPv6 only" : "")) &middot; vs/sort on \(metricName(refMetric)) &middot; "
    d += "clock ~\(clkCost) ns/call, res \(clkRes) ns &middot; MISS &lt;rand&gt;.\(he(cfg.missBase))</p>"
    if cfg.mode != .miss {
        d += htmlTable("cache-HIT (ms)", hit, names, hOrd, refMetric)
        d += "<h2>cache-HIT distribution (CDF)</h2>" + cdfChart(hit, names, isV6, hOrd)
    }
    if cfg.mode != .hit {
        d += htmlTable("cache-MISS (ms)", miss, names, mOrd, refMetric)
        d += "<h2>cache-MISS distribution (CDF)</h2>" + cdfChart(miss, names, isV6, mOrd)
    }
    // Anomalies: per-resolver breakdown of everything excluded from the samples.
    var anomRows = ""
    for i in names.indices {
        let hd = cfg.mode != .miss ? anomalyDesc(hit[i]) : nil
        let md = cfg.mode != .hit ? anomalyDesc(miss[i]) : nil
        if hd == nil && md == nil { continue }
        anomRows += "<tr><td class=\"name\">\(he(names[i]))</td><td class=\"anom\">\(he(hd ?? "-"))</td><td class=\"anom\">\(he(md ?? "-"))</td></tr>"
    }
    d += "<h2>Anomalies</h2>"
    if anomRows.isEmpty {
        d += "<p class=\"foot\">None: every reply was NOERROR/NXDOMAIN, no timeouts, no network errors.</p>"
    } else {
        d += "<table><thead><tr><th class=\"name\">resolver</th><th class=\"anom\">cache-HIT</th><th class=\"anom\">cache-MISS</th></tr></thead><tbody>\(anomRows)</tbody></table>"
        if hit.contains(where: { $0.rcodeCounts[5] > 0 }) || miss.contains(where: { $0.rcodeCounts[5] > 0 }) {
            d += "<p class=\"foot\">REFUSED from a Pi-hole is typically FTL rate limiting (default 1000 q / 60 s per client) - consider --gap.</p>"
        }
    }
    // What the servers did to the TCP connections - nothing here is excluded.
    var reopened = [String](), repeated = [String]()
    for i in names.indices {
        if reconns[i] > 0 { reopened.append("\(he(names[i])) \(reconns[i])") }
        let rep = (cfg.mode != .miss ? hit[i].retried : 0) + (cfg.mode != .hit ? miss[i].retried : 0)
        if rep > 0 { repeated.append("\(he(names[i])) \(rep)") }
    }
    if !reopened.isEmpty {
        d += "<p class=\"foot\">TCP connections closed by the server while idle, reopened before t0 (outside the samples): \(reopened.joined(separator: ", ")).</p>"
    }
    if !repeated.isEmpty {
        d += "<p class=\"foot\">TCP connections closed by the server mid-query, query repeated on a new connection (those samples include the lost attempt and the handshake): \(repeated.joined(separator: ", ")).</p>"
    }
    d += "<p class=\"foot\">Values in ms. CDF: a curve further left = faster; X is log-scaled and clipped at p99. "
    d += "One colour per server - entries whose names differ only by a -v6 or -tcp suffix share it; v4 solid, v6 dashed, and where a panel mixes transports TCP dotted (v6 over TCP dash-dot). Hover a curve for its name. "
    d += "Bars/vs scale to the fastest on \(metricName(refMetric)). Red rows were unreachable. "
    d += "fail counts timeouts, network errors (ICMP unreachable, send failures) and TCP queries whose connection the server closed twice (a first close is retried); err counts replies whose RCODE is neither NOERROR nor NXDOMAIN (SERVFAIL, REFUSED, ...). Both are excluded from the latency samples - hover a fail/err cell for the per-kind breakdown.</p></body></html>"

    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
    if fd < 0 { fputs("dnsbench: cannot write HTML: \(path)\n", stderr); return }
    defer { close(fd) }
    let bytes = Array(d.utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    fputs("HTML written: \(path)\n", stderr)
}

// ───────────────────── Machine-readable output (JSON, CSV) ─────────────────────
// The console tables, for scripts and dashboards. JSON carries the whole run
// (options, clock, per-resolver statistics, anomaly breakdown and, with
// --samples, every raw sample in measurement order) in integer nanoseconds
// under a versioned schema. CSV carries the two summary tables formatted
// exactly like the console (ms, same columns), one row per resolver and mode.
// Hand-written serializers: no Foundation, so no JSONEncoder.
var machineFd: Int32 = -1           // the real stdout, when "-" hands it to --json/--csv

func modeName(_ m: Mode) -> String { m == .both ? "both" : (m == .hit ? "hit" : "miss") }
func orderName() -> String {
    switch visitOrder {
    case .shuffle: return "shuffle"
    case .conf: return "conf"
    case .v4First: return "v4-first"
    case .v6First: return "v6-first"
    }
}

// RFC 3339, UTC: machine output must not depend on the probe's timezone.
func utcStamp() -> String {
    var t = time(nil); var tmv = tm()
    gmtime_r(&t, &tmv)
    var buf = [CChar](repeating: 0, count: 32)
    let n = strftime(&buf, buf.count, "%Y-%m-%dT%H:%M:%SZ", &tmv)
    return n > 0 ? String(cString: buf) : ""
}

func writeOutput(_ path: String, _ text: String, _ what: String) {
    let toStdout = path == "-"
    let fd = toStdout ? machineFd : open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
    if fd < 0 { fputs("dnsbench: cannot write \(what): \(path)\n", stderr); return }
    defer { if !toStdout { close(fd) } }
    let bytes = Array(text.utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, $0.count - off) }
        if n < 0 {
            if errno == EINTR { continue }
            fputs("dnsbench: write error on \(what): \(path)\n", stderr); return
        }
        off += n
    }
    if !toStdout { fputs("\(what) written: \(path)\n", stderr) }
}

func jsonString(_ s: String) -> String {
    var o = "\""
    for u in s.unicodeScalars {
        switch u.value {
        case 0x22: o += "\\\""
        case 0x5C: o += "\\\\"
        case 0x0A: o += "\\n"
        case 0x0D: o += "\\r"
        case 0x09: o += "\\t"
        case 0..<0x20:
            let h = String(u.value, radix: 16)
            o += "\\u" + String(repeating: "0", count: 4 - h.count) + h
        default: o.unicodeScalars.append(u)
        }
    }
    return o + "\""
}

// One phase of one resolver. Statistics are null when no sample was collected
// (the console prints 0.000 there); `vs` is the console ratio, as a number.
func jsonPhase(_ a: Acc, _ best: UInt64, _ refMetric: SortKey, _ withSamples: Bool) -> String {
    var s = a.samples; s.sort()
    let (mean, std) = meanStd(s)
    func v(_ x: UInt64) -> String { s.isEmpty ? "null" : String(x) }
    var rcodes = [String]()
    for rc in 0..<16 where a.rcodeCounts[rc] > 0 { rcodes.append("\(jsonString(rcodeName(rc))): \(a.rcodeCounts[rc])") }
    let ratio = ratioStr(sortValue(a, refMetric), best)
    var o = "{\"n\": \(s.count), \"fail\": \(a.fails), \"err\": \(a.rcodeErrs), \"timeouts\": \(a.timeouts), "
    o += "\"net_errors\": \(a.netErrs), \"closed\": \(a.closes), \"retried\": \(a.retried), "
    o += "\"rcodes\": {\(rcodes.joined(separator: ", "))}, "
    o += "\"min\": \(v(percentile(s, 0))), \"p50\": \(v(percentile(s, 50))), \"p90\": \(v(percentile(s, 90))), "
    o += "\"p99\": \(v(percentile(s, 99))), \"p999\": \(v(percentile(s, 99.9))), \"max\": \(v(percentile(s, 100))), "
    o += "\"mean\": \(v(mean)), \"std\": \(v(std)), \"vs\": \(ratio == "-" ? "null" : String(ratio.dropLast()))"
    if withSamples { o += ", \"samples\": [" + a.samples.map { String($0) }.joined(separator: ",") + "]" }
    return o + "}"
}

func writeJSON(_ path: String, _ cfg: Config, _ names: [String], _ addrs: [String], _ isV6: [Bool],
               _ hit: [Acc], _ miss: [Acc], _ refMetric: SortKey, _ clkCost: UInt64, _ clkRes: UInt64,
               _ started: String, _ elapsedNs: UInt64) {
    let doHit = cfg.mode != .miss, doMiss = cfg.mode != .hit
    let hBest = bestValue(hit, refMetric), mBest = bestValue(miss, refMetric)
#if canImport(Darwin)
    let pin = "null"                                   // --pin is ignored on Darwin
#else
    let pin = pinCore.map { String($0) } ?? "null"
#endif
    var d = "{\n  \"schema\": 1,\n  \"tool\": \"dnsbench\",\n  \"version\": \(jsonString(VERSION)),\n"
    d += "  \"label\": \(runLabel.map(jsonString) ?? "null"),\n"
    d += "  \"started\": \(jsonString(started)),\n  \"elapsed_ms\": \(elapsedNs / 1_000_000),\n  \"unit\": \"ns\",\n"
    d += "  \"options\": {\"config\": \(jsonString(configPath)), \"rounds\": \(cfg.rounds), \"mode\": \"\(modeName(cfg.mode))\", "
    d += "\"parallel\": \(cfg.parallel), \"timeout_ms\": \(cfg.timeoutMs), \"gap_ms\": \(cfg.gapMs), \"edns\": \(cfg.edns), "
    d += "\"qtype\": \(jsonString(qtypeName(cfg.qtype))), \"order\": \"\(orderName())\", "
    d += "\"family\": \"\(familyOnly == AF_INET ? "v4" : (familyOnly == AF_INET6 ? "v6" : "any"))\", "
    d += "\"spin\": \(spinFlag), \"rt\": \(rtFlag), \"kts\": \(ktsActive), \"pin\": \(pin), "
    d += "\"tcp\": \(tcpFlag), \"reconnect\": \(reconnectFlag), \"vs_metric\": \"\(metricName(refMetric))\"},\n"
    d += "  \"hit_domains\": [" + cfg.hitDomains.map {
        "{\"name\": \(jsonString($0.name)), \"qtype\": \(jsonString(qtypeName($0.qtype ?? cfg.qtype)))}"
    }.joined(separator: ", ") + "],\n"
    d += "  \"miss_base\": \(jsonString(cfg.missBase)),\n"
    d += "  \"clock\": {\"cost_ns\": \(clkCost), \"resolution_ns\": \(clkRes)},\n  \"resolvers\": [\n"
    for i in names.indices {
        d += "    {\"name\": \(jsonString(names[i])), \"address\": \(jsonString(addrs[i])), \"family\": \"\(isV6[i] ? "v6" : "v4")\", "
        d += "\"transport\": \"\(isStream[i] ? "tcp" : "udp")\", \"port\": \(ports[i])"
        if isStream[i] { d += ", \"reconnects\": \(reconns[i])" }
        if doHit { d += ",\n     \"hit\": " + jsonPhase(hit[i], hBest, refMetric, samplesFlag) }
        if doMiss { d += ",\n     \"miss\": " + jsonPhase(miss[i], mBest, refMetric, samplesFlag) }
        d += i == names.count - 1 ? "}\n" : "},\n"
    }
    d += "  ]\n}\n"
    writeOutput(path, d, "JSON")
}

// RFC 4180 quoting, only where a field needs it.
func csvField(_ s: String) -> String {
    if !s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) { return s }
    var o = "\""
    for u in s.unicodeScalars { if u == "\"" { o += "\"\"" } else { o.unicodeScalars.append(u) } }
    return o + "\""
}

func csvRows(_ run: String, _ mode: String, _ accs: [Acc], _ names: [String], _ ord: [Int], _ refMetric: SortKey) -> String {
    let best = bestValue(accs, refMetric)
    var o = ""
    for i in ord {
        let a = accs[i]; var s = a.samples; s.sort()
        let (mean, std) = meanStd(s)
        let f = [run, mode, csvField(names[i]), "\(s.count)", "\(a.fails)", "\(a.rcodeErrs)",
                 msStr(percentile(s, 0)), msStr(percentile(s, 50)), msStr(percentile(s, 90)),
                 msStr(percentile(s, 99)), msStr(percentile(s, 99.9)), msStr(percentile(s, 100)),
                 msStr(mean), msStr(std), ratioStr(sortValue(a, refMetric), best)]
        o += f.joined(separator: ",") + "\n"
    }
    return o
}

// Rows follow the console order (--sort). `run` is the --label, or the run's
// start time when none was given: every row says which run it belongs to, so
// the files of a campaign concatenate into one table.
func writeCSV(_ path: String, _ cfg: Config, _ names: [String], _ hit: [Acc], _ miss: [Acc],
              _ hOrd: [Int], _ mOrd: [Int], _ refMetric: SortKey, _ started: String) {
    let run = csvField(runLabel ?? started)
    var d = "run,mode,resolver,n,fail,err,min,p50,p90,p99,p999,max,mean,std,vs\n"
    if cfg.mode != .miss { d += csvRows(run, "HIT", hit, names, hOrd, refMetric) }
    if cfg.mode != .hit { d += csvRows(run, "MISS", miss, names, mOrd, refMetric) }
    writeOutput(path, d, "CSV")
}

// ───────────────────────────── CLI ─────────────────────────────
func usage() {
    fputs("""
    usage: dnsbench [-c FILE] [--rounds N] [--qtype A|AAAA|HTTPS|N] [--mode hit|miss|both]
                    [--timeout-ms N] [--gap MS] [--spin] [--edns] [--rt] [--kts] [--pin N]
                    [--tcp] [--reconnect] [--sort KEY] [--html FILE] [--json FILE]
                    [--csv FILE] [--samples] [--label TEXT] [-v] [-h] [--version]
      -c, --config FILE      configuration file (default: ./dnsbench.conf)
          --rounds N         override the round count (quick smoke test)
          --qtype T          override the global query type (A, AAAA, HTTPS, TXT or numeric)
          --mode hit|miss|both   which phase(s) to run (default: both)
          --timeout-ms N     override the receive timeout, in milliseconds
          --gap MS           pacing: sleep MS ms between queries (sequential) or
                             phases (parallel); keeps resolver-side rate limits quiet
          --parallel         fan out one query per resolver at once (poll-based)
          --no-parallel      force sequential closed-loop (overrides config)
          --spin             busy-wait receive (sequential only): removes the scheduler
                             wake-up from the measurement, costs one core at 100%
          --edns             add an EDNS0 OPT record (bufsize 1232), like modern stubs
          --rt               best-effort latency hints (Darwin: QoS + time-constraint
                             thread; Linux: SCHED_FIFO + mlockall + SO_BUSY_POLL)
          --kts              kernel RX timestamps: t1 is stamped by the kernel at
                             packet arrival (removes wake-up and batch bias)
          --pin N            Linux: pin the process to CPU N (sched_setaffinity)
          --order MODE       visit/send order: shuffle (default, fair mix of cold
                             and warm), conf (file order: the first entry of a
                             same-server pair absorbs the wake-up - cold probe),
                             v4-first or v6-first (family blocks, each family
                             cooled ~half a round - symmetric, deterministic)
          --fixed-order      alias of --order conf (v2.2 behaviour)
      -4, -6                 restrict the panel to IPv4-only / IPv6-only without
                             editing the conf (mutually exclusive)
          --tcp              query every resolver over TCP without editing the conf
                             (one entry at a time: tcp://ADDR[:PORT] in [resolvers])
          --reconnect        TCP entries: a new connection for every query, timed
                             from connect() - handshake + query. Default: one
                             persistent connection per resolver, reopened outside
                             the timed window when the server closes it while
                             idle. Sequential. Either way, a query whose connection
                             is closed mid-flight is repeated once, clock running.
          --sort KEY         sort + vs-ratio on min|p50|p90|p99|p999|max|mean
          --html FILE        also write a standalone HTML report (tables + CDF charts)
          --json FILE        also write the whole run as JSON (versioned schema,
                             integer nanoseconds); "-" writes it to stdout and
                             moves the console report to stderr
          --csv FILE         also write the summary tables as CSV (console columns
                             and units, one row per resolver and mode); "-" as above
          --samples          with --json: include every raw sample, in measurement order
          --label TEXT       name this run: JSON `label`, CSV `run` column (default:
                             the start time)
      -v, --verbose          echo parsed resolver addresses at startup
          --version          print version and exit
      -h, --help             show this help and exit
    A bare argument is also accepted as the config file path.

    """, stderr)
}

var configPath = "dnsbench.conf"
var roundsOverride: Int? = nil
var qtypeOverride: UInt16? = nil
var modeOverride: Mode? = nil
var parallelOverride: Bool? = nil
var timeoutMsOverride: Int? = nil
var gapOverride: Int? = nil
var ednsOverride: Bool? = nil
var spinFlag = false
var rtFlag = false
var ktsFlag = false
var pinCore: Int? = nil
var tcpFlag = false
var reconnectFlag = false
var verboseFlag = false
var sortKey: SortKey? = nil
var htmlPath: String? = nil
var jsonPath: String? = nil
var csvPath: String? = nil
var samplesFlag = false
var runLabel: String? = nil
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "-c", "--config":
        guard let v = it.next() else { fputs("dnsbench: \(a) requires a value\n", stderr); exit(2) }
        configPath = v
    case "--rounds":
        guard let v = it.next(), let n = Int(v) else { fputs("dnsbench: --rounds requires an integer\n", stderr); exit(2) }
        roundsOverride = n
    case "--qtype":
        guard let v = it.next(), let q = parseQType(v) else { fputs("dnsbench: --qtype requires A, AAAA, HTTPS, TXT or a numeric type\n", stderr); exit(2) }
        qtypeOverride = q
    case "--mode":
        guard let v = it.next(), let m = parseMode(v) else { fputs("dnsbench: --mode requires hit|miss|both\n", stderr); exit(2) }
        modeOverride = m
    case "--timeout-ms":
        guard let v = it.next(), let n = Int(v), n > 0 else { fputs("dnsbench: --timeout-ms requires a positive integer\n", stderr); exit(2) }
        timeoutMsOverride = n
    case "--gap":
        guard let v = it.next(), let n = Int(v), n >= 0 else { fputs("dnsbench: --gap requires a non-negative integer (ms)\n", stderr); exit(2) }
        gapOverride = n
    case "--parallel":
        parallelOverride = true
    case "--no-parallel":
        parallelOverride = false
    case "--spin":
        spinFlag = true
    case "--edns":
        ednsOverride = true
    case "--rt":
        rtFlag = true
    case "--kts":
        ktsFlag = true
    case "--pin":
        guard let v = it.next(), let n = Int(v), n >= 0 else { fputs("dnsbench: --pin requires a CPU index\n", stderr); exit(2) }
        pinCore = n
    case "--fixed-order":
        visitOrder = .conf
    case "--order":
        guard let v = it.next() else { fputs("dnsbench: --order requires shuffle|conf|v4-first|v6-first\n", stderr); exit(2) }
        switch v {
        case "shuffle":  visitOrder = .shuffle
        case "conf":     visitOrder = .conf
        case "v4-first": visitOrder = .v4First
        case "v6-first": visitOrder = .v6First
        default: fputs("dnsbench: --order requires shuffle|conf|v4-first|v6-first\n", stderr); exit(2)
        }
    case "-4":
        if familyOnly == AF_INET6 { fputs("dnsbench: -4 and -6 are mutually exclusive\n", stderr); exit(2) }
        familyOnly = AF_INET
    case "-6":
        if familyOnly == AF_INET { fputs("dnsbench: -4 and -6 are mutually exclusive\n", stderr); exit(2) }
        familyOnly = AF_INET6
    case "--tcp":
        tcpFlag = true
    case "--reconnect":
        reconnectFlag = true
    case "-v", "--verbose":
        verboseFlag = true
    case "--sort":
        guard let v = it.next(), let k = parseSort(v) else { fputs("dnsbench: --sort requires min|p50|p90|p99|p999|max|mean\n", stderr); exit(2) }
        sortKey = k
    case "--html":
        guard let v = it.next() else { fputs("dnsbench: --html requires a file path\n", stderr); exit(2) }
        htmlPath = v
    case "--json":
        guard let v = it.next() else { fputs("dnsbench: --json requires a file path (or -)\n", stderr); exit(2) }
        jsonPath = v
    case "--csv":
        guard let v = it.next() else { fputs("dnsbench: --csv requires a file path (or -)\n", stderr); exit(2) }
        csvPath = v
    case "--samples":
        samplesFlag = true
    case "--label":
        guard let v = it.next() else { fputs("dnsbench: --label requires a text\n", stderr); exit(2) }
        runLabel = v
    case "--version":
        print("dnsbench \(VERSION)"); exit(0)
    case "-h", "--help":
        usage(); exit(0)
    default:
        if a.first == "-" { fputs("dnsbench: unknown option \(a)\n", stderr); usage(); exit(2) }
        configPath = a
    }
}

// ───────────────────────────── Main ─────────────────────────────
// "-" hands stdout to the machine-readable output: the console report moves to
// stderr, so that `dnsbench --json - | jq .` stays a clean pipe.
if jsonPath == "-" && csvPath == "-" {
    fputs("dnsbench: only one of --json and --csv can write to stdout\n", stderr); exit(2)
}
if jsonPath == "-" || csvPath == "-" {
    machineFd = dup(1)
    dup2(2, 1)
}
if samplesFlag && jsonPath == nil { fputs("dnsbench: --samples only applies to --json, ignored\n", stderr) }

guard var cfg = loadConfig(configPath) else { fputs("dnsbench: cannot read config: \(configPath)\n", stderr); exit(1) }
if let r = roundsOverride { cfg.rounds = r }
if let q = qtypeOverride { cfg.qtype = q }
if let m = modeOverride { cfg.mode = m }
if let p = parallelOverride { cfg.parallel = p }
if let t = timeoutMsOverride { cfg.timeoutMs = t }
if let g = gapOverride { cfg.gapMs = g }
if let e = ednsOverride { cfg.edns = e }
if cfg.resolvers.isEmpty { fputs("dnsbench: no resolvers in \(configPath) ([resolvers] section).\n", stderr); exit(1) }
if spinFlag && cfg.parallel {
    fputs("dnsbench: --spin implies sequential mode, disabling parallel\n", stderr)
    cfg.parallel = false
}
// Cold streams connect inside the timed window: that takes the sequential loop.
let wantsStreams = tcpFlag || cfg.resolvers.contains { parseTarget($0.ip)?.transport == .tcp }
if reconnectFlag && !wantsStreams {
    fputs("dnsbench: --reconnect only applies to tcp entries (none in this panel), ignored\n", stderr)
}
if reconnectFlag && wantsStreams && cfg.parallel {
    fputs("dnsbench: --reconnect implies sequential mode, disabling parallel\n", stderr)
    cfg.parallel = false
}
if rtFlag { applyRuntimeHints() }
if let core = pinCore {
#if canImport(Darwin)
    fputs("pin: CPU affinity is not supported on Darwin, ignoring --pin \(core)\n", stderr)
#else
    var set = cpu_set_t()
    withUnsafeMutableBytes(of: &set) { raw in
        if core / 8 < raw.count { raw[core / 8] |= UInt8(1 << (core % 8)) }
    }
    if sched_setaffinity(0, MemoryLayout<cpu_set_t>.size, &set) == 0 {
        fputs("pin: pinned to CPU \(core)\n", stderr)
    } else {
        fputs("pin: sched_setaffinity failed (errno \(errno)), continuing\n", stderr)
    }
#endif
}
ktsActive = ktsFlag

// Validate names once so the packet builder stays trap-free.
for hd in cfg.hitDomains where !validDNSName(hd.name) {
    fputs("dnsbench: invalid hit domain: \(hd.name)\n", stderr); exit(1)
}
let missName = "000000000000." + cfg.missBase          // placeholder label, patched per query
if !validDNSName(missName) {
    fputs("dnsbench: invalid miss_base: \(cfg.missBase)\n", stderr); exit(1)
}

let refMetric = sortKey ?? .p50
let recvCap = 2048                                     // > EDNS0 bufsize 1232
var recvBuf = [UInt8](repeating: 0, count: recvCap)

var fds = [Int32](); var names = [String](); var isV6 = [Bool]()
var addrs = [String]()                                 // address literal from the conf (JSON output)
// Transport state, per entry. Stream entries keep their address: they reconnect.
var isStream = [Bool](); var ports = [UInt16]()
var sas = [sockaddr_storage](); var salens = [socklen_t](); var fams = [Int32]()
var reconns = [Int]()                                  // warm streams found closed while idle, reopened before t0
var skippedFamily = 0
for r in cfg.resolvers {
    guard let tgt = parseTarget(r.ip) else {
        fputs("warning: skipping \(r.name): invalid address or unsupported transport (\(r.ip))\n", stderr); continue
    }
    let stream = tcpFlag || tgt.transport == .tcp
    guard let (ss, len, fam) = resolveSockaddr(tgt.host, tgt.port) else {
        fputs("warning: skipping invalid address: \(r.name) (\(r.ip))\n", stderr); continue
    }
    if let only = familyOnly, fam != only { skippedFamily += 1; continue }
    var mss = ss
    var fd: Int32 = -1
    if stream {
        // Warm streams connect now, untimed (cold ones connect once per query).
        // A server that refuses or filters TCP stays in the panel: every visit
        // retries, and its row reports the failures.
        if !reconnectFlag {
            fd = openStream(addr: &mss, addrlen: len, family: fam, timeoutMs: cfg.timeoutMs,
                            nonblocking: cfg.parallel || spinFlag, busyPoll: rtFlag).fd
            if fd < 0 {
                fputs("warning: cannot connect to \(r.name) (\(r.ip)) over tcp - kept in the panel, retried at every visit\n", stderr)
            }
        }
    } else {
        fd = openConnectedSocket(addr: &mss, addrlen: len, family: fam,
                                 timeoutMs: cfg.timeoutMs, nonblocking: cfg.parallel || spinFlag)
        if fd < 0 {
            fputs("warning: cannot open/connect socket for \(r.name) (\(r.ip)), skipping\n", stderr); continue
        }
    }
    if ktsFlag && !stream {
        var one: Int32 = 1
#if canImport(Darwin)
        let tsrc = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &one, socklen_t(MemoryLayout<Int32>.size))
#else
        let tsrc = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPNS, &one, socklen_t(MemoryLayout<Int32>.size))
#endif
        if tsrc != 0 && ktsActive {
            ktsActive = false
            fputs("kts: enabling kernel timestamps failed (errno \(errno)), user-space clock fallback\n", stderr)
        }
    }
#if !canImport(Darwin)
    if rtFlag && !stream {
        var us: Int32 = 50
        if setsockopt(fd, SOL_SOCKET, SO_BUSY_POLL, &us, socklen_t(MemoryLayout<Int32>.size)) != 0 && !busyPollWarned {
            busyPollWarned = true
            fputs("rt: SO_BUSY_POLL unavailable (privileges/driver), continuing\n", stderr)
        }
    }
#endif
    fds.append(fd); names.append(r.name); addrs.append(tgt.host); isV6.append(fam == AF_INET6)
    isStream.append(stream); ports.append(tgt.port); sas.append(ss); salens.append(len); fams.append(fam)
    reconns.append(0)
    streamBuf.append(stream ? [UInt8](repeating: 0, count: streamCap) : []); streamHave.append(0)
    if verboseFlag {
        var dbgSS = ss
        var dbgHost = [CChar](repeating: 0, count: 64)
        let gi = withUnsafePointer(to: &dbgSS) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            getnameinfo(sap, len, &dbgHost, socklen_t(64), nil, 0, NI_NUMERICHOST) } }
        let parsed = gi == 0 ? String(cString: dbgHost) : "ERR(\(gi))"
        fputs("resolver '\(r.name)': conf=[\(r.ip)] -> \(fam == AF_INET6 ? "v6" : "v4") parsed=[\(parsed)]:\(tgt.port)\(stream ? " tcp" : "")\n", stderr)
    }
}
if fds.isEmpty { fputs("dnsbench: no usable resolvers.\n", stderr); exit(1) }
let anyStream = isStream.contains(true)
if let only = familyOnly, skippedFamily > 0 {
    fputs("family: \(only == AF_INET ? "IPv4" : "IPv6") only - \(skippedFamily) entries skipped\n", stderr)
}
switch visitOrder {
case .v4First: baseOrder = fds.indices.filter { !isV6[$0] } + fds.indices.filter { isV6[$0] }
case .v6First: baseOrder = fds.indices.filter { isV6[$0] } + fds.indices.filter { !isV6[$0] }
default:       baseOrder = Array(fds.indices)
}
if ktsActive {
#if canImport(Darwin)
    fputs("kts: kernel RX timestamps on (mach monotonic domain)\n", stderr)
#else
    fputs("kts: kernel RX timestamps on (CLOCK_REALTIME domain - NTP slew <= 0.5 us/ms, avoid clock steps mid-run)\n", stderr)
#endif
    if anyStream { fputs("kts: datagram entries only - tcp samples take t1 in user space (do not compare them to kts rows at the us level)\n", stderr) }
}

// Stream entries: connection upkeep, and one query (see "Stream transport").
// Bring entry i to a usable connection, outside any timed window. nil = ready;
// otherwise the outcome to record for the query that could not be sent.
func ensureStream(_ i: Int) -> Probe? {
    if fds[i] >= 0 && streamStale(fds[i]) { close(fds[i]); fds[i] = -1; reconns[i] += 1 }
    if fds[i] >= 0 { return nil }
    let (fd, res) = openStream(addr: &sas[i], addrlen: salens[i], family: fams[i], timeoutMs: cfg.timeoutMs,
                               nonblocking: cfg.parallel || spinFlag, busyPoll: rtFlag)
    if fd < 0 { return res == .timeout ? .timeout : .netErr }
    fds[i] = fd; streamHave[i] = 0
    return nil
}

// One query on stream entry i, the way a client lives it. An attempt either
// rides the persistent connection (warm, first attempt) or dials inside the
// timed window (cold mode, and any retry). When the server closes or resets
// the connection with the query in flight, the query is repeated once on a
// new connection: t0 and the timeout budget are those of the first attempt.
func streamQuery(_ i: Int, _ query: [UInt8], _ id: UInt16, spin: Bool,
                 wantTTL: Bool) -> (probe: Probe, ttl: UInt32?, retried: Bool) {
    var t0: UInt64? = nil
    var retried = false
    while true {
        let dial = reconnectFlag || retried
        var fd: Int32
        if dial {
            fd = makeStreamSocket(family: fams[i], busyPoll: rtFlag)
            if fd < 0 { return (.netErr, nil, retried) }
            streamHave[i] = 0
            let opened = t0 ?? probeNow()
            t0 = opened
            let c = connectStream(fd, &sas[i], salens[i], deadline: opened &+ UInt64(cfg.timeoutMs) &* 1_000_000, spin: spin)
            if c != .ok { close(fd); return (c == .timeout ? .timeout : .netErr, nil, retried) }
        } else {
            if let failed = ensureStream(i) { return (failed, nil, false) }
            fd = fds[i]
        }
        let r = streamExchange(fd: fd, query: query, expectId: id, t0: t0, timeoutMs: cfg.timeoutMs,
                               nonblock: dial || cfg.parallel || spinFlag, spin: spin, wantTTL: wantTTL,
                               buf: &streamBuf[i], have: &streamHave[i])
        t0 = r.t0
        if reconnectFlag {
            close(fd)                                  // cold: one connection per attempt
        } else if !r.alive {
            close(fd); fds[i] = -1
        } else if dial {                               // warm: the retry's connection carries on
            settleStream(fd, timeoutMs: cfg.timeoutMs, nonblocking: cfg.parallel || spinFlag)
            fds[i] = fd
        }
        if case .closed = r.probe, !retried { retried = true; continue }
        return (r.probe, r.ttl, retried)
    }
}

// A stream sample and its bookkeeping: a repeated query is counted, whatever
// its outcome.
func streamSample(_ acc: inout [Acc], _ i: Int, _ query: [UInt8], _ id: UInt16) {
    let r = streamQuery(i, query, id, spin: spinFlag, wantTTL: false)
    if r.retried { acc[i].retried += 1 }
    record(&acc, i, r.probe)
}

// Query templates: built once, TXID (and MISS label) patched in place per send.
// send() copies the payload into the kernel, so one buffer serves everything.
var hitTemplates: [[UInt8]] = cfg.hitDomains.map { buildQuery(id: 0, name: $0.name, qtype: $0.qtype ?? cfg.qtype, edns: cfg.edns) }
var missTemplate = buildQuery(id: 0, name: missName, qtype: cfg.qtype, edns: cfg.edns)
let missLabelOffset = 13                               // header (12) + length byte

var rng = XorShift64(seed: monotonicNanos() ^ (UInt64(bitPattern: Int64(getpid())) << 32))

let (clkCost, clkRes) = clockCalibration()
let doHit = cfg.mode != .miss, doMiss = cfg.mode != .hit
let startedStamp = utcStamp()
print("dnsbench v\(VERSION) - \(fds.count) resolvers, \(cfg.rounds) rounds/mode, mode=\(cfg.mode == .both ? "both" : (cfg.mode == .hit ? "hit" : "miss"))\(cfg.parallel ? " (parallel)" : "")\(spinFlag ? " (spin)" : "")\(cfg.edns ? " (edns)" : "")\(ktsActive ? " (kts)" : "")\(tcpFlag ? " (tcp)" : "")\(reconnectFlag && anyStream ? " (reconnect)" : "")\(orderMark())\(familyOnly == AF_INET ? " (v4 only)" : (familyOnly == AF_INET6 ? " (v6 only)" : "")), "
    + "timeout \(cfg.timeoutMs) ms\(cfg.gapMs > 0 ? ", gap \(cfg.gapMs) ms" : ""), \(cfg.hitDomains.count) hit domain(s), default qtype=\(qtypeName(cfg.qtype)), vs/sort=\(metricName(refMetric))")
print("clock: ~\(clkCost) ns/call, resolution \(clkRes) ns")
print("MISS=<rand>.\(cfg.missBase)\n")

// Warm-up the cache-HIT, and read the answers' min TTL: a run longer than the
// TTL re-fetches upstream mid-run, silently contaminating HIT with MISS.
if doHit {
    var domainTTL = [UInt32?](repeating: nil, count: cfg.hitDomains.count)
    for i in fds.indices {
        for d in cfg.hitDomains.indices {
            let id = rng.nextId()
            patchId(&hitTemplates[d], id)
            let ttl = isStream[i]
                ? streamQuery(i, hitTemplates[d], id, spin: false, wantTTL: true).ttl
                : warmupProbe(fd: fds[i], query: hitTemplates[d], expectId: id, timeoutMs: cfg.timeoutMs, recvBuf: &recvBuf)
            if let ttl = ttl {
                if domainTTL[d] == nil || ttl < domainTTL[d]! { domainTTL[d] = ttl }
            }
        }
    }
    for d in cfg.hitDomains.indices {
        if let ttl = domainTTL[d] {
            let warn = ttl < 120 ? "  <- short TTL: a run longer than this re-fetches (HIT contaminated by MISS)" : ""
            fputs("warmup: \(cfg.hitDomains[d].name) min TTL \(ttl)s\(warn)\n", stderr)
        }
    }
}

var hit = [Acc](repeating: Acc(), count: fds.count)
var miss = [Acc](repeating: Acc(), count: fds.count)
for i in fds.indices {
    hit[i].samples.reserveCapacity(cfg.rounds)
    miss[i].samples.reserveCapacity(cfg.rounds)
}

// Progress: time-throttled (~200 ms), checked after each resolver, with req/s.
let runStart = monotonicNanos()
var progLast = runStart
var done = 0
func showProgress(_ round: Int) {
    var fails = 0; var errs = 0
    for i in fds.indices { fails += hit[i].fails + miss[i].fails; errs += hit[i].rcodeErrs + miss[i].rcodeErrs }
    let elapsed = Double(monotonicNanos() &- runStart) / 1_000_000_000.0
    let qps = elapsed > 0 ? UInt64((Double(done) / elapsed).rounded()) : 0
    let pct = (round + 1) * 100 / cfg.rounds
    fputs("\rrounds \(round + 1)/\(cfg.rounds) (\(pct)%)  reqs \(done)  fails \(fails)  errs \(errs)  \(qps)/s     ", stderr)
}

let N = fds.count

// Parallel-mode scratch, allocated once.
var parIds = [UInt16](repeating: 0, count: N)
var parT0 = [UInt64](repeating: 0, count: N)
var parPfds = [pollfd](repeating: pollfd(), count: N)
var parOrder = [Int](repeating: 0, count: N)
var parResults = [Probe?](repeating: nil, count: N)
var parStage = [UInt8](repeating: 0, count: N)      // streams: non-zero = query repeated after a close
var seqOrder = baseOrder            // sequential visit order, reshuffled per round in shuffle mode

func record(_ acc: inout [Acc], _ i: Int, _ p: Probe) {
    switch p {
    case .ok(let r):        acc[i].samples.append(r)
    case .rcode(_, let rc): acc[i].rcodeCounts[Int(rc)] += 1
    case .timeout:          acc[i].timeouts += 1
    case .netErr:           acc[i].netErrs += 1
    case .closed:           acc[i].closes += 1
    }
}

for round in 0..<cfg.rounds {
    let dIdx = round % cfg.hitDomains.count
    if cfg.parallel {
        // Streams the server closed since the last phase are reopened here,
        // before any t0 - never inside the fan-out.
        if doHit {
            if anyStream { for i in 0..<N where isStream[i] { _ = ensureStream(i) } }
            fanPhase(fds: &fds, streams: isStream, stage: &parStage, template: &hitTemplates[dIdx], labelOffset: nil,
                     rng: &rng, timeoutMs: cfg.timeoutMs, recvBuf: &recvBuf,
                     ids: &parIds, t0: &parT0, pfds: &parPfds, order: &parOrder, results: &parResults)
            for i in 0..<N {
                if parStage[i] != 0 { hit[i].retried += 1 }
                record(&hit, i, parResults[i] ?? .timeout); done += 1
            }
            if cfg.gapMs > 0 { sleepMs(cfg.gapMs) }
        }
        if doMiss {
            if anyStream { for i in 0..<N where isStream[i] { _ = ensureStream(i) } }
            fanPhase(fds: &fds, streams: isStream, stage: &parStage, template: &missTemplate, labelOffset: missLabelOffset,
                     rng: &rng, timeoutMs: cfg.timeoutMs, recvBuf: &recvBuf,
                     ids: &parIds, t0: &parT0, pfds: &parPfds, order: &parOrder, results: &parResults)
            for i in 0..<N {
                if parStage[i] != 0 { miss[i].retried += 1 }
                record(&miss, i, parResults[i] ?? .timeout); done += 1
            }
            if cfg.gapMs > 0 { sleepMs(cfg.gapMs) }
        }
        let now = monotonicNanos()
        if now &- progLast > 200_000_000 { progLast = now; showProgress(round) }
    } else {
        // Visit order per round (see --order): shuffle makes same-server
        // entries exchangeable; other modes follow the precomputed baseOrder.
        if visitOrder == .shuffle && N > 1 {
            var k = N - 1
            while k > 0 { let j = Int(rng.next() % UInt64(k + 1)); seqOrder.swapAt(k, j); k -= 1 }
        }
        for oi in 0..<N {
            let i = seqOrder[oi]
            if doHit {
                let id1 = rng.nextId()
                patchId(&hitTemplates[dIdx], id1)
                if isStream[i] {
                    streamSample(&hit, i, hitTemplates[dIdx], id1)
                } else {
                    record(&hit, i, measureOnce(fd: fds[i], query: hitTemplates[dIdx], expectId: id1,
                                                timeoutMs: cfg.timeoutMs, spin: spinFlag, recvBuf: &recvBuf))
                }
                done += 1
                if cfg.gapMs > 0 { sleepMs(cfg.gapMs) }
            }
            if doMiss {
                let id2 = rng.nextId()
                patchId(&missTemplate, id2)
                patchLabel(&missTemplate, missLabelOffset, &rng)
                if isStream[i] {
                    streamSample(&miss, i, missTemplate, id2)
                } else {
                    record(&miss, i, measureOnce(fd: fds[i], query: missTemplate, expectId: id2,
                                                 timeoutMs: cfg.timeoutMs, spin: spinFlag, recvBuf: &recvBuf))
                }
                done += 1
                if cfg.gapMs > 0 { sleepMs(cfg.gapMs) }
            }
            let now = monotonicNanos()
            if now &- progLast > 200_000_000 { progLast = now; showProgress(round) }
        }
    }
}
let elapsedNs = monotonicNanos() &- runStart
showProgress(cfg.rounds - 1)
fputs("\n\n", stderr)

let hitOrd = ordering(hit, sortKey), missOrd = ordering(miss, sortKey)
if doHit { printTable("=== cache-HIT (ms) ===", hit, names, hitOrd, refMetric) }
if doMiss { print(""); printTable("=== cache-MISS (ms) ===", miss, names, missOrd, refMetric) }

// Anomaly report: everything excluded from the latency samples, per resolver.
let anomW = max(16, (names.map { $0.count }.max() ?? 0) + 2)
var anomalyLines = [String]()
for i in fds.indices {
    var segs = [String]()
    if doHit, let ad = anomalyDesc(hit[i]) { segs.append("HIT: " + ad) }
    if doMiss, let ad = anomalyDesc(miss[i]) { segs.append("MISS: " + ad) }
    if !segs.isEmpty { anomalyLines.append(col(names[i], anomW) + segs.joined(separator: "  |  ")) }
}
if anomalyLines.isEmpty {
    print("\nno anomalies: every reply was NOERROR/NXDOMAIN, no timeouts, no network errors")
} else {
    print("\n=== anomalies (excluded from samples) ===")
    for l in anomalyLines { print(l) }
    if hit.contains(where: { $0.rcodeCounts[5] > 0 }) || miss.contains(where: { $0.rcodeCounts[5] > 0 }) {
        print("note: REFUSED from a Pi-hole is typically FTL rate limiting (default 1000 q / 60 s per client) - consider --gap")
    }
}
// What the servers did to the streams - none of it excluded from the samples.
// Closed while idle: reopened before t0, the next sample rode a new
// connection. Closed with a query in flight: the query was repeated, and its
// sample spans the lost attempt, the handshake and the answer.
for i in fds.indices {
    if reconns[i] > 0 {
        print("note: \(names[i]): tcp connection closed by the server while idle, \(reconns[i]) time(s) - reopened before t0, outside the samples")
    }
    let repeated = (doHit ? hit[i].retried : 0) + (doMiss ? miss[i].retried : 0)
    if repeated > 0 {
        print("note: \(names[i]): tcp connection closed by the server mid-query, \(repeated) time(s) - query repeated on a new connection; those samples include the lost attempt and the handshake")
    }
}

if let hp = htmlPath {
    let hOrd = ordering(hit, sortKey ?? .p50), mOrd = ordering(miss, sortKey ?? .p50)
    writeHTML(hp, cfg, names, isV6, hit, miss, hOrd, mOrd, refMetric, clkCost, clkRes)
}
if let jp = jsonPath {
    writeJSON(jp, cfg, names, addrs, isV6, hit, miss, refMetric, clkCost, clkRes, startedStamp, elapsedNs)
}
if let cp = csvPath {
    writeCSV(cp, cfg, names, hit, miss, hitOrd, missOrd, refMetric, startedStamp)
}

for fd in fds where fd >= 0 { close(fd) }
