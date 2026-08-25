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

## Options, and why each one exists

Nothing here was designed up front. Every flag below was added because a
measurement campaign needed it — and the number that justified it is
given each time. Command-line flags override the corresponding
configuration keys; everything is off by default so that a bare run stays
comparable with earlier ones.

### Run shape

**`-c FILE`** (or a bare argument) — configuration file, default
`./dnsbench.conf`. One panel per file: we keep one for the fleet, one for
public resolvers, tight two-entry ones for cold probes.

**`--rounds N`** — measurements per resolver *and per mode*. 20 for a
smoke test, 2000 for a decision, 10 000 for a citable p99. Why the
distinction matters: at n=2000 the p99 rests on ~20 samples; at
n=10 000, two consecutive runs on the same resolver still put p99.9 at
10.8 ms and then 28 ms — a single ARP refresh moved it. p99.9 is
decoration at any n we can afford.

**`--mode hit|miss|both`** — which phase(s) to run. Public resolvers
rate-limit and DoS-protect random-label floods (DNS4EU caps around
1000 qps per IP, Cloudflare and Google throttle NXDOMAIN bursts): their
MISS is slow, noisy and meaningless, so probe them `hit`-only. `miss`
alone measures the recursion path. Note that in `both`, the MISS query
follows the HIT of the same visit, so MISS is always a *warm* measurement
by construction.

**`--qtype A|AAAA|HTTPS|TXT|N`** — global query type, overridable per hit
domain in the conf. v1 silently mapped any unknown type to A; v2 refuses
it. HTTPS (type 65) is there because that is what modern stubs — Apple's
in particular — actually ask for alongside A and AAAA.

**`--timeout-ms N`** (conf: `timeout_ms`, takes precedence over
`timeout_sec`) — receive timeout. The v1 cascade bug lived exactly at this
boundary: a WAN reply landing just after the 1 s timeout poisoned every
subsequent round (791, 2 590, then 28 430 false failures in one night;
one resolver "lost" 75 % of its rounds). v2 drains late replies, so the
timeout is now a clean classification threshold you can set to the
millisecond — 250 ms is plenty on a LAN.

**`--gap MS`** (conf: `gap_ms`) — pacing: sleep between queries in
sequential mode, between phases in parallel mode. Two reasons, found in
that order. First, rate limits: Pi-hole's FTL answers REFUSED beyond
1000 queries per 60 s per client, and a closed loop at 2000 rounds × 2
modes trips it — v1 could not see it (the REFUSED were counted as
samples), v2 shows it in the `err` column, `--gap 5` avoids it. Second,
and more interesting: `--gap 300` on a tight two-entry conf turns the run
into a **symmetric cold probe** — the server is left idle long enough to
enter deep C-states (or lose its vCPU) before *every* query. That probe is
how we measured the wake-up cost of our resolvers (~330–400 µs on
containers, 450–600 µs on VMs), then tested every hardware lever against
it: deep C-states were worth 20–26 µs, CPU frequency ramp-up 6–28 µs, NIC
interrupt coalescing nothing at all, and one runtime setting
(`DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1`) a confirmed 32–45 µs.

**`--parallel` / `--no-parallel`** (conf: `parallel`) — fan one query per
resolver out at once and collect with `poll()`. One request stays in
flight *per resolver*, so each resolver's latency is untouched; the
round's wall-clock collapses from the sum of RTTs to roughly the slowest
one. On our panel, 2000 rounds took 9 min 30 s sequential and 74 s
parallel. Two caveats we paid for: a parallel run is
not directly comparable to a sequential one (the client core stays hot,
LAN RTTs come out slightly lower), and the order in which ready
descriptors are processed after `poll()` biased early config entries by
a few µs on fast LANs — v2 randomizes it per batch.

### Panel

**`-4` / `-6`** — restrict the panel to one address family without
editing the conf (mutually exclusive). During the IPv4 investigation we
were re-running family-only tests by hand-editing configurations; this
is that edit as a flag.

**`--order shuffle|conf|v4-first|v6-first`**, **`--fixed-order`** (alias
of `conf`) — visit order in sequential mode, send order in parallel mode.
This one is the reason v2.3 exists. For days our data said IPv4 was
slower than IPv6 on the same LAN targets: +67 to +191 µs on container
resolvers, +410 to +499 µs on VMs, from every client, under every option.
We burned four hypotheses on it. The tell: in isolated two-entry tests
the penalty was exactly zero, and in full rotation it always landed on
whichever family was listed *first*. A resolver idle for ~300 ms between
visits cools down — C-state entry for containers, vCPU descheduling for
VMs — and the first query of an adjacent same-server pair pays the
wake-up while the second rides a warm server. An inverted conf (v6 first)
flipped the sign on all four pairs: +401/+159/+120/+479 µs became
−468/−168/−131/−594. Not a protocol effect; a visit-order effect.

Both thermal states are real — *cold* is what the first query of every
client burst pays (stubs send A and AAAA back-to-back), *warm* is steady
state — so the instrument now lets you say which one you sample:

- `shuffle` (default): per-round random order — entries sharing a server
  become exchangeable, a fair mix of cold and warm.
- `conf`: file order — the first entry of a same-server pair absorbs the
  wake-up. A deliberate cold probe, and the way to reproduce v2.2-era
  campaigns.
- `v4-first` / `v6-first`: family blocks — each family cooled ~half a
  round, symmetric and deterministic. The right tool for comparing
  families at equal thermal conditions.
- A tight two-entry conf is a warm probe; add `--gap 300` for a
  symmetric cold one.

### Accuracy planes

The default measurement takes `t1` in user space, after the scheduler has
woken the probe up. That wake-up is 5–30 µs on an idle machine and
hundreds of µs under load — the same size as the effects we were chasing.
Three flags move the measurement to a better plane. All were ranked
against each other in an interleaved option matrix on the macOS client
against a container resolver answering in ~0.4 ms.

**`--kts`** — kernel RX timestamps: `t1` is stamped by the kernel when the
packet enters the network stack (`SO_TIMESTAMP_MONOTONIC` on Darwin,
`SO_TIMESTAMPNS` on Linux, control message parsed by hand), so the
scheduler wake-up and the batch bias of parallel mode leave the
measurement entirely. Measured: −30 µs at p50, −70 µs at p90, tighter
std. It is our reference plane for accuracy. Honest limits: RX only — the
send-side entry cost stays in the number (see `--spin` for how much that
is); on Linux the probe clock switches to `CLOCK_REALTIME` to share the
kernel's domain (NTP slew ≤ 0.5 µs per ms of RTT — do not *step* the clock
mid-run); on macOS the stamp lives in the same Mach domain as the default
clock and the timebase conversion is self-checked on the first packet.

**`--spin`** — busy-wait on a non-blocking `recv()` instead of sleeping:
no wake-up at all, at the cost of one core at 100 %. Sequential only (it
forces it). Measured on the same target: p50 0.492 → 0.366 ms (−126 µs),
p90 −157 µs, min −30 to −47 µs. The instructive part: `--spin` beat
`--kts` at p50 although `--kts` stamps in the kernel. The explanation is
that spinning also keeps the *send* side hot — an active P-core, no
frequency ramp, warm caches and policy state at `send()` — and `--kts`
by definition removes none of that. That is how we learned that sending
from a sleeping core costs ~30–50 µs, and why the two flags are
complementary rather than redundant.

**`--rt`** — best-effort latency hints. Darwin: QoS user-interactive plus
a Mach time-constraint thread policy (300 µs period, 50 µs computation —
the class audio threads use). Linux: `SCHED_FIFO` priority 10, `mlockall`,
and `SO_BUSY_POLL` 50 µs on every socket (needs root or `CAP_SYS_NICE`;
degrades silently otherwise). Measured: the median did not move (it even
gained 30 µs once) but the standard deviation dropped by ~1.5× (0.257 →
0.164 ms). `--rt` is a variance killer, not a floor — what you want for
campaigns that must be reproducible week after week.

**`--pin N`** — Linux only: pin the process to one CPU (`sched_setaffinity`).
`SCHED_FIFO` alone still lets the probe migrate between cores; pinned, it
keeps its caches. Our reference series on the hypervisor nodes runs
`--pin 2`. Ignored on macOS with a message (affinity is advisory there).

One caveat that saved us time: on VM-hosted resolvers answering in
1.2–1.7 ms, none of these planes made any visible difference — the
hypervisor path dominates everything. Accuracy planes matter when the
resolver answers in 100–400 µs; below that, spend the effort on the
resolver instead.

### Protocol realism

**`--edns`** (conf: `edns`) — add an EDNS0 OPT record (UDP buffer 1232),
like every modern stub does. Measured cost versus bare queries: +80 to
+140 µs on LAN targets, +250 to +500 µs on WAN. The latency a real client
experiences is closer to the `--edns` number than to the bare one; keep
that in mind when quoting figures. Off by default so runs stay comparable
with earlier campaigns.

### Output

**`--sort KEY`** — `min|p50|p90|p99|p999|max|mean`: orders each table
fastest-first and drives the `vs` column (ratio to the fastest resolver on
that metric). Default p50 — read percentiles, not means.

**`--html FILE`** — a self-contained report (inline CSS/SVG, no network):
per-resolver percentile tables, one CDF chart per phase overlaying every
resolver (X log-scaled, v4 solid, v6 dashed), and the anomalies
breakdown. We needed the CDF the day a resolver's latency turned out
bimodal: a mean hides it, a percentile table half-hides it, a step in the
curve shows it.

**`-v` / `--verbose`** — echo the parsed resolver addresses at startup.
This replaces v1's forked "debug" source file, which `make debug` used to
compile over the release binary.

**`--version`** — and the run header says the rest: version, panel size,
rounds, mode, active planes (`(spin)`, `(kts)`), visit order or family
filter, timeout, gap, clock cost and resolution. After a 33-run campaign
in which we had to reconstruct which run carried which flags, every
results file now identifies itself.

### Configuration keys

| Key | Role | CLI equivalent |
|---|---|---|
| `rounds` | measurements per resolver and per mode | `--rounds` |
| `timeout_sec` / `timeout_ms` | receive timeout (`timeout_ms` wins if both) | `--timeout-ms` |
| `gap_ms` | pacing between queries / phases | `--gap` |
| `edns` | `yes` to add an OPT record | `--edns` |
| `qtype` | global query type | `--qtype` |
| `mode` | `hit`, `miss` or `both` | `--mode` |
| `parallel` | `yes` for poll-based fan-out | `--parallel` / `--no-parallel` |
| `[hit_domains]` | one `name [qtype]` per line, rotated round-robin; prefer long TTLs | — |
| `miss_base` | zone under which the random MISS label is prefixed | — |
| `[resolvers]` | one `address name` per line, v4 and v6 mixed freely | `-4` / `-6` filter |

### Recipes

    ./dnsbench --rounds 20                              # smoke test
    ./dnsbench --sort p50 --html report.html            # choose resolvers for a fleet
    ./dnsbench --rounds 10000 --sort p99                # citable p99
    ./dnsbench --mode hit --parallel --gap 5            # public resolvers, rate-limit friendly
    ./dnsbench --kts --spin                             # macOS: accuracy + instrument floor
    ./dnsbench --rounds 5000 --kts --rt --spin --pin 2  # Linux node: our reference series
    ./dnsbench -c pair.conf --gap 300 --rounds 500      # symmetric cold probe (two-entry conf)
    ./dnsbench --order v4-first ; ./dnsbench --order v6-first   # families at equal thermal state
    ./dnsbench --fixed-order                            # reproduce a v2.2-era campaign

When comparing two settings, run them ABAB — never AAAA then BBBB — and
call the difference real only when |Δp50| exceeds the spread between
repetitions on both sides. That rule killed a plausible storage
"optimization" that was pure tail variance; it will kill yours too.

### What a run looks like

Excerpt of a 5000-round reference run from one of our hypervisor nodes
(`--kts --rt --spin --pin 2`; the MISS base is redacted):

    dnsbench v2.3 - 12 resolvers, 5000 rounds/mode, mode=both (spin) (kts), timeout 1000 ms, 3 hit domain(s), default qtype=A, vs/sort=p50
    clock: ~17 ns/call, resolution 10 ns
    MISS=<rand>.example.com

    === cache-HIT (ms) ===
    resolver        n      fail  err   min       p50       p90       p99       p99.9     max       mean      std       vs
    phebe2          5000   0     0     0.052     0.190     0.240     0.333     2.597     195.440   0.276     3.735     1.00x
    phebe2-v6       5000   0     0     0.054     0.191     0.240     0.337     1.249     6.186     0.189     0.112     1.00x
    phebe3          5000   0     0     0.155     0.408     0.452     0.492     0.555     519.494   0.503     7.343     2.14x
    phebe3-v6       5000   0     0     0.180     0.424     0.458     0.499     0.750     485.361   0.590     8.957     2.23x
    phebe1          5000   0     0     0.322     1.434     2.043     2.703     4.802     8.881     1.413     0.538     7.52x
    cloudflare-v6   5000   0     0     8.347     9.523     10.186    12.043    16.051    22.205    9.590     0.699     49.93x
    google          5000   0     0     7.556     9.229     18.613    28.101    32.787    63.020    11.965    4.888     48.39x

    === anomalies (excluded from samples) ===
    phebe4          HIT: 1 timeout  |  MISS: 1 timeout
    google-v6       MISS: 2 timeout

Read it the way we do: phebe2 and phebe3 are two identical containers on
two different nodes — same software, 0.19 vs 0.41 ms, and that gap was the
start of a whole investigation. The `max` column on phebe2 (195 ms) is one
event in 5000; `std` reports it, `p99` does not care. The anomalies
section is the whole error story: 0 REFUSED, 0 SERVFAIL, four timeouts in
120 000 queries.

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
