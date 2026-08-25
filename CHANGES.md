*Engineering log of the v2 rewrite, version by version. The narrative
deep-dive — findings, wrong turns, method — is
[docs/INVESTIGATION.md](docs/INVESTIGATION.md).*

# dnsbench v2 — deltas vs v1

Rewritten in a separate tree, without touching v1. Still a single source
file, still zero dependencies (POSIX + a monotonic clock, no Foundation).
The v1 configuration format is read as-is; our internal `dnsbench.conf`
is a verbatim copy of the v1 one, so that v1/v2 comparisons run on
strictly identical panels.

## v2.1 — anomaly reporting

`fail` and `err` remain the aggregated table columns, but each accumulator
now breaks down timeouts, network errors (ICMP unreachable, failed sends)
and invalid RCODEs by value (FORMERR, SERVFAIL, NOTIMP, REFUSED, RCODEn).
New "anomalies" section at the end of the console output — only the
resolvers concerned appear, otherwise an explicit "no anomalies" line —
an equivalent section in the HTML report, tooltips on the fail/err cells
(hover = breakdown), and a contextual note when REFUSED shows up (the
typical signature of Pi-hole's FTL rate limiter, with a `--gap`
suggestion). Pure classification: the measurement paths are strictly
identical to 2.0, so 2.0 and 2.1 runs stay comparable on every column.

## v2.2 — instrument floor (--kts, richer --rt, --pin)

**`--kts`, kernel RX timestamps.** The accuracy lever: t1 becomes the
timestamp the kernel stamps as the packet enters the network stack, via
`recvmsg` and a hand-parsed control message (the `CMSG_*` macros do not
exist in Swift). The scheduler wake-up (5–30 µs of variance) and the
residual batch bias of parallel mode leave the measurement entirely — the
Fisher-Yates shuffle becomes belt-and-braces. Darwin:
`SCM_TIMESTAMP_MONOTONIC`, same Mach domain as `CLOCK_UPTIME_RAW`,
timebase conversion self-checked on the first stamp (ticks-vs-ns
detection, clean disable on domain mismatch). Linux: `SO_TIMESTAMPNS` in
`CLOCK_REALTIME` — under kts, t0 and the deadlines move to that domain
(NTP slew ≤ 0.5 µs per ms of RTT; do not step the clock mid-run). RX
only: the send-side entry cost (~0.5–1 µs) stays in the number, accepted
and documented. Default OFF: without `--kts`, the probe path is
byte-for-byte identical to 2.1.

**Richer `--rt`.** Darwin: on top of the QoS class, the thread joins the
time-constraint class (300 µs period, 50 µs computation) — the real
wake-up latency lever on macOS, the one audio threads use. Linux:
`SO_BUSY_POLL` 50 µs per socket (the kernel polls the NIC queue before
sleeping, short-circuiting the IRQ wake-up; driver- and
privilege-dependent, silent degradation otherwise).

**`--pin N` (Linux).** Pin the process to one core via
`sched_setaffinity` (`cpu_set_t` manipulated as raw bytes, the `CPU_SET`
macros being un-importable). Combined with `SCHED_FIFO`: no migration,
warm caches. No effect on Darwin (affinity is advisory only), explicit
message.

Recommended use on fast infrastructure (resolvers answering in 10–50 µs):
`--kts --rt` (plus `--pin` on Linux) as the reference plane, `--spin` as
a second plane for the pure instrument floor. Everything OFF by default:
2.0/2.1/2.2 runs without flags remain comparable.

## v2.3 — randomized visit order ("the first of the pair pays")

Investigation closed on 17 August by attempted falsification (the
swap-test): in sequential rotation, a server cools for ~300 ms between
two visits; the first entry of a same-server pair absorbs its wake-up
(125–215 µs on containers, 400–590 µs on VMs), the second one rides a
warm server. The historical "IPv4 penalty" was nothing but the
configuration order (v4 listed first): with the configuration inverted,
the penalty switches sides, sign and magnitude included.

v2.3 makes entries exchangeable: the visit order is shuffled every round
in sequential mode, the send order every phase in parallel mode
(Fisher-Yates, same PRNG). `--fixed-order` restores the v2.2
configuration order — to reproduce earlier campaigns, and as a deliberate
cold probe (the first of a same-server pair then measures the wake-up).
Both quantities are real: cold = the first query of a client burst (the
stub sends A and AAAA a few µs apart — the first of every real burst pays
this wake-up); warm = steady state, measurable in a tight pair. The v2.3
default samples a fair mix. Note: in `both` mode, the MISS always follows
the HIT of the same visit — so the MISS has always been "warm" by
construction (except in miss-only mode).

Re-reading the v2.0–v2.2 campaigns: the RTT columns remain valid; only
comparisons between entries sharing a server (v4/v6 pairs) must be
re-read as cold-vs-warm, not as a family effect.

2.3 additions: `-4` / `-6` restrict the panel to one family without
editing the configuration (replay a v4-only/v6-only test with one flag);
`--order shuffle|conf|v4-first|v6-first` drives the order — shuffle
(default, fair mix), conf (cold probe by adjacency, alias
`--fixed-order`), v4-first/v6-first (family blocks in configuration
order: each server is visited once per half-round, both families measure
a symmetric, deterministic semi-cold state — the family comparison at
equal thermal conditions, with no randomness). The header and the HTML
report identify themselves (order/family).

## Measurement validity

**Late-reply drain (the v1 cascade bug).** In sequential mode, a reply
arriving after the timeout stayed queued and made every subsequent round
fail in a chain (TXID mismatch → nil → the genuine reply queues up in
turn). `measureOnce` now drains until match or deadline, with the
remaining budget recomputed. The happy path is identical to v1 (one send
plus one blocking recv under `SO_RCVTIMEO`): the timeout is only re-armed
on the rare drain path, then restored.

**RCODE read.** QR bit checked, RCODE parsed: NOERROR and NXDOMAIN are
valid samples (NXDOMAIN is the expected MISS answer); everything else
(SERVFAIL, REFUSED, …) goes to a dedicated `err` column, its latency
excluded from the percentiles. This is what makes Pi-hole's FTL rate
limiter visible (1000 queries / 60 s / client → REFUSED): at 2000 rounds
× 2 modes in a closed loop, the v1 runs most probably tripped it without
anyone seeing it.

**TTL at warm-up.** The warm-up parses the answer section (compression
handled) and prints the minimum TTL per hit domain, with a warning below
120 s: a run longer than the TTL re-queries upstream and contaminates HIT
with disguised MISSes (the bimodality observed on www.apple.com/Akamai is
probably partly such an artifact).

**Per-batch random order in parallel mode.** After `poll()`, ready
descriptors are processed in a per-batch Fisher-Yates order instead of
configuration order — removes the systematic bias of a few µs in favour
of the first `[resolvers]` entries on a LAN.

## Latency floor

**Connected UDP sockets.** send/recv instead of sendto/recvfrom (no
address copy per call, a marginally shorter happy path than v1), kernel
filtering of foreign datagrams, and ICMP surfacing: a resolver that is
down costs an immediate ECONNREFUSED instead of rounds × timeout.

**Zero-allocation hot path.** Prebuilt query templates (one per hit
domain plus one MISS), TXID patched over 2 bytes, fixed-width 12-hex MISS
label (48 bits, offset 13) patched in place — `send()` copies into the
kernel, so a single buffer serves everything, including parallel mode
where the scratch arrays (ids, t0, pfds, order, results) are preallocated
once. xorshift64* PRNG instead of `SystemRandomNumberGenerator` (a
possible `getrandom(2)` per draw on Linux). `reserveCapacity(rounds)` on
the samples. `recvBuf` raised to 2048 (EDNS0).

**`--spin` (sequential only).** Non-blocking recv in a busy loop: removes
the scheduler wake-up (5–30 µs plus variance) from the measurement, at
the cost of one core at 100 %. A second measurement plane (instrument
floor), not a replacement for the default mode. If parallel is active,
`--spin` forces sequential with a message.

**`--rt` (best-effort).** Darwin: user-interactive QoS (favours the
P-cores on Apple silicon). Linux: attempted `SCHED_FIFO` priority 10 plus
`mlockall`, silent degradation without privileges. Off by default to stay
comparable with v1.

## Robustness & portability

EINTR retried everywhere (recv, poll — v1's `rc <= 0 → break` in
`fanPhase` sacrificed the whole batch on a mere signal).
POLLERR/POLLHUP/POLLNVAL handled in parallel mode (ICMP → immediate
fail). Socket/connect failure → warning and the resolver is skipped
cleanly (v1 pushed a -1 fd). DNS name validation at startup (labels ≤ 63,
total ≤ 254) — `buildQuery` stays trap-free. The `canImport(Musl)` shim
follows the form validated by v1's arm64 musl build (`SOCK_DGRAM`
imported directly as Int32, no cast). Minimal `Package.swift` and the
`make linux-arm64` / `linux-amd64` targets carried over from v1 (Swift
Static Linux SDK 6.3.3, static musl binaries in `dist/`, zero dependency
on the target); `make static-stdlib` remains available for a native glibc
build. The forked `dnsbench-debug.swift` is gone: `-v/--verbose` brings
back the echo of parsed addresses, and `make debug` produces
`dnsbench-debug` without overwriting the release binary any more.

## New options

`timeout_ms` (configuration, takes precedence over `timeout_sec`) and
`--timeout-ms`; `gap_ms` / `--gap` (pacing: sleep between queries in
sequential mode, between phases in parallel mode); `edns` / `--edns` (OPT
bufsize 1232); strict extended qtype — A, AAAA, HTTPS, TXT or numeric; an
unknown value is refused instead of being silently mapped to A as in v1;
`--version`. VERSION is printed in the header, the HTML report and
`--version`, so results files identify themselves.

## To validate at first compilation (historical — since validated)

v1's arm64 musl build (Swift Static Linux SDK 6.3.3) empirically
validates the Musl shim and every POSIX pattern shared with v2
(`Int16(POLLIN)`, `nfds_t`, `timeval` via `.init()`, `fcntl`,
`getaddrinfo`, `poll`, `mode_t`). Left to validate: the
`sched_param.sched_priority` field as imported by Swift on the Glibc side
in `applyRuntimeHints` (only used with `--rt`; under musl,
`sched_setscheduler` returns ENOSYS by design — the best-effort fallback
applies and the message says so), and v2's new paths (drain, rewritten
`fanPhase`, TTL warm-up, EDNS) which had never been compiled anywhere
yet. 2.2 adds its own points to check at first build: import of the
`SO_TIMESTAMP_MONOTONIC` / `SCM_TIMESTAMP_MONOTONIC` constants and of the
Mach `thread_policy_set` / `thread_time_constraint_policy_data_t` API on
Darwin; import of `SO_TIMESTAMPNS` / `SCM_TIMESTAMPNS` and `SO_BUSY_POLL`
on Linux (glibc and musl); the `msghdr` field types (`msg_iovlen`,
`msg_controllen`) absorbed by `numericCast`. Should compilation fail,
everything is localized in `recvWithTS`, `applyRuntimeHints` and the
`--pin` block. (All of it has since compiled and run on macOS, Linux
glibc and Linux musl, amd64 and arm64.)

## v1/v2 comparison protocol

Same host, same configuration (verbatim copy included), back-to-back
runs, sequential, `--sort p50`. The RTT columns (min/p50/p90/p99/…) are
comparable; `n`, `fail` and `err` are not, by construction: v2 recovers
samples v1 lost (drain) and demotes to `err` replies v1 counted as
successes (RCODE). A non-zero `err` on the Pi-hole targets in v2 will
mean the v1 runs were partly measuring the FTL rate limiter. For a clean
comparison of the cache itself, `--gap 5` keeps ~2000 queries / 60 s
spread over the panel, below the FTL threshold per phase. The v2 happy
path (connected send/recv) is structurally shorter than v1's
(sendto/recvfrom) by a fraction of a µs — expected, it is one of the
goals. The same protocol applies on Linux targets with the `dist/`
binaries (v1 arm64 already produced, v2 via `make linux-arm64`).

## Deferred (v2.x)

`--json`/`--csv` output, then a Prometheus textfile collector; `--bind`.
DoT/DoH: non-goal (zero dependencies). Deliberately set aside: io_uring
SQPOLL (a Linux-only architecture change for 1–2 µs already below the
`--kts` floor), TX timestamps (`MSG_ERRQUEUE`, disproportionate
complexity for ~1 µs on the send side), `PR_SET_TIMERSLACK` (`prctl` is
variadic in C, uncallable from Swift).
