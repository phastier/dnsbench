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

## v2.4 — machine-readable output (--json, --csv)

The campaign runners rebuilt a `summary.csv` by scraping the console
tables with awk — column positions, an `err` column that v1 did not
have. The instrument now writes its results itself.

**`--json FILE`.** The whole run as one document, under a versioned
schema (`"schema": 1`): tool version, `--label`, UTC start time, elapsed
time, every option that shapes the measurement (rounds, mode, parallel,
timeout, gap, EDNS, qtype, order, family, spin/rt/kts/pin, the `vs`
metric), the hit domains with their effective qtype, the MISS base, the
clock calibration, then one object per resolver — name, address, family —
with a `hit` and/or `miss` phase: `n`, `fail`, `err`, the anomaly
breakdown (`timeouts`, `net_errors`, `rcodes` by name), the statistics
of the console and `vs`. Durations are integer
nanoseconds (`"unit": "ns"`), not rounded to the console's microsecond;
statistics are `null` when a phase collected no sample, where the console
prints 0.000. `kts` reports the plane actually in effect (it can
self-disable), `pin` is `null` on Darwin where the flag is ignored.
Resolvers come in configuration order, whatever `--sort` says.

**`--samples`.** Adds every raw sample to the JSON, in measurement order
(failed queries are not in the series): a distribution can be re-plotted,
and the time structure of a run is no longer lost in the percentiles.

**`--csv FILE`.** The two console tables, same columns, same formatting
(ms), one row per resolver and mode, in console order: `run, mode,
resolver, n, fail, err, min, p50, p90, p99, p999, max, mean, std, vs` —
the layout of the scraped `summary.csv`, so earlier campaign files and
new ones concatenate. `run` is the `--label`, or the UTC start time when
none is given: every row says which run it belongs to. RFC 4180 quoting
where a field needs it.

**`--label TEXT`.** Names the run (JSON `label`, CSV `run`).

`-` as FILE writes to stdout; the console report then moves to stderr,
so `dnsbench --json - | jq` is a clean pipe (one of `--json` / `--csv`
at a time). Hand-written serializers, no Foundation. Pure output: the
measurement paths are those of 2.3.

## v2.5 — DNS over TCP

A `[resolvers]` address can now carry a scheme: `tcp://ADDR[:PORT]`
selects TCP, `udp://ADDR[:PORT]` is UDP with a port (IPv6 literals in
brackets). A bare address stays what it always was — UDP, port 53. Any
other scheme is refused with a warning rather than probed over UDP.
`--tcp` runs a whole panel over TCP without editing the configuration.
Listing a server as both `ADDR` and `tcp://ADDR` puts its two transports
in the same rotation.

**Two samples, because a client can experience two things.** *Warm*
(default): one persistent connection per resolver (RFC 7766), the sample
is send → complete reply — the same window as UDP. *Cold*
(`--reconnect`): a new connection per query, `t0` taken before
`connect()` — handshake plus query, what a stub falling back from a
truncated UDP answer pays. Cold forces sequential mode, with a message,
like `--spin`.

**The path.** One `sendmsg()` carries the two-byte length prefix and the
shared datagram template (two iovecs, one segment, `TCP_NODELAY`): no
second template set, and the hot path still allocates nothing. Replies
are reassembled across segments in a per-resolver buffer sized for the
largest DNS message. Blocking sockets keep the UDP happy path — one
send, one recv under `SO_RCVTIMEO`, re-armed only when a reply arrives
in pieces; `--spin` busy-waits on a non-blocking socket as on UDP;
`--parallel` reassembles on `POLLIN`. `connect()` is non-blocking and
bounded by the configured timeout: a filtered port costs the timeout,
not the OS default. No SIGPIPE (`SO_NOSIGPIPE` on Darwin, `MSG_NOSIGNAL`
on Linux).

**Server-side closes.** A server may close a connection whenever it
likes, and a client can live two different things. *Idle close*: before
every `t0`, a non-blocking peek tells whether the server closed; the
connection is then reopened *outside* the timed window and counted (JSON
`reconnects`) — the sample is kept, it simply rode a new connection.
*Close with the query in flight*: the peek cannot be airtight (a close
can cross the query on the wire, and some servers close on receipt), so
the probe does what RFC 7766 §6.2.4 asks of a client — it connects again
and repeats the query, once, inside the same timed window and the same
timeout budget. That sample spans the lost attempt, the handshake and
the answer; the query is counted `retried` (JSON, per phase). Only a
second close on the same query is a `fail`, of a new kind next to
timeouts and network errors: `closed`. Each kind of event gets its
console note and its HTML note, per resolver. In parallel mode the retry
is a small state machine inside the fan-out — non-blocking redial, the
query again on writability — so that no handshake ever blocks the batch;
a repeated MISS query carries a fresh random label. A server that
refuses or filters TCP stays in the panel and fails every round — the
connectivity check the tables already gave for UDP.

**Late replies.** A reply landing after its timeout stays in the stream;
the next exchange drops every complete message that does not answer the
current query, including one the timeout cut in half — the stream
equivalent of the datagram drain, with the same guarantee: no cascade.

**Accuracy planes.** `--spin` and `--rt` apply. `--kts` does not: kernel
RX timestamps are enabled on datagram sockets only, TCP samples take
`t1` in user space, and a note says so when both are present — do not
compare a `--kts` UDP row with a TCP row at the microsecond level.

**Datagram path.** `measureOnce`, `recvWithTS` and the warm-up probe are
untouched; in sequential mode the transport is chosen before `t0`. In
parallel mode the fan-out tests the entry's transport once before `t0`
and once per ready descriptor.

**Output.** The JSON gains `transport` and `port` on every resolver,
`reconnects` on TCP ones, `closed` and `retried` in each phase, `tcp`
and `reconnect` among the options. Additions only: the schema number
stays 1, 2.4 having never been published on its own. The console and
HTML anomaly lines gain `closed`; the CSV columns do not change (`fail`
includes it).

**Configuration file.** The example file shipped with 2.3 placed
`miss_base` after `[hit_domains]`. A section ran to the next one
whatever it held, so that line was read as a hit domain named
`miss_base` — queried one round in three — and the MISS base silently
kept its default, which happened to be the example's own value. The
example now keeps every setting above the first section, and the parser
reads a known setting as a setting wherever it sits, with a message
asking to move it. If your configuration was copied from the 2.3
example, its `miss_base` only takes effect from this version on.

Validation: a loopback mock server with one failure mode per port
(reply in three segments, close after every reply, close without
answering every fifth query, close on every query, close on every other
connection, reply after the timeout, half a reply then the rest after
the timeout, a stale message before every reply, a 4.8 kB answer,
REFUSED, no listener), in sequential, `--spin`, `--parallel` and
`--reconnect` modes, on macOS and on Linux amd64 (static musl build):
the probe's counters — samples, repeated queries, reopened connections,
`closed` — match the server's connection and query counts exactly.
Datagram path against 2.3, same Linux node, same panel, reference plane,
ABAB: p50 differences on the fast LAN resolvers between −24 and +10 µs,
inside the spread between repetitions (100–150 rounds: a smoke test, not
a campaign).

First campaign on real resolvers, same Linux node: five LAN resolvers,
each over UDP and over TCP, IPv4 then IPv6, warm then cold, 5000 rounds
per mode with `--rt --spin --pin` — 400 000 queries, every run exit 0.
Two of the resolvers close a TCP connection after 100 queries: 100
closes per TCP entry and per warm run over 10 003 queries, 85 to 94
found idle and reopened before `t0`, 6 to 15 with the query in flight
and repeated, no `closed` failure. The only failures of the campaign
(15, UDP and TCP alike) fall in the four seconds during which one
resolver's service was restarted by hand; they are reported as timeouts
and network errors. The cold figures were cross-checked with an
independent socket client timing `connect()` and the query separately.
The results are under *Transport* in the README.

The arm64 build had not been run when 2.5.0 was tagged; it has been
since (see 2.5.1). The glibc build is not yet compiled.

**Build.** `make macos-arm64` builds the macOS release asset with a
pinned deployment target (`MACOS_TARGET`, macOS 26.0 by default). A
plain `make` targets the build host's OS version: fine for a local
build, wrong for a binary meant to run elsewhere.

## v2.5.1 — HTML report: colours, axis

Two defects of the report, both found on the first panels larger than
the ones it was drawn for.

**Colours.** The CDF took its colours from a list of twelve, in ranking
order. With sixteen entries four colours appeared twice, and since the
HIT and MISS rankings differ, a resolver changed colour between the two
charts of one report. A colour is now a server: entries whose names
differ only by a `-v6`, `-v4`, `-tcp` or `-udp` suffix share it, in
configuration order, identically in both charts. The line style carries
the variant — v4 solid, v6 dashed, and where a panel mixes transports,
TCP dotted (v6 over TCP dash-dot); two entries of one server that would
share both get separate colours. The palette is eight hues from the
earlier twelve, the subset and the order chosen by computation rather
than by eye: the eight that stay furthest apart pairwise, ordered so
that neighbours remain distinct under protanopia and deuteranopia (OKLab
distance at least 11 between neighbours, 20 for full colour vision), all
at 3:1 or better against the chart surface. Past eight servers a hue
would have to be reused: the panel is split into several charts on the
same axes instead, eight servers each, in configuration order. Each
curve has a hover target that names it with its p50 and p99; the legend
swatches show the line style.

**X axis.** The marks came from a fixed 1-2-5 list. A cache-MISS panel
spanning 11 to 27 ms had exactly one of them ("20"), and nothing past
200 ms. The series is now generated for the range; when fewer than four
of its marks fall inside, evenly spaced round values take over (12, 14,
… 26 in that case), and a mark whose label would touch the previous one
is dropped.

Measurement paths, console, JSON and CSV are those of 2.5.

Validation: reports rendered and read for a 16-entry panel (8 servers,
both families), a 20-entry one (5 servers, both families, both
transports), a single-transport TCP panel, and an 11-server panel (two
charts). The tick generator was checked on thirteen ranges from 0.05 ms
to 1 s.

**arm64.** The static arm64 build of 2.5.0 was run on an aarch64 Linux
node: the mock suite of the 2.5 validation (six runs) gives the same
counters as on amd64 in all 133 resolver-and-phase comparisons, the
mock server counts the same queries on every port, and the real panel
answers over UDP with `--kts`, over TCP warm, cold and in parallel —
every run exit 0, no failure.

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

A Prometheus textfile collector (`--json` and `--csv` landed in 2.4);
`--bind`; kernel RX timestamps on stream sockets (untested on either OS).
DoT and DoH: planned, on both OS families — the stream transport of 2.5
is their substrate. They were a non-goal for as long as "zero
dependencies" was absolute; they need a TLS stack, and the rule becomes:
nothing beyond one reference TLS implementation (Apple's or OpenSSL).

Deliberately set aside: io_uring SQPOLL (a Linux-only architecture
change for 1–2 µs already below the `--kts` floor), TX timestamps
(`MSG_ERRQUEUE`, disproportionate complexity for ~1 µs on the send
side), `PR_SET_TIMERSLACK` (`prctl` is variadic in C, uncallable from
Swift).
