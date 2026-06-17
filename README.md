# dnsbench

A **sub-millisecond** DNS latency probe, cross-platform (macOS + Linux), written
in Swift with zero dependencies. It measures the **application-level RTT** of a
DNS query - exactly what a client experiences - separating **cache-HIT** from
**cache-MISS**, reports **exact percentiles** plus a ratio to the fastest, and
emits a standalone **HTML report** with overlaid distribution curves.

It exists because existing tools don't go low enough. `dig` reports `Query time`
in whole milliseconds (useless on a 10G LAN where a warm lookup is sub-millisecond),
and a Python script pays an interpreter overhead that dominates the signal. A
native binary brings the measurement floor down to the syscall cost (~a few µs).

## What it measures (and what it doesn't)

- **Application-level RTT** = time between `sendto()` and `recvfrom()`. It includes
  the local stack overhead (syscall, NIC, driver): deliberate, it is what a real
  client incurs, and being common to every resolver it cancels out in **relative
  comparison**.
- **cache-HIT**: pre-warmed domains, resolved hot. Cache service latency.
- **cache-MISS**: a fresh random subdomain per request, forcing a real recursion.
  The only mode where a recursive resolver and a forwarder actually differ.
- Not a throughput/load tool: closed-loop (one request in flight), so it measures
  **nominal** latency, not behaviour under saturation.

## Build

```sh
make            # optimized binary ./dnsbench
make run        # build + run with ./dnsbench.conf
make debug      # -Onone -g
```

Single file, no Foundation: only POSIX sockets and the monotonic clock. The two
cross-platform spots are isolated at the top (`Darwin`/`Glibc` shim, clock).

## Usage

First run? Create your config from the template, then edit the `[resolvers]`
section for your own setup:

```sh
cp dnsbench.conf.example dnsbench.conf
```

```sh
./dnsbench                              # uses ./dnsbench.conf
./dnsbench -c examples/public-dns.conf  # explicit config file
./dnsbench --rounds 20                  # quick smoke test
./dnsbench --qtype AAAA                 # override the global query type
./dnsbench --mode hit                   # run only HIT (or: miss | both)
./dnsbench --parallel                   # fan out one query per resolver at once
./dnsbench --sort p50                   # sort + ratio on a metric
./dnsbench --html run.html              # also write an HTML report
```

- `--sort KEY` (`min|p50|p90|p99|p999|max|mean`) orders each table fastest-first
  and drives the **`vs` column** (ratio to the fastest resolver on that metric;
  the fastest shows `1.00x`). Default metric is `p50`.
- `--mode hit|miss|both` selects the phase(s). Use `hit` for public resolvers,
  whose MISS is rate-limited and not meaningful.
- `--parallel` (config key `parallel = yes`, override with `--no-parallel`) fans
  out one query per resolver at once and collects replies with `poll()`, instead
  of the default sequential closed-loop. One request stays in flight **per
  resolver**, so each resolver's latency is unaffected; the per-round wall-clock
  drops from `sum(latencies)` to `~max(latency)`. Use it for large/slow panels
  (the public one enables it). Caveat: a parallel run isn't directly comparable
  to a sequential one (different client-side conditions) - comparison *between*
  resolvers within a single run stays valid.
- Progress is on **stderr**, time-throttled (~200 ms) with a live request count,
  fail count and **req/s** - so you see movement even when slow resolvers stall:

```sh
./dnsbench --sort p99 > run-2026-06-17.txt
```

The `--html` report is self-contained (inline CSS/SVG, no network): per-resolver
percentile tables, a p50 bar per row, and a **CDF chart per phase** overlaying
every resolver's latency distribution - X log-scaled, **v4 solid / v6 dashed**.
A curve further left is faster; percentiles read off directly.

## Comparing public resolvers

`examples/public-dns.conf` ships a ready panel (HIT-only): Cloudflare (standard /
malware / malware+adult), Google (primary + secondary), and DNS4EU (the five EU
sovereign variants from joindns4.eu - `86.54.11.{1,11,12,13,100}` with matching
`2a13:1001::86:54:11:X` IPv6), each in IPv4 and IPv6.

```sh
./dnsbench -c examples/public-dns.conf --sort p50 --html public.html
```

Public resolvers rate-limit (DNS4EU ~1000 qps/IP; Cloudflare/Google throttle
NXDOMAIN floods), which is why the panel runs HIT-only. Google has no public
filtered variant, unlike Cloudflare and DNS4EU.

## Configuration

| Key | Role |
|-----|------|
| `rounds` | Measurements per resolver and per mode |
| `timeout_sec` | Receive timeout (beyond this: FAIL) |
| `qtype` | Global default query type, `A` or `AAAA` |
| `mode` | `hit`, `miss` or `both` (CLI `--mode` overrides) |
| `parallel` | `yes` to fan out queries via `poll()` (CLI `--parallel` / `--no-parallel`) |
| `miss_base` | Base to prefix a random label onto (cache-MISS) |

Sections, one entry per line: `[hit_domains]` (`<domain> [A|AAAA]`, rotated and
aggregated per resolver) and `[resolvers]` (`<address> <name>`, v4 or v6).

### Why `miss_base` matters

The MISS prefixes a unique random label to `miss_base` so the name is never cached
and the resolver must recurse every time. Point it at a zone **you** control: you
own the authority, the NXDOMAIN is fast and constant, and you measure your
resolver's recursion path rather than a third party's variability. After the first
query the resolver caches the delegation, so subsequent misses mostly measure the
final hop to your authority - representative of production.

## Clock

`CLOCK_MONOTONIC_RAW` (Linux) / `CLOCK_UPTIME_RAW` (Darwin): monotonic, **not
NTP/adjtime-disciplined**. On startup it prints the **amortized cost** of one
timestamp call and the **effective resolution** (smallest strictly-positive delta),
both in ns - tens of ns against millisecond RTTs, so the instrument is orders of
magnitude finer than the phenomenon.

## Reading the results

Two tables (HIT/MISS) in ms (µs precision): `n`, `fail`, `min / p50 / p90 / p99 /
p99.9 / max / mean / std`, and `vs` (ratio to the fastest). Read the percentiles,
not the mean. A resolver with `n=0, fail=<rounds>` was unreachable over that
transport - a useful connectivity check in its own right.

## Methodology

- **Interleaving**: resolvers swept round-robin each round, spreading system noise.
- **Parallel mode**: optional fan-out/fan-in over `poll()`; one query in flight per
  resolver (no on-resolver contention), wall-clock per round ~ the slowest reply.
- **Pairing**: replies checked against their transaction ID; mismatches discarded.
- **Deterministic MISS**: prefer a `miss_base` whose authority you control.

### Reading the distribution curves (threshold effects)

Steps in a CDF mean a **multimodal** latency: a flat plateau is a latency band
with almost no samples (a gap between modes), a steep rise is a mode. Common
causes on public resolvers: anycast/multi-POP variance (a fast nearby instance vs
an occasional slow path), cache tiers (edge hit vs core recursion), and aggressive
negative caching (RFC 8198 NSEC) on signed zones, where a fraction of random-label
MISS are answered from cached NSEC without reaching the authority. A tight,
unimodal curve (typical of a local recursive resolver hitting one authority)
indicates a single deterministic path.

## License

MIT - see [LICENSE](LICENSE).
