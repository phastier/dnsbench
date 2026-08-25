# The investigation behind dnsbench v2

dnsbench v2 was not designed on a whiteboard. It came out of a ten-day
investigation on a real fleet — two Proxmox nodes, two macOS hypervisor
hosts, four internal resolvers (Technitium in LXC containers, Pi-hole in
VMs, each fronting a local unbound), a 10 GbE LAN — during which almost
every initial hypothesis we held was falsified by measurement, in public,
one test at a time. The tool is what survived. This document is the honest
record: four findings, the wrong turns between them, and the method that
kept us honest. Names like phebe (resolvers) and pve1/pve2 (nodes) are our
real machines; addresses have been replaced with documentation ranges.

## 1. The cascade bug, caught in the act

dnsbench v1 used the classic probe loop: send a query, block on recv with
a timeout, match the transaction ID. It has a latent failure mode: when a
reply arrives *just after* the timeout fires, it stays queued in the
socket. The next round reads the stale reply, mismatches the TXID, counts
a failure — and its own reply arrives late in turn. The loop never
resynchronizes until a packet is genuinely lost.

We caught it live, at scale, during an interleaved v1/v2 campaign (33 runs,
2.5 M queries in one night). Three v1 runs were poisoned: 791, then 2 590,
then 28 430 false failures on a 10 000-round run — one WAN resolver lost
75 % of its rounds while the v2 runs, same panel, same night, recorded 1
to 5. The failure column of every v1-era benchmark on WAN targets was
untrustworthy, and nobody could have known without the A/B.

v2's fix is narrow by design: late datagrams are drained until match or
deadline; the happy path — one send, one blocking recv — is byte-identical.
v2 also stopped counting SERVFAIL/REFUSED as latency samples: they are
accounted separately, per RCODE, in an anomalies report. An error is not a
number; mixing them poisons percentiles.

## 2. The unconnected-UDP tax on macOS

The v1/v2 equivalence campaign was supposed to show sub-microsecond
differences (v2 uses connected sockets: send/recv instead of
sendto/recvfrom). Instead, v2 came out ~0.15 ms faster — minimum included —
on every LAN target, reproducibly across five interleaved repetitions.
That is a hundred times the syscall-mechanics expectation.

Our hypothesis: NECP, the per-datagram policy evaluation that macOS
performs for network extensions on *unconnected* sends, evaluated once per
flow on connected sockets. The bench Mac, like every Mac in this fleet,
runs a network-extension stack (management/security filters). We
registered a falsifiable prediction before testing: on Linux, the v1/v2
gap must collapse to microseconds. It did — Δ(v1, v2) = −1 to −13 µs
across two nodes and all container targets.

Practical consequence for anyone shipping macOS software that talks UDP:
**connect() your sockets**. On a managed Mac, every unconnected sendto
pays the policy walk; a connected flow pays it once. Honest caveat: our
fleet has the NE stack everywhere, so we attribute the tax to "macOS with
NE filters present" — isolating base-macOS from the filters requires a
control machine without them, which is on our roadmap. The claim as stated
is what we measured.

## 3. "The first of the pair pays" — the IPv4 penalty that wasn't

For days, our data showed IPv4 consistently slower than IPv6 on the same
LAN targets: +67 to +191 µs on container resolvers, +410 to +499 µs on VM
resolvers, from every client, under every option. We burned four
hypotheses trying to explain it — proxy-ARP hairpinning (killed by
TTL/MAC evidence), the macOS client stack (killed by Linux clients showing
the same penalty), a host cleanup that seemed to remove it (killed by
better-controlled runs), and the address family itself.

The tell was hidden in plain sight: in isolated two-entry tests the
penalty was exactly zero, and in full-panel rotation it always landed on
whichever family was listed *first* in the configuration. In rotation, a
resolver cools for ~300 ms between visits — C-state entry for containers,
vCPU descheduling for VMs. The first query of an adjacent same-server pair
pays the wake-up; the second rides a warm server one millisecond later.

We falsified it properly: an inverted configuration (v6 listed first)
flipped the penalty's sign on all four pairs (+401/+159/+120/+479 µs
became −468/−168/−131/−594) while preserving the per-server hierarchy.
Not a protocol effect. A visit-order effect.

This is not just a benchmark artifact. Real stubs send A and AAAA
back-to-back to the same resolver: the first query of every client burst
pays this wake-up in production too — at ~2 queries/second per resolver,
inter-query gaps exceed 300 ms routinely. So v2.3 treats cold and warm as
two first-class quantities: the default shuffles visit order every round
(entries sharing a server become exchangeable), `--order conf` turns the
old behaviour into a deliberate cold probe, `--order v4-first/v6-first`
gives each family a symmetric half-round cooldown, and a tight pair with
`--gap 300` becomes a symmetric cold probe. The instrument now states
which thermal state it samples, instead of letting file order decide
silently.

## 4. The wake-up that survived the hardware

That left ~350 µs of cold wake-up on container resolvers (~450-600 on
VMs). We executed four hardware levers with reversible A/B tests and
before/after probes: deep C-states (worth 20–26 µs), CPU frequency
ramp-up (6–28 µs), PCIe ASPM (nothing sleeping — disabled end-to-end on
inventory), NIC interrupt coalescing (zero effect on an isolated packet;
aggressive settings *doubled* warm latency under load, vindicating the
driver default). Total addressable by hardware: ~50 µs, each bought with
permanent watts. We declined all of them, with the numbers on file.

An ICMP control then acquitted the kernel: echo served by the container's
network stack shows +10–18 µs cold, no more. The remaining ~335 µs live in
userspace. Scheduler tracing split it further: wake-to-run delays are
3–5 µs median across 10–12 thread hops per request (the managed runtime's
socket engine, worker pool, and the server's internal queue), leaving
~250–300 µs of *execution on cold caches* — the price floor of a managed
pipeline waking up. One free lever fell out of the analysis:
`DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1` removes one thread hop
and returned a confirmed −32 to −45 µs, warm path intact. The rest is
architecture, not configuration: the honest choices are a keep-warm probe
(a local query every ~200 ms keeps threads and caches hot for negligible
cost) or documented acceptance.

The pattern across the whole investigation is worth stating plainly:
every real effect we found was software — a policy layer, a visit order, a
runtime pipeline. The hardware was innocent everywhere we accused it.

## 5. Method, or why the tool looks the way it does

- **Interleave everything.** v1/v2 ran ABAB; option matrices ran
  round-robin per repetition. Slow drift then hits all arms equally.
- **Decision rule before the data.** An effect is real when |Δp50| exceeds
  the inter-repetition spread on both sides. This rule killed a plausible
  ZFS "optimization" that was pure tail variance, and it will kill yours.
- **Register predictions, then try to kill them.** The NECP claim survived
  a cross-OS falsification attempt; the IPv4 claim did not survive an
  order swap. Both outcomes are progress.
- **Diagnose in layers.** ICMP (kernel, bypasses flow filters), UDP echo
  (kernel flow path), DNS (the full service): three probes that pin a cost
  to a layer in minutes.
- **Know your statistics.** At n=2000, p50/p90 are solid, p99 rests on
  ~20 tail samples, p99.9 on two. A single ARP refresh moves p99.9 by 3×.
  Use 10 000 rounds for a citable p99; treat p99.9 as decoration.
- **Know your measurement plane.** Sleepy user-space (±300 µs of your own
  wake-up), busy-wait (`--spin`), kernel RX timestamps (`--kts`), and —
  the rung above, on our roadmap — NIC hardware timestamps (PHC), which
  need no PTP for round-trip measurements: TX and RX stamps live on the
  same clock. Every historical tool sits somewhere on this ladder; the
  failure of ping is not being old, it is not announcing its rung. On
  macOS the kernel-timestamp rung is the ceiling: no userland access to
  hardware stamps exists.

If you see a flaw in any of this, open an issue. Being wrong quickly and
in public is the entire operating principle here — it is how the tool got
every feature it has.
