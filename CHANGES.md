*French engineering log. The English deep-dive is [docs/INVESTIGATION.md](docs/INVESTIGATION.md).*

# dnsbench v2 — deltas vs v1

Réécriture dans un répertoire séparé (`~/Dev/dnsbench-v2`), sans toucher à
`~/Dev/dnsbench`. Source unique, toujours zéro dépendance (POSIX + horloge
monotone, pas de Foundation). Le format de conf v1 est lu tel quel ;
`dnsbench.conf` est une copie verbatim de la conf interne v1 pour comparer à
panels strictement identiques.

## v2.1 — restitution des anomalies

`fail` et `err` restent les colonnes agrégées des tableaux, mais chaque Acc
ventile désormais les timeouts, les erreurs réseau (ICMP unreachable, échecs
send) et les RCODEs invalides par valeur (FORMERR, SERVFAIL, NOTIMP, REFUSED,
RCODEn). Nouvelle section « anomalies » en fin de sortie console — seuls les
résolveurs concernés apparaissent, sinon une ligne « no anomalies » explicite —
section équivalente dans le rapport HTML, tooltips sur les cellules fail/err
(survol = ventilation), et note contextuelle quand du REFUSED apparaît
(signature typique du rate-limiter FTL, suggestion --gap). Classification
pure : chemins de mesure strictement identiques à la 2.0, les runs 2.0 et 2.1
restent comparables sur toutes les colonnes.

## v2.2 — plancher instrument (--kts, --rt enrichi, --pin)

**--kts, timestamps noyau RX.** Le levier d'exactitude : t1 devient l'horodatage
posé par le noyau à l'entrée de la pile réseau, via recvmsg + cmsg parsé à la
main (les macros CMSG_* n'existent pas en Swift). Le réveil scheduler
(5–30 µs de variance) et le résidu de biais de batch du mode parallèle sortent
entièrement de la mesure — le shuffle Fisher-Yates devient ceinture-bretelles.
Darwin : SCM_TIMESTAMP_MONOTONIC, même domaine mach que CLOCK_UPTIME_RAW,
conversion timebase auto-vérifiée au premier stamp (détection ticks vs ns,
désactivation propre si mismatch de domaine). Linux : SO_TIMESTAMPNS en
CLOCK_REALTIME — sous kts, t0 et les deadlines basculent dans ce domaine
(slew NTP ≤ 0,5 µs/ms de RTT ; ne pas stepper l'horloge en cours de run).
RX uniquement : le coût d'entrée du send (~0,5–1 µs) reste dans le chiffre,
assumé et documenté. Défaut OFF : sans --kts, le chemin de sonde est
identique octet pour octet à la 2.1.

**--rt enrichi.** Darwin : en plus de la QoS, thread en classe time-constraint
(période 300 µs, calcul 50 µs) — le vrai levier de latence de réveil macOS,
celui des threads audio. Linux : SO_BUSY_POLL 50 µs par socket (le noyau
polle la queue NIC avant de dormir, court-circuite le réveil IRQ ; dépend du
driver et des privilèges, dégradation silencieuse sinon).

**--pin N (Linux).** Épinglage du process sur un cœur via sched_setaffinity
(cpu_set_t manipulé en octets bruts, les macros CPU_SET n'étant pas
importables). Combiné à SCHED_FIFO : pas de migration, caches chauds.
Sans effet sur Darwin (affinité consultative seulement), message explicite.

Usage recommandé sur infra rapide (résolveurs à 10–50 µs) : `--kts --rt`
(+ `--pin` côté Linux) comme plan de référence, `--spin` en second plan pour
le plancher instrument pur. Tout à OFF par défaut : les runs 2.0/2.1/2.2 sans
flags restent comparables.

## v2.3 — ordre de visite aléatoire (« le premier de la paire paie »)

Découverte close le 17/08 par falsification tentée (swap-test) : en rotation
séquentielle, un serveur refroidit ~300 ms entre deux visites ; la première
entrée d'une paire même-serveur encaisse son réveil (125–215 µs sur les CT,
400–590 µs sur les VMs), la seconde passe sur serveur chaud. Le « malus
v4 » historique n'était que l'ordre de la conf (v4 listé d'abord) : conf
inversée, le malus change de camp au signe et à la magnitude près.

v2.3 rend les entrées échangeables : ordre de visite mélangé à chaque round
en séquentiel, ordre d'émission mélangé par phase en parallèle (Fisher-
Yates, même PRNG). `--fixed-order` restaure l'ordre de conf v2.2 — pour
reproduire les anciennes campagnes, et comme sonde de froid délibérée (le
premier d'une paire même-serveur mesure alors le réveil). Les deux grandeurs
sont réelles : froid = première requête d'une rafale client (le stub envoie
A/AAAA à quelques µs d'écart — le premier de chaque burst réel paie ce
réveil) ; chaud = régime établi, mesurable en paire serrée. Le défaut v2.3
échantillonne un mélange équitable. Note : en mode both, le MISS suit
toujours le HIT de la même visite — le MISS a donc toujours été « chaud »
par construction (sauf en mode miss seul).

Relecture des campagnes v2.0–v2.2 : les colonnes RTT restent valides ;
seules les comparaisons entre entrées partageant un serveur (paires v4/v6)
sont à relire comme froid-vs-chaud, pas comme un effet de famille.

Compléments 2.3 : `-4` / `-6` restreignent le panel à une famille sans
éditer la conf (rejouer un test v4-only/v6-only en un flag) ; `--order
shuffle|conf|v4-first|v6-first` pilote l'ordre — shuffle (défaut,
mélange équitable), conf (sonde de froid par adjacence, alias
--fixed-order), v4-first/v6-first (blocs par famille dans l'ordre conf :
chaque serveur est visité une fois par demi-tour, les deux familles
mesurent un semi-froid symétrique et déterministe — la comparaison de
familles à conditions thermiques égales, sans aléa). Le header et le
rapport HTML s'auto-identifient (order/family).

## Validité de la mesure

**Drain des réponses tardives (bug cascade v1).** En séquentiel, une réponse
arrivée après timeout restait en file et faisait échouer toutes les rounds
suivantes en chaîne (mismatch TXID → nil → la vraie réponse s'empile à son
tour). `measureOnce` draine désormais jusqu'au match ou à l'échéance, budget
restant recalculé. Le happy path reste identique à v1 (un send + un recv
bloquant sous SO_RCVTIMEO) : le timeout n'est ré-armé que sur le chemin de
drain, rare, puis restauré.

**RCODE lu.** QR bit vérifié, RCODE parsé : NOERROR et NXDOMAIN sont des
échantillons valides (NXDOMAIN est la réponse attendue du MISS) ; tout le reste
(SERVFAIL, REFUSED, …) part dans une colonne `err` dédiée, latence exclue des
percentiles. C'est ce qui rendra visible le rate-limiter FTL des Pi-hole
(1000 req/60 s/client → REFUSED) : à 2000 rounds × 2 modes en boucle fermée,
les runs v1 le déclenchaient très probablement sans qu'on le voie.

**TTL au warm-up.** Le warm-up parse la section answer (compression gérée) et
affiche le TTL min par hit domain, avec avertissement sous 120 s : un run plus
long que le TTL ré-interroge l'amont et contamine le HIT par des MISS déguisés
(la bimodalité observée sur www.apple.com/Akamai en est probablement en partie
un artefact).

**Ordre aléatoire par batch en parallèle.** Après poll(), les fd prêts sont
traités dans un ordre Fisher-Yates par batch au lieu de l'ordre de la conf —
supprime le biais systématique de quelques µs en faveur des premières entrées
`[resolvers]` sur LAN.

## Plancher de latence

**Sockets UDP connectés.** send/recv au lieu de sendto/recvfrom (pas de copie
d'adresse par appel, happy path marginalement plus court que v1), filtrage
noyau des datagrammes étrangers, et remontée ICMP : un résolveur down coûte un
ECONNREFUSED immédiat au lieu de rounds × timeout.

**Chemin chaud zéro allocation.** Templates de requête préconstruits (un par
hit domain + un MISS), TXID patché sur 2 octets, label MISS à largeur fixe
12 hex (48 bits, offset 13) patché en place — send() copie dans le noyau, un
seul buffer sert tout, y compris en parallèle où les scratch (ids, t0, pfds,
order, results) sont préalloués une fois. PRNG xorshift64* au lieu de
SystemRandomNumberGenerator (getrandom(2) potentiel par tirage sous Linux).
reserveCapacity(rounds) sur les échantillons. recvBuf passé à 2048 (EDNS0).

**--spin (séquentiel uniquement).** recv non bloquant en busy-loop : supprime
le réveil scheduler (5–30 µs + variance) de la mesure, au prix d'un cœur à
100 %. Second plan de mesure (plancher instrument), pas un remplacement du mode
par défaut. Si parallel est actif, --spin force le séquentiel avec message.

**--rt (best-effort).** Darwin : QoS user-interactive (favorise les P-cores
Apple Silicon). Linux : tentative SCHED_FIFO prio 10 + mlockall, dégradation
silencieuse sans privilèges. Off par défaut pour rester comparable à v1.

## Robustesse & portabilité

EINTR bouclé partout (recv, poll — le `rc <= 0 → break` de fanPhase v1
sacrifiait le batch sur un simple signal). POLLERR/POLLHUP/POLLNVAL gérés en
parallèle (ICMP → fail immédiat). Échec socket/connect → warning + résolveur
sauté proprement (v1 empilait un fd -1). Validation des noms DNS au démarrage
(labels ≤ 63, total ≤ 254) — buildQuery reste trap-free. Shim
`canImport(Musl)` aligné sur la forme validée par le build musl arm64 de la v1
(SOCK_DGRAM importé directement en Int32, sans cast). Package.swift minimal et
cibles `make linux-arm64` / `linux-amd64` repris de la v1 (Swift Static Linux
SDK 6.3.3, binaires statiques musl dans dist/, zéro dépendance sur la cible) ;
`make static-stdlib` reste disponible pour un build glibc natif. Le fork
dnsbench-debug.swift disparaît : `-v/--verbose` réactive l'écho des adresses
parsées, et `make debug` produit `dnsbench-debug` sans plus écraser le binaire
release.

## Nouvelles options

`timeout_ms` (conf, prioritaire sur timeout_sec) et `--timeout-ms` ; `gap_ms` /
`--gap` (pacing : sleep entre requêtes en séquentiel, entre phases en
parallèle) ; `edns` / `--edns` (OPT bufsize 1232) ; qtype étendu strict — A,
AAAA, HTTPS, TXT ou numérique, une valeur inconnue est refusée au lieu d'être
silencieusement mappée sur A comme en v1 ; `--version`. VERSION affichée dans
le header, le rapport HTML et --version, donc les fichiers de résultats
s'auto-identifient.

## À valider à la première compilation

Le build musl arm64 de la v1 (Swift Static Linux SDK 6.3.3) valide
empiriquement le shim Musl et tous les patterns POSIX partagés avec la v2
(Int16(POLLIN), nfds_t, timeval en .init(), fcntl, getaddrinfo, poll,
mode_t). Reste à valider : le champ `sched_param.sched_priority` tel
qu'importé par Swift côté Glibc dans `applyRuntimeHints` (utilisé seulement
avec --rt ; sous musl, sched_setscheduler retourne ENOSYS par design — le
fallback best-effort s'applique et le message l'indique), et les chemins
nouveaux de la v2 (drain, fanPhase réécrit, warm-up TTL, EDNS) qui n'ont
encore jamais été compilés nulle part. La 2.2 ajoute ses propres points à
vérifier au premier build : import des constantes SO_TIMESTAMP_MONOTONIC /
SCM_TIMESTAMP_MONOTONIC et des API mach thread_policy_set /
thread_time_constraint_policy_data_t côté Darwin ; import de SO_TIMESTAMPNS /
SCM_TIMESTAMPNS et SO_BUSY_POLL côté Linux (glibc et musl) ; types des champs
msghdr (msg_iovlen, msg_controllen) absorbés par numericCast. En cas d'échec
de compilation, tout est localisé dans recvWithTS, applyRuntimeHints et le
bloc --pin.

## Protocole de comparaison v1/v2

Même hôte, même conf (copie verbatim incluse), runs back-to-back, séquentiel,
`--sort p50`. Les colonnes RTT (min/p50/p90/p99/…) sont comparables ; `n`,
`fail` et `err` ne le sont pas, par construction : v2 récupère des échantillons
que v1 perdait (drain) et déclasse en `err` des réponses que v1 comptait comme
succès (RCODE). Un `err` non nul sur phebe1/phebe4 en v2 signifiera que les
runs v1 mesuraient en partie le rate-limiter FTL. Pour une comparaison propre
du cache lui-même, `--gap 5` maintient ~2000 req/60 s réparties sur le panel,
sous le seuil FTL par phase. Le happy path v2 (send/recv connecté) est
structurellement plus court que v1 (sendto/recvfrom) de l'ordre de la fraction
de µs — attendu, c'est un des objectifs. Même protocole applicable sur cible
Linux avec les binaires dist/ (v1 arm64 déjà produit, v2 via make linux-arm64).

## Différé (v2.x)

Sortie --json/--csv puis textfile-collector Prometheus (stack #31) ;
`--bind`. DoT/DoH : non-but (zéro dépendance). Écartés délibérément :
io_uring SQPOLL (changement d'architecture Linux-only pour 1–2 µs déjà sous
le plancher --kts), timestamps TX (MSG_ERRQUEUE, complexité disproportionnée
pour ~1 µs côté émission), PR_SET_TIMERSLACK (prctl est variadique en C,
inappelable depuis Swift).
