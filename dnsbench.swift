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
//
// Build: see Makefile (swiftc -O dnsbench.swift -o dnsbench).
// Usage: ./dnsbench [-c FILE] [--rounds N] [--qtype A|AAAA|HTTPS|N] [--mode hit|miss|both]
//                   [--sort KEY] [--html FILE] [--gap MS] [--spin] [--edns] [--rt] [-v] [-h]

#if canImport(Darwin)
import Darwin
let SOCK_DGRAM_VAL = SOCK_DGRAM            // Int32 on Darwin
#elseif canImport(Musl)
import Musl
let SOCK_DGRAM_VAL = SOCK_DGRAM            // plain Int32 on Musl (static SDK)
#elseif canImport(Glibc)
import Glibc
let SOCK_DGRAM_VAL = Int32(SOCK_DGRAM.rawValue)   // enum on Glibc
#endif

let VERSION = "2.3"

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
        if section == "resolvers" {
            let p = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if p.count >= 2 { c.resolvers.append((p[0], p[1])) } else if p.count == 1 { c.resolvers.append((p[0], p[0])) }
            continue
        }
        if section == "hit_domains" {
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
enum Probe { case ok(UInt64); case rcode(UInt64, UInt8); case timeout; case netErr }

// NOERROR and NXDOMAIN are valid latency samples (NXDOMAIN is the expected MISS
// answer). Anything else (SERVFAIL, REFUSED, ...) measures a failure path -
// e.g. Pi-hole FTL rate-limiting answers REFUSED - and lands in `err`.
// Timeouts and network errors (ICMP unreachable, send failures) land in
// `fail`. Both are broken down per kind in the anomalies report.
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
func fanPhase(fds: [Int32], template: inout [UInt8], labelOffset: Int?,
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
        results[i] = nil
        pfds[i].fd = -1; pfds[i].events = Int16(POLLIN); pfds[i].revents = 0
        if fds[i] < 0 { results[i] = .netErr; continue }
        let id = rng.nextId()
        ids[i] = id
        patchId(&template, id)
        if let lo = labelOffset { patchLabel(&template, lo, &rng) }
        t0[i] = probeNow()
        let sent = template.withUnsafeBytes { qb in send(fds[i], qb.baseAddress, qb.count, 0) }
        if sent >= 0 { pfds[i].fd = fds[i]; pending += 1 } else { results[i] = .netErr }
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
    var rcodeCounts = [Int](repeating: 0, count: 16)   // invalid RCODEs by value
    var fails: Int { timeouts + netErrs }
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

let palette = ["#4f46e5", "#dc2626", "#059669", "#d97706", "#0891b2", "#7c3aed",
               "#db2777", "#65a30d", "#2563eb", "#ea580c", "#0d9488", "#9333ea"]

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

// Overlaid CDFs (one line per resolver), log-X. v4 = solid, v6 = dashed.
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

    var svg = "<svg viewBox=\"0 0 \(Int(W)) \(Int(H))\" class=\"chart\" role=\"img\">"
    for g in stride(from: 0.0, through: 100.0, by: 25.0) {
        let y = ypix(g)
        svg += "<line x1=\"\(L)\" y1=\"\(n1(y))\" x2=\"\(L + plotW)\" y2=\"\(n1(y))\" class=\"grid\"/>"
        svg += "<text x=\"\(L - 5)\" y=\"\(n1(y + 3))\" class=\"ylab\">\(Int(g))%</text>"
    }
    let ticks: [Double] = [0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200]
    for tk in ticks where tk >= xminMs && tk <= xmaxMs {
        let x = xpix(tk)
        svg += "<line x1=\"\(n1(x))\" y1=\"\(T)\" x2=\"\(n1(x))\" y2=\"\(n1(T + plotH))\" class=\"grid\"/>"
        let lab = tk < 1 ? "\(tk)" : "\(Int(tk))"
        svg += "<text x=\"\(n1(x))\" y=\"\(n1(T + plotH + 13))\" class=\"xlab\">\(lab)</text>"
    }
    svg += "<text x=\"\(n1(L + plotW / 2))\" y=\"\(Int(H) - 2)\" class=\"axt\">latency (ms, log scale)</text>"

    var legend = "<div class=\"legend\">"
    var ci = 0
    for i in ord {
        let a = accs[i]; if a.samples.isEmpty { continue }
        var s = a.samples; s.sort()
        let color = palette[ci % palette.count]; ci += 1
        let dash = isV6[i] ? " stroke-dasharray=\"5 3\"" : ""
        var pts = ""; var p = 0.0
        while p <= 100.0 { pts += "\(n1(xpix(Double(percentile(s, p)) / 1_000_000.0))),\(n1(ypix(p))) "; p += 2.0 }
        svg += "<polyline points=\"\(pts)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"1.6\"\(dash)/>"
        let style = isV6[i] ? "dashed" : "solid"
        legend += "<span class=\"lg\"><i style=\"border-color:\(color);border-bottom-style:\(style)\"></i>\(he(names[i]))</span>"
    }
    svg += "</svg>"
    legend += "</div>"
    return svg + legend
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
    .legend i{display:inline-block;width:20px;border-bottom-width:2px;border-bottom-style:solid;margin-right:5px;vertical-align:middle}
    .foot{color:#888;font-size:.75rem;margin-top:1.4rem}
    td.anom,th.anom{text-align:left}
    """
    var d = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    d += "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>dnsbench results</title>"
    d += "<style>\(css)</style></head><body><h1>dnsbench results</h1>"
    d += "<p class=\"meta\">dnsbench v\(VERSION) &middot; \(nowString()) &middot; \(names.count) resolvers &middot; \(cfg.rounds) rounds/mode &middot; "
    d += "default qtype \(qtypeName(cfg.qtype)) &middot; timeout \(cfg.timeoutMs) ms\(cfg.gapMs > 0 ? " &middot; gap \(cfg.gapMs) ms" : "")\(cfg.edns ? " &middot; EDNS0" : "")\(ktsActive ? " &middot; kernel RX ts" : "")\(orderMark())\(familyOnly == AF_INET ? " &middot; IPv4 only" : (familyOnly == AF_INET6 ? " &middot; IPv6 only" : "")) &middot; vs/sort on \(metricName(refMetric)) &middot; "
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
    d += "<p class=\"foot\">Values in ms. CDF: a curve further left = faster; v4 solid, v6 dashed; X is log-scaled and "
    d += "clipped at p99. Bars/vs scale to the fastest on \(metricName(refMetric)). Red rows were unreachable. "
    d += "fail counts timeouts and network errors (ICMP unreachable, send failures); err counts replies whose RCODE is neither NOERROR nor NXDOMAIN (SERVFAIL, REFUSED, ...). Both are excluded from the latency samples - hover a fail/err cell for the per-kind breakdown.</p></body></html>"

    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
    if fd < 0 { fputs("dnsbench: cannot write HTML: \(path)\n", stderr); return }
    defer { close(fd) }
    let bytes = Array(d.utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    fputs("HTML written: \(path)\n", stderr)
}

// ───────────────────────────── CLI ─────────────────────────────
func usage() {
    fputs("""
    usage: dnsbench [-c FILE] [--rounds N] [--qtype A|AAAA|HTTPS|N] [--mode hit|miss|both]
                    [--timeout-ms N] [--gap MS] [--spin] [--edns] [--rt] [--kts] [--pin N]
                    [--sort KEY] [--html FILE] [-v] [-h] [--version]
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
          --sort KEY         sort + vs-ratio on min|p50|p90|p99|p999|max|mean
          --html FILE        also write a standalone HTML report (tables + CDF charts)
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
var verboseFlag = false
var sortKey: SortKey? = nil
var htmlPath: String? = nil
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
    case "-v", "--verbose":
        verboseFlag = true
    case "--sort":
        guard let v = it.next(), let k = parseSort(v) else { fputs("dnsbench: --sort requires min|p50|p90|p99|p999|max|mean\n", stderr); exit(2) }
        sortKey = k
    case "--html":
        guard let v = it.next() else { fputs("dnsbench: --html requires a file path\n", stderr); exit(2) }
        htmlPath = v
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
var skippedFamily = 0
for r in cfg.resolvers {
    guard let (ss, len, fam) = resolveSockaddr(r.ip, 53) else {
        fputs("warning: skipping invalid address: \(r.name) (\(r.ip))\n", stderr); continue
    }
    if let only = familyOnly, fam != only { skippedFamily += 1; continue }
    var mss = ss
    let fd = openConnectedSocket(addr: &mss, addrlen: len, family: fam,
                                 timeoutMs: cfg.timeoutMs, nonblocking: cfg.parallel || spinFlag)
    if fd < 0 {
        fputs("warning: cannot open/connect socket for \(r.name) (\(r.ip)), skipping\n", stderr); continue
    }
    if ktsFlag {
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
    if rtFlag {
        var us: Int32 = 50
        if setsockopt(fd, SOL_SOCKET, SO_BUSY_POLL, &us, socklen_t(MemoryLayout<Int32>.size)) != 0 && !busyPollWarned {
            busyPollWarned = true
            fputs("rt: SO_BUSY_POLL unavailable (privileges/driver), continuing\n", stderr)
        }
    }
#endif
    fds.append(fd); names.append(r.name); isV6.append(fam == AF_INET6)
    if verboseFlag {
        var dbgSS = ss
        var dbgHost = [CChar](repeating: 0, count: 64)
        let gi = withUnsafePointer(to: &dbgSS) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            getnameinfo(sap, len, &dbgHost, socklen_t(64), nil, 0, NI_NUMERICHOST) } }
        let parsed = gi == 0 ? String(cString: dbgHost) : "ERR(\(gi))"
        fputs("resolver '\(r.name)': conf=[\(r.ip)] -> \(fam == AF_INET6 ? "v6" : "v4") parsed=[\(parsed)]:53\n", stderr)
    }
}
if fds.isEmpty { fputs("dnsbench: no usable resolvers.\n", stderr); exit(1) }
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
}

// Query templates: built once, TXID (and MISS label) patched in place per send.
// send() copies the payload into the kernel, so one buffer serves everything.
var hitTemplates: [[UInt8]] = cfg.hitDomains.map { buildQuery(id: 0, name: $0.name, qtype: $0.qtype ?? cfg.qtype, edns: cfg.edns) }
var missTemplate = buildQuery(id: 0, name: missName, qtype: cfg.qtype, edns: cfg.edns)
let missLabelOffset = 13                               // header (12) + length byte

var rng = XorShift64(seed: monotonicNanos() ^ (UInt64(bitPattern: Int64(getpid())) << 32))

let (clkCost, clkRes) = clockCalibration()
let doHit = cfg.mode != .miss, doMiss = cfg.mode != .hit
print("dnsbench v\(VERSION) - \(fds.count) resolvers, \(cfg.rounds) rounds/mode, mode=\(cfg.mode == .both ? "both" : (cfg.mode == .hit ? "hit" : "miss"))\(cfg.parallel ? " (parallel)" : "")\(spinFlag ? " (spin)" : "")\(cfg.edns ? " (edns)" : "")\(ktsActive ? " (kts)" : "")\(orderMark())\(familyOnly == AF_INET ? " (v4 only)" : (familyOnly == AF_INET6 ? " (v6 only)" : "")), "
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
            if let ttl = warmupProbe(fd: fds[i], query: hitTemplates[d], expectId: id, timeoutMs: cfg.timeoutMs, recvBuf: &recvBuf) {
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
var seqOrder = baseOrder            // sequential visit order, reshuffled per round in shuffle mode

func record(_ acc: inout [Acc], _ i: Int, _ p: Probe) {
    switch p {
    case .ok(let r):        acc[i].samples.append(r)
    case .rcode(_, let rc): acc[i].rcodeCounts[Int(rc)] += 1
    case .timeout:          acc[i].timeouts += 1
    case .netErr:           acc[i].netErrs += 1
    }
}

for round in 0..<cfg.rounds {
    let dIdx = round % cfg.hitDomains.count
    if cfg.parallel {
        if doHit {
            fanPhase(fds: fds, template: &hitTemplates[dIdx], labelOffset: nil,
                     rng: &rng, timeoutMs: cfg.timeoutMs, recvBuf: &recvBuf,
                     ids: &parIds, t0: &parT0, pfds: &parPfds, order: &parOrder, results: &parResults)
            for i in 0..<N { record(&hit, i, parResults[i] ?? .timeout); done += 1 }
            if cfg.gapMs > 0 { sleepMs(cfg.gapMs) }
        }
        if doMiss {
            fanPhase(fds: fds, template: &missTemplate, labelOffset: missLabelOffset,
                     rng: &rng, timeoutMs: cfg.timeoutMs, recvBuf: &recvBuf,
                     ids: &parIds, t0: &parT0, pfds: &parPfds, order: &parOrder, results: &parResults)
            for i in 0..<N { record(&miss, i, parResults[i] ?? .timeout); done += 1 }
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
                record(&hit, i, measureOnce(fd: fds[i], query: hitTemplates[dIdx], expectId: id1,
                                            timeoutMs: cfg.timeoutMs, spin: spinFlag, recvBuf: &recvBuf))
                done += 1
                if cfg.gapMs > 0 { sleepMs(cfg.gapMs) }
            }
            if doMiss {
                let id2 = rng.nextId()
                patchId(&missTemplate, id2)
                patchLabel(&missTemplate, missLabelOffset, &rng)
                record(&miss, i, measureOnce(fd: fds[i], query: missTemplate, expectId: id2,
                                             timeoutMs: cfg.timeoutMs, spin: spinFlag, recvBuf: &recvBuf))
                done += 1
                if cfg.gapMs > 0 { sleepMs(cfg.gapMs) }
            }
            let now = monotonicNanos()
            if now &- progLast > 200_000_000 { progLast = now; showProgress(round) }
        }
    }
}
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

if let hp = htmlPath {
    let hOrd = ordering(hit, sortKey ?? .p50), mOrd = ordering(miss, sortKey ?? .p50)
    writeHTML(hp, cfg, names, isV6, hit, miss, hOrd, mOrd, refMetric, clkCost, clkRes)
}

for fd in fds where fd >= 0 { close(fd) }
