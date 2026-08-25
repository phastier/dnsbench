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

## Statistics, honestly

At n=2000, p50 and p90 are solid; p99 rests on ~20 tail samples
(indicative); p99.9 on 2 (decorative). Use 10000 rounds for a citable p99.
Run-to-run variance exceeds within-run variance: repeat, and **interleave**
repetitions (ABAB), never group them. An effect is real when |Δp50| exceeds
the inter-repetition spread on both sides.

## Quick start

    make                       # native build
    make linux-amd64           # static musl cross-build (also: linux-arm64)
    cp dnsbench.conf.example dnsbench.conf   # edit: your resolvers, your miss_base
    ./dnsbench --sort p50 --html report.html

## Critique welcome

This tool was built by measuring, being wrong in public, and testing the
next hypothesis to destruction. If you see a flaw in the method, open an
issue. And if you run 25/40/100 GbE gear: we would love your numbers — at
those speeds the resolver answers in tens of microseconds and the
instrument's floor becomes the story.

See CHANGES.md for the full engineering log, LICENSE for terms.
