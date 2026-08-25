# dnsbench

A sub-millisecond DNS latency probe and diagnostic instrument, for choosing
your resolvers — internal or external — and their resolution order, on
measurements as rigorous as we can make them.

This is **not** a public-resolver ranking. Anycast results depend on your
ISP, your peering, your address family and your source address; we measured
deltas of ±0.3 ms on the *same* public resolver from two machines on the
same LAN. dnsbench exists to answer a different question: *on this network,
from this machine, which resolvers should this fleet use, in which order —
and when a number looks wrong, why?*

## Why sub-millisecond

On a LAN, a warm resolver answers in 100–300 µs. `dig` prints its
`Query time` in whole milliseconds: on a 10 GbE network it reads `0 msec`
for every resolver you own, and the entire space where the decision lives
sits below its resolution. A Python or shell wrapper is worse — the
interpreter's overhead is the same size as the signal. `ping` measures the
kernel, not the service. `dnsperf` is a load generator: open loop,
throughput, not the latency one client experiences.

Everything that actually mattered while building this tool lived in that
space:

| Effect (measured, see docs/INVESTIGATION.md) | Size |
|---|---|
| Per-datagram policy evaluation on *unconnected* UDP sockets (macOS with a network-extension stack) | ~150 µs |
| Server wake-up paid by the first query of a burst (C-states, vCPU descheduling) | 125–600 µs |
| "IPv4 is slower than IPv6" — actually a visit-order artifact | +67 to +499 µs |
| One thread hop inside a managed runtime's socket engine | 32–45 µs |
| Deep C-states, CPU frequency ramp-up | 6–28 µs each |
| The probe's own scheduler wake-up | 5–30 µs, hundreds under load |

A tool that rounds to the millisecond sees none of it: a 40 % gap between
two resolvers reads as "both 0 ms". And it is not academic — a stub sends
A and AAAA back-to-back on every lookup, a page load issues dozens, and
every client burst in the fleet pays the resolver's cold start again.

To argue about 100 µs, the instrument's own floor must sit an order of
magnitude lower. Here a raw monotonic clock read costs ~30 ns and a
send/recv pair a few microseconds; dnsbench prints its clock cost and
effective resolution at startup, so every run states its own floor.

## How it works

    dnsbench.conf ──▶ query templates built once (one per HIT domain + one MISS)
                      one connected UDP socket per resolver (v4 or v6)
                                       │
    round r ───────────────────────────┤ order: shuffle | conf | v4-first | v6-first
                                       ▼
    for each resolver ──▶ patch TXID (+ random MISS label) in place, no alloc
              │
              │   t0 ── send() ──▶ kernel ──▶ NIC ~~~~~▶ resolver: cache HIT,
              │                                              │      or recursion
              │   t1 ◀─ recv()  ◀── kernel ◀── NIC ◀~~~~~────┘
              │         │            └── --kts : t1 = kernel RX timestamp
              │         └── default: blocking, SO_RCVTIMEO · --spin: busy-wait
              │
              └─▶ TXID + QR match ─┬─▶ NOERROR / NXDOMAIN → sample = t1 − t0
                                   ├─▶ any other RCODE     → counted, not a sample
                                   ├─▶ stale reply         → drained, keep waiting
                                   └─▶ timeout / ICMP      → counted per resolver
                                       │
                 exact percentiles per resolver and phase · anomalies report
                 self-contained HTML with one CDF per phase

Sequential by default: a closed loop, one query in flight, the round's
wall-clock is the sum of the RTTs. `--parallel` fans one query per
resolver through `poll()` — still one in flight *per resolver*, so each
resolver's latency is unaffected while the round collapses to ~max(RTT).
Ready descriptors are processed in a per-batch random order (fixed order
favoured early config entries by a few µs on fast LANs).

**What the RTT contains.** `t1 − t0` is the application-level round trip:
syscall, kernel UDP path, driver, NIC, wire, the resolver, and the same
stack back. That is deliberate — it is what a real client pays — and,
being common to every resolver in a run, it cancels in the *relative*
comparison. What does *not* cancel is the probe's own wake-up after the
reply lands, which is why three measurement planes exist:

| Plane | t1 is taken… | What leaves the measurement |
|---|---|---|
| default | in user space, after the scheduler wakes the probe | — |
| `--spin` | in user space, busy-polling `recv()` | the scheduler wake-up (costs one core) |
| `--kts` | by the kernel, at packet arrival (`SO_TIMESTAMP_MONOTONIC` / `SO_TIMESTAMPNS`) | wake-up *and* batch bias |

The rung above — NIC hardware timestamps (PHC) — is on the roadmap for
Linux; on macOS the kernel stamp is the ceiling, there is no userland
access to hardware stamps. Every latency tool sits somewhere on this
ladder; the honest thing is to announce the rung.

## Why Swift, and why no Foundation

- **Two OS families, one source, direct syscalls.** The fleet this tool
  was born on is macOS *and* Linux, and the decisive findings were
  OS-level: policy evaluation on Darwin UDP sends, `SCM_TIMESTAMP_MONOTONIC`
  versus `SCM_TIMESTAMPNS`, a Mach time-constraint thread policy versus
  `SCHED_FIFO`. Swift imports `Darwin`, `Glibc` and `Musl` as C modules:
  `recvmsg` with control messages, `thread_policy_set`,
  `sched_setaffinity`, `clock_gettime` are called as-is, no binding layer,
  and the platform split fits in a ten-line shim at the top of the file.
- **Compiled, no garbage collector.** Reference counting is deterministic,
  and the hot path allocates nothing at all — prebuilt templates patched in
  place, scratch buffers allocated once, a xorshift PRNG instead of a
  possible `getrandom(2)` per draw — a property you can check by reading
  one function. A GC pause or an interpreter's dispatch loop lands in the
  same decade as the signal.
- **Memory-safe parsing of untrusted datagrams.** The tool reads DNS
  replies off the network: header, RCODE, compressed answer sections for
  TTLs. Bounds-checked buffers turn a malformed packet into a trap rather
  than a silent overrun, at no cost on the timed path — parsing happens
  after `t1`.
- **No Foundation.** It is large, it is not the same library on Linux and
  macOS, and nothing here needs it. Without it the macOS binary is 190 KB
  and the Linux builds link statically against musl: one file to `scp`
  into a container, a VM or a hypervisor node, nothing to install on the
  target — which is how the whole investigation was deployed.
- **Honestly: C would have done this too.** Swift is what the author writes
  daily on the Apple side; here it is used as C with a type system. What
  you read in `dnsbench.swift` is POSIX.

## Philosophy

- **Closed loop.** Never more than one query in flight per resolver. The
  probe's throughput is the sum of the RTTs, by design: dnsbench is a
  latency instrument, not a load generator (use dnsperf for that).
- **Zero dependencies.** One Swift file, POSIX syscalls, raw monotonic
  clock (~30 ns/read), no Foundation, no external libraries. Static musl
  builds for Linux amd64/arm64; native build on macOS.
- **The OS stack is part of the measurement — deliberately.** A DNS lookup
  crosses your kernel, your scheduler, your NIC driver and (on managed
  Macs) your network-extension stack before it crosses the wire. dnsbench
  measures the whole path, and gives you the tools to isolate each layer:
  kernel RX timestamps, busy-wait floors, RT scheduling hints, CPU pinning,
  visit-order control. Two findings from building it: on macOS with a
  network-extension stack present, every *unconnected* UDP datagram pays a
  per-packet policy-evaluation cost (~0.15 ms on our fleet) that connect()
  amortizes to once per flow; and in any rotating benchmark, *the first
  query of a pair pays the server's wake-up* (125–600 µs depending on
  C-states and virtualization) while the second rides a warm server — a
  bias that silently masquerades as a protocol difference. Details, data
  and falsification tests: docs/INVESTIGATION.md.

## What it measures

For each resolver: cache-HIT latency (rotating pre-warmed domains) and
cache-MISS latency (unique random labels under a base you control — use a
domain you own). Exact percentiles (min/p50/p90/p99/p99.9/max), mean, std,
per-resolver error accounting (timeouts, network errors, per-RCODE counts —
a SERVFAIL is not a latency sample), and a self-contained HTML report with
CDF charts. Late replies are drained, never misattributed.

- **cache-HIT**: pre-warmed domains, resolved hot — the cache service
  latency. The warm-up reads each answer's minimum TTL and warns below
  120 s: a run longer than the TTL re-fetches upstream and contaminates
  HIT with disguised MISSes.
- **cache-MISS**: a fresh random label under `miss_base` on every query,
  forcing a real recursion. The only mode where a recursive resolver and
  a forwarder actually differ. NXDOMAIN is the expected answer and a valid
  sample.

**Why `miss_base` matters.** Point it at a zone *you* control: you own the
authority, the NXDOMAIN is fast and constant, and you measure your
resolver's recursion path rather than a third party's variability. After
the first query the resolver caches the delegation, so subsequent misses
mostly measure the final hop to your authority — representative of
production.

## Cold, warm, and visit order

A resolver idle for ~300 ms re-enters deep C-states (or gets its vCPU
descheduled). Both states are real: *cold* is what the first query of every
client burst pays (stubs send A and AAAA back-to-back); *warm* is steady
state. dnsbench lets you choose what you measure:

- `--order shuffle` (default): per-round random visit order — entries
  sharing a server become exchangeable, fair mix of cold and warm.
- `--order conf`: file order — the first entry of a same-server pair
  absorbs the wake-up. A deliberate cold probe (alias: `--fixed-order`).
- `--order v4-first` / `v6-first`: family blocks — each family cooled
  ~half a round, symmetric and deterministic.
- Tight two-entry conf = warm probe; add `--gap 300` to turn it into a
  symmetric cold probe (the server sleeps before every query).
- `-4` / `-6`: restrict the panel to one family without editing the conf.

## Accuracy planes

- `--kts`: kernel RX timestamps (SO_TIMESTAMP_MONOTONIC / SO_TIMESTAMPNS) —
  t1 is stamped at packet arrival; scheduler wake-up and batch bias leave
  the measurement.
- `--spin`: busy-wait receive — the instrument floor (also keeps the send
  path hot; costs one core).
- `--rt`, `--pin N`: scheduling hints (Darwin time-constraint / Linux
  SCHED_FIFO + SO_BUSY_POLL) and CPU affinity — variance killers.
- `--edns`: probe with an OPT record, like modern stubs actually do.

## Clock

`CLOCK_MONOTONIC_RAW` (Linux) / `CLOCK_UPTIME_RAW` (Darwin): monotonic,
**not NTP/adjtime-disciplined**. At startup dnsbench prints the amortized
cost of one timestamp call and its effective resolution (smallest strictly
positive delta), both in ns — tens of ns against RTTs of hundreds of µs,
so the instrument is orders of magnitude finer than the phenomenon.

With `--kts` on Linux, t0, t1 and deadlines all move to `CLOCK_REALTIME`
to share the `SO_TIMESTAMPNS` domain (NTP slew ≤ 0.5 µs per ms of RTT —
do not *step* the clock mid-run). On Darwin the kernel stamps live in the
same Mach domain as the default clock: nothing changes.

## Statistics, honestly

At n=2000, p50 and p90 are solid; p99 rests on ~20 tail samples
(indicative); p99.9 on 2 (decorative). Use 10000 rounds for a citable p99.
Run-to-run variance exceeds within-run variance: repeat, and **interleave**
repetitions (ABAB), never group them. An effect is real when |Δp50| exceeds
the inter-repetition spread on both sides.

**Reading the results.** Two tables (HIT/MISS) in ms with µs precision:
`n`, `fail`, `err`, `min / p50 / p90 / p99 / p99.9 / max / mean / std`, and
`vs` (ratio to the fastest on the `--sort` metric). Read the percentiles,
not the mean. A resolver with `n=0` and `fail=<rounds>` was unreachable
over that transport — a useful connectivity check in its own right. The
anomalies section lists, per resolver, everything that was excluded from
the samples and why.

**Reading the CDF curves.** A curve further left is faster; percentiles
read off directly (X is log-scaled, v4 solid, v6 dashed). Steps mean a
*multimodal* latency: a plateau is a band with almost no samples, a steep
rise is a mode. Usual causes on public resolvers: anycast/multi-POP
variance, cache tiers (edge hit vs core recursion), aggressive negative
caching (RFC 8198 NSEC) on signed zones. A tight unimodal curve — typical
of a local recursive resolver hitting one authority — is a single
deterministic path.

## Quick start

    make                       # native build
    make linux-amd64           # static musl cross-build (also: linux-arm64)
    cp dnsbench.conf.example dnsbench.conf   # edit: your resolvers, your miss_base
    ./dnsbench --sort p50 --html report.html

`dnsbench.conf.example` documents every key. Progress goes to **stderr**
(rounds, requests, fails, req/s), results to **stdout**, so
`./dnsbench --sort p99 > run.txt` keeps a clean record.

## Critique welcome

This tool was built by measuring, being wrong in public, and testing the
next hypothesis to destruction. If you see a flaw in the method, open an
issue. And if you run 25/40/100 GbE gear: we would love your numbers — at
those speeds the resolver answers in tens of microseconds and the
instrument's floor becomes the story.

See CHANGES.md for the full engineering log, LICENSE for terms.
