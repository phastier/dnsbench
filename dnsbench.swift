// dnsbench.swift - sub-millisecond DNS latency probe, cross-platform (macOS + Linux)
//
// Measures the application-level RTT of a DNS query (sendto -> recvfrom), i.e.
// exactly what a real client experiences, separating cache-HIT from cache-MISS,
// and reporting exact percentiles. Every variable value lives in an external
// config file; this source holds none.
//
// No dependencies: raw POSIX sockets + a monotonic clock that is NOT NTP-slewed.
// Foundation is intentionally NOT imported.
//
// Build: see Makefile (swiftc -O dnsbench.swift -o dnsbench).
// Usage: ./dnsbench [-c FILE] [--rounds N] [--qtype A|AAAA] [--mode hit|miss|both]
//                   [--sort KEY] [--html FILE] [-h]

#if canImport(Darwin)
import Darwin
let SOCK_DGRAM_VAL = SOCK_DGRAM            // Int32 on Darwin
#elseif canImport(Glibc)
import Glibc
let SOCK_DGRAM_VAL = Int32(SOCK_DGRAM.rawValue)   // enum on Glibc
#endif

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

// ───────────────────────────── Config ─────────────────────────────
enum Mode { case hit, miss, both }
func parseMode(_ s: String) -> Mode? {
    switch s { case "hit": return .hit; case "miss": return .miss; case "both": return .both; default: return nil }
}

struct Config {
    var rounds = 2000
    var timeoutSec = 1
    var hitDomains: [(name: String, qtype: UInt16?)] = []
    var missBase = "example.com"
    var qtype: UInt16 = 1
    var mode: Mode = .both
    var parallel = false
    var resolvers: [(ip: String, name: String)] = []
}

func parseQType(_ s: String) -> UInt16 { (s == "AAAA" || s == "aaaa") ? 28 : 1 }

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
            c.hitDomains.append((p[0], p.count >= 2 ? parseQType(p[1]) : nil))
            continue
        }
        guard let eq = t.firstIndex(of: "=") else { continue }
        let key = String(trim(t[t.startIndex..<eq]))
        let val = String(trim(t[t.index(after: eq)...]))
        switch key {
        case "rounds":      c.rounds = Int(val) ?? c.rounds
        case "timeout_sec": c.timeoutSec = Int(val) ?? c.timeoutSec
        case "hit_domain":  c.hitDomains.append((val, nil))
        case "miss_base":   c.missBase = val
        case "qtype":       c.qtype = parseQType(val)
        case "mode":        c.mode = parseMode(val) ?? c.mode
        case "parallel":    c.parallel = (val == "yes" || val == "true" || val == "1")
        default:            break
        }
    }
    if c.hitDomains.isEmpty { c.hitDomains = [("www.apple.com", nil)] }
    return c
}

// ───────────────────────────── DNS query ─────────────────────────────
func buildQuery(id: UInt16, name: String, qtype: UInt16) -> [UInt8] {
    var p = [UInt8](); p.reserveCapacity(32 + name.utf8.count)
    p += [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    for label in name.split(separator: ".") { let b = Array(label.utf8); p.append(UInt8(b.count)); p += b }
    p.append(0x00)
    p += [UInt8(qtype >> 8), UInt8(qtype & 0xff), 0x00, 0x01]
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

func openSocket(family: Int32, timeoutSec: Int, nonblocking: Bool) -> Int32 {
    let fd = socket(family, SOCK_DGRAM_VAL, 0)
    if fd < 0 { return fd }
    var tv = timeval(); tv.tv_sec = .init(timeoutSec); tv.tv_usec = 0
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    if nonblocking { let fl = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK) }
    return fd
}

func measureOnce(fd: Int32, addr: inout sockaddr_storage, addrlen: socklen_t,
                 query: [UInt8], expectId: UInt16, recvBuf: inout [UInt8]) -> UInt64? {
    let t0 = monotonicNanos()
    let sent = query.withUnsafeBytes { qb -> Int in
        withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                sendto(fd, qb.baseAddress, qb.count, 0, sap, addrlen)
            }
        }
    }
    if sent < 0 { return nil }
    let n = recvBuf.withUnsafeMutableBytes { rb in recvfrom(fd, rb.baseAddress, rb.count, 0, nil, nil) }
    let t1 = monotonicNanos()
    if n < 2 { return nil }
    let rid = (UInt16(recvBuf[0]) << 8) | UInt16(recvBuf[1])
    if rid != expectId { return nil }
    return t1 &- t0
}

// Parallel fan-out / fan-in: one query per resolver sent at once, replies
// collected via poll(). One request in flight PER RESOLVER, so each resolver's
// latency is still measured without on-resolver contention; only the wall-clock
// per round collapses from sum(latencies) to ~max(latency). Sockets must be
// non-blocking (set when cfg.parallel). Returns RTT per resolver (nil = no reply).
func fanPhase(fds: [Int32], addrs: inout [sockaddr_storage], lens: [socklen_t],
              queries: [[UInt8]], ids: [UInt16], timeoutSec: Int, recvBuf: inout [UInt8]) -> [UInt64?] {
    let n = fds.count
    var t0 = [UInt64](repeating: 0, count: n)
    var rtt = [UInt64?](repeating: nil, count: n)
    var pfds = [pollfd](repeating: pollfd(), count: n)
    var pending = 0
    for i in 0..<n {
        pfds[i].fd = -1; pfds[i].events = Int16(POLLIN); pfds[i].revents = 0
        t0[i] = monotonicNanos()
        let sent = queries[i].withUnsafeBytes { qb -> Int in
            withUnsafePointer(to: &addrs[i]) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    sendto(fds[i], qb.baseAddress, qb.count, 0, sap, lens[i])
                }
            }
        }
        if sent >= 0 { pfds[i].fd = fds[i]; pending += 1 }
    }
    let deadline = monotonicNanos() &+ UInt64(timeoutSec) &* 1_000_000_000
    while pending > 0 {
        let now = monotonicNanos()
        if now >= deadline { break }
        let remMs = Int32(min(UInt64(Int32.max), (deadline &- now) / 1_000_000))
        let rc = pfds.withUnsafeMutableBufferPointer { buf in
            poll(buf.baseAddress, nfds_t(buf.count), remMs > 0 ? remMs : 1)
        }
        if rc <= 0 { break }
        for i in 0..<n {
            if pfds[i].fd < 0 { continue }
            if (Int32(pfds[i].revents) & POLLIN) != 0 {
                let m = recvBuf.withUnsafeMutableBytes { rb in recvfrom(fds[i], rb.baseAddress, rb.count, 0, nil, nil) }
                let t1 = monotonicNanos()
                if m >= 2 {
                    let rid = (UInt16(recvBuf[0]) << 8) | UInt16(recvBuf[1])
                    if rid == ids[i] { rtt[i] = t1 &- t0[i]; pfds[i].fd = -1; pending -= 1 }
                }
            }
            pfds[i].revents = 0
        }
    }
    return rtt
}

// ───────────────────────────── Statistics ─────────────────────────────
struct Acc { var samples: [UInt64] = []; var fails = 0 }

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

func printRow(_ name: String, _ a: Acc, _ vs: String, _ nameW: Int) {
    var s = a.samples; s.sort()
    let (mean, std) = meanStd(s)
    print(col(name, nameW) + col("\(s.count)", 7) + col("\(a.fails)", 6)
        + col(msStr(percentile(s, 0)), 10) + col(msStr(percentile(s, 50)), 10)
        + col(msStr(percentile(s, 90)), 10) + col(msStr(percentile(s, 99)), 10)
        + col(msStr(percentile(s, 99.9)), 10) + col(msStr(percentile(s, 100)), 10)
        + col(msStr(mean), 10) + col(msStr(std), 10) + col(vs, 9))
}
func printTable(_ title: String, _ accs: [Acc], _ names: [String], _ ord: [Int], _ refMetric: SortKey) {
    let best = bestValue(accs, refMetric)
    let nameW = max(16, (names.map { $0.count }.max() ?? 0) + 2)
    let header = col("resolver", nameW) + col("n", 7) + col("fail", 6) + col("min", 10) + col("p50", 10)
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
    let head = "<tr><th class=\"name\">resolver</th><th>n</th><th>fail</th><th>min</th><th>p50</th>"
        + "<th>p90</th><th>p99</th><th>p99.9</th><th>max</th><th>mean</th><th>std</th><th>vs</th>"
        + "<th class=\"bar\">p50</th></tr>"
    var rows = ""
    for i in ord {
        let a = accs[i]; var s = a.samples; s.sort()
        let (mean, std) = meanStd(s)
        let p50 = a.samples.isEmpty ? 0 : percentile(s, 50)
        let w = a.samples.isEmpty ? 0 : Int((Double(p50) / maxP50 * 100.0).rounded())
        let cls = a.samples.isEmpty ? " class=\"dead\"" : ""
        rows += "<tr\(cls)><td class=\"name\">\(he(names[i]))</td><td>\(a.samples.count)</td><td>\(a.fails)</td>"
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
    """
    var d = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    d += "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>dnsbench results</title>"
    d += "<style>\(css)</style></head><body><h1>dnsbench results</h1>"
    d += "<p class=\"meta\">\(nowString()) &middot; \(names.count) resolvers &middot; \(cfg.rounds) rounds/mode &middot; "
    d += "default qtype \(cfg.qtype == 28 ? "AAAA" : "A") &middot; vs/sort on \(metricName(refMetric)) &middot; "
    d += "clock ~\(clkCost) ns/call, res \(clkRes) ns &middot; MISS &lt;rand&gt;.\(he(cfg.missBase))</p>"
    if cfg.mode != .miss {
        d += htmlTable("cache-HIT (ms)", hit, names, hOrd, refMetric)
        d += "<h2>cache-HIT distribution (CDF)</h2>" + cdfChart(hit, names, isV6, hOrd)
    }
    if cfg.mode != .hit {
        d += htmlTable("cache-MISS (ms)", miss, names, mOrd, refMetric)
        d += "<h2>cache-MISS distribution (CDF)</h2>" + cdfChart(miss, names, isV6, mOrd)
    }
    d += "<p class=\"foot\">Values in ms. CDF: a curve further left = faster; v4 solid, v6 dashed; X is log-scaled and "
    d += "clipped at p99. Bars/vs scale to the fastest on \(metricName(refMetric)). Red rows were unreachable.</p></body></html>"

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
    usage: dnsbench [-c FILE] [--rounds N] [--qtype A|AAAA] [--mode hit|miss|both]
                    [--sort KEY] [--html FILE] [-h]
      -c, --config FILE      configuration file (default: ./dnsbench.conf)
          --rounds N         override the round count (quick smoke test)
          --qtype A|AAAA     override the global query type
          --mode hit|miss|both   which phase(s) to run (default: both)
          --parallel         fan out one query per resolver at once (poll-based)
          --no-parallel      force sequential closed-loop (overrides config)
          --sort KEY         sort + vs-ratio on min|p50|p90|p99|p999|max|mean
          --html FILE        also write a standalone HTML report (tables + CDF charts)
      -h, --help             show this help and exit
    A bare argument is also accepted as the config file path.

    """, stderr)
}

var configPath = "dnsbench.conf"
var roundsOverride: Int? = nil
var qtypeOverride: UInt16? = nil
var modeOverride: Mode? = nil
var parallelOverride: Bool? = nil
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
        guard let v = it.next() else { fputs("dnsbench: --qtype requires A or AAAA\n", stderr); exit(2) }
        qtypeOverride = parseQType(v)
    case "--mode":
        guard let v = it.next(), let m = parseMode(v) else { fputs("dnsbench: --mode requires hit|miss|both\n", stderr); exit(2) }
        modeOverride = m
    case "--parallel":
        parallelOverride = true
    case "--no-parallel":
        parallelOverride = false
    case "--sort":
        guard let v = it.next(), let k = parseSort(v) else { fputs("dnsbench: --sort requires min|p50|p90|p99|p999|max|mean\n", stderr); exit(2) }
        sortKey = k
    case "--html":
        guard let v = it.next() else { fputs("dnsbench: --html requires a file path\n", stderr); exit(2) }
        htmlPath = v
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
if cfg.resolvers.isEmpty { fputs("dnsbench: no resolvers in \(configPath) ([resolvers] section).\n", stderr); exit(1) }

let refMetric = sortKey ?? .p50
let recvCap = 1500
var recvBuf = [UInt8](repeating: 0, count: recvCap)

var addrs = [sockaddr_storage](); var lens = [socklen_t](); var fds = [Int32](); var names = [String](); var isV6 = [Bool]()
for r in cfg.resolvers {
    guard let (ss, len, fam) = resolveSockaddr(r.ip, 53) else {
        fputs("warning: skipping invalid address: \(r.name) (\(r.ip))\n", stderr); continue
    }
    addrs.append(ss); lens.append(len); fds.append(openSocket(family: fam, timeoutSec: cfg.timeoutSec, nonblocking: cfg.parallel))
    names.append(r.name); isV6.append(fam == AF_INET6)
}

let (clkCost, clkRes) = clockCalibration()
let doHit = cfg.mode != .miss, doMiss = cfg.mode != .hit
print("dnsbench - \(addrs.count) resolvers, \(cfg.rounds) rounds/mode, mode=\(cfg.mode == .both ? "both" : (cfg.mode == .hit ? "hit" : "miss"))\(cfg.parallel ? " (parallel)" : ""), "
    + "\(cfg.hitDomains.count) hit domain(s), default qtype=\(cfg.qtype == 28 ? "AAAA" : "A"), vs/sort=\(metricName(refMetric))")
print("clock: ~\(clkCost) ns/call, resolution \(clkRes) ns")
print("MISS=<rand>.\(cfg.missBase)\n")

// Warm-up the cache-HIT.
if doHit {
    for i in addrs.indices {
        for hd in cfg.hitDomains {
            let id = UInt16.random(in: 0...0xffff)
            let q = buildQuery(id: id, name: hd.name, qtype: hd.qtype ?? cfg.qtype)
            _ = measureOnce(fd: fds[i], addr: &addrs[i], addrlen: lens[i], query: q, expectId: id, recvBuf: &recvBuf)
        }
    }
}

var hit = [Acc](repeating: Acc(), count: addrs.count)
var miss = [Acc](repeating: Acc(), count: addrs.count)

// Progress: time-throttled (~200 ms), checked after each resolver, with req/s.
let runStart = monotonicNanos()
var progLast = runStart
var done = 0
func showProgress(_ round: Int) {
    var fails = 0
    for i in addrs.indices { fails += hit[i].fails + miss[i].fails }
    let elapsed = Double(monotonicNanos() &- runStart) / 1_000_000_000.0
    let qps = elapsed > 0 ? UInt64((Double(done) / elapsed).rounded()) : 0
    let pct = (round + 1) * 100 / cfg.rounds
    fputs("\rrounds \(round + 1)/\(cfg.rounds) (\(pct)%)  reqs \(done)  fails \(fails)  \(qps)/s     ", stderr)
}

let N = addrs.count
for round in 0..<cfg.rounds {
    let hd = cfg.hitDomains[round % cfg.hitDomains.count]
    let qtHit = hd.qtype ?? cfg.qtype
    if cfg.parallel {
        if doHit {
            var qs = [[UInt8]](); qs.reserveCapacity(N); var ids = [UInt16](); ids.reserveCapacity(N)
            for _ in 0..<N { let id = UInt16.random(in: 0...0xffff); ids.append(id); qs.append(buildQuery(id: id, name: hd.name, qtype: qtHit)) }
            let rtts = fanPhase(fds: fds, addrs: &addrs, lens: lens, queries: qs, ids: ids, timeoutSec: cfg.timeoutSec, recvBuf: &recvBuf)
            for i in 0..<N { if let r = rtts[i] { hit[i].samples.append(r) } else { hit[i].fails += 1 }; done += 1 }
        }
        if doMiss {
            var qs = [[UInt8]](); qs.reserveCapacity(N); var ids = [UInt16](); ids.reserveCapacity(N)
            for _ in 0..<N {
                let id = UInt16.random(in: 0...0xffff); ids.append(id)
                qs.append(buildQuery(id: id, name: "x\(UInt32.random(in: 0...0xffffffff)).\(cfg.missBase)", qtype: cfg.qtype))
            }
            let rtts = fanPhase(fds: fds, addrs: &addrs, lens: lens, queries: qs, ids: ids, timeoutSec: cfg.timeoutSec, recvBuf: &recvBuf)
            for i in 0..<N { if let r = rtts[i] { miss[i].samples.append(r) } else { miss[i].fails += 1 }; done += 1 }
        }
        let now = monotonicNanos()
        if now &- progLast > 200_000_000 { progLast = now; showProgress(round) }
    } else {
        for i in addrs.indices {
            if doHit {
                let id1 = UInt16.random(in: 0...0xffff)
                let q1 = buildQuery(id: id1, name: hd.name, qtype: qtHit)
                if let r = measureOnce(fd: fds[i], addr: &addrs[i], addrlen: lens[i], query: q1, expectId: id1, recvBuf: &recvBuf) {
                    hit[i].samples.append(r)
                } else { hit[i].fails += 1 }
                done += 1
            }
            if doMiss {
                let id2 = UInt16.random(in: 0...0xffff)
                let name = "x\(UInt32.random(in: 0...0xffffffff)).\(cfg.missBase)"
                let q2 = buildQuery(id: id2, name: name, qtype: cfg.qtype)
                if let r = measureOnce(fd: fds[i], addr: &addrs[i], addrlen: lens[i], query: q2, expectId: id2, recvBuf: &recvBuf) {
                    miss[i].samples.append(r)
                } else { miss[i].fails += 1 }
                done += 1
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

if let hp = htmlPath {
    let hOrd = ordering(hit, sortKey ?? .p50), mOrd = ordering(miss, sortKey ?? .p50)
    writeHTML(hp, cfg, names, isV6, hit, miss, hOrd, mOrd, refMetric, clkCost, clkRes)
}

for fd in fds where fd >= 0 { close(fd) }
