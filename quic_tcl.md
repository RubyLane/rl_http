# QUIC in Tcl: feasibility and architecture

Research notes on whether — and how — to add HTTP/3 / QUIC to the
rl_http-flavoured stack (protocol in Tcl script, crypto in C). This is
exploratory; nothing here is committed work. Written against the
state of the ecosystem in early 2026 (s2n-tls 1.5.x, tomcrypt 0.9.x,
Linux 6.8 mainline, Tcl 9).

## TL;DR

- **s2n-tls does not implement QUIC**; it exposes an internal API
  (`tls/s2n_quic_support.h`) for *external* QUIC implementations to
  drive. It provides the TLS 1.3 handshake state machine and secret
  derivation. The QUIC wire, streams, congestion control, HTTP/3 and
  QPACK are all your problem.
- **tomcrypt already covers ~90% of the crypto primitives QUIC needs**
  (HKDF, AES-GCM, ChaCha20-Poly1305, SHA-256/384). Two small gaps: raw
  ChaCha20 stream for the ChaCha20 header-protection path, and a clean
  single-block AES-ECB (trivially workaroundable with CFB/CTR).
- **Pure-Tcl QUIC is feasible** for someone comfortable implementing
  binary protocols at pgwire performance. Estimated 2-3 months focused
  work for an interop-tested HTTP/3 client. Straight-line bytecoded
  metaprogramming + jitc for hot paths plausibly gets per-packet Tcl
  overhead under 50 µs, keeping throughput in the
  low-to-mid-tens-of-MB/s range per stream.
- **Two architectural substrates** are worth considering: extending
  rl_http (cross-platform, consistent stance) or building on
  [ulp](/home/cyan/git/ulp) (Linux-only, smaller substrate, potential
  io_uring future, can drop ulp's current stream/resumable-parser
  layer). Both lead to the same pure-Tcl QUIC core.
- **Linux KTLS is a dead end as a QUIC crypto substrate** — the
  framing doesn't match. Mainline Linux has been accumulating
  in-kernel QUIC bits (`net/quic`) but that's a completely different
  architecture (syscalls replace most of your implementation) and
  gates on a specific kernel version.
- **Plan B** (wrap a C library): ngtcp2 + picotls. Reserve for the
  case where shipping H3 this quarter beats investing in a Tcl
  implementation.

## What s2n-tls actually provides for QUIC

Everything below is in `deps/s2n-tls/tls/s2n_quic_support.{h,c}`,
*not* in the public `api/` tree — you include the internal header.
The opening comment is explicit:

> APIs intended to support an external implementation of the QUIC
> protocol … change the behavior of S2N in potentially dangerous
> ways and should only be used by implementations of the QUIC
> protocol … all QUIC APIs are considered experimental and are
> subject to change without notice.

### The six entry points

```c
int  s2n_config_enable_quic(struct s2n_config *config);
int  s2n_connection_enable_quic(struct s2n_connection *conn);
bool s2n_connection_is_quic_enabled(struct s2n_connection *conn);

int  s2n_connection_set_quic_transport_parameters(
         struct s2n_connection *conn,
         const uint8_t *data_buffer, uint16_t data_len);
int  s2n_connection_get_quic_transport_parameters(
         struct s2n_connection *conn,
         const uint8_t **data_buffer, uint16_t *data_len);

typedef int (*s2n_secret_cb)(void *ctx, struct s2n_connection *conn,
         s2n_secret_type_t secret_type, uint8_t *secret, uint8_t secret_size);
int  s2n_connection_set_secret_callback(
         struct s2n_connection *conn, s2n_secret_cb cb, void *ctx);

int  s2n_recv_quic_post_handshake_message(
         struct s2n_connection *conn, s2n_blocked_status *blocked);

int  s2n_error_get_alert(int error, uint8_t *alert);
```

### How the pieces compose

1. **Mode toggle.** Call `s2n_connection_enable_quic()` before the
   handshake. This disables s2n's record-framing read/write paths
   (hence the `S2N_ERR_UNSUPPORTED_WITH_QUIC` error we saw when a
   non-QUIC parked keepalive connection was resumed) and puts s2n
   into "handshake messages only, no records" mode.

2. **Transport parameters.** Before the handshake, you call
   `s2n_connection_set_quic_transport_parameters(conn, bytes, len)`
   with the RFC 9000 §18 encoded bytes of *your* transport parameters
   extension. After the handshake completes you call
   `s2n_connection_get_quic_transport_parameters()` to read the
   peer's. **s2n treats these as opaque bytes** — encoding/decoding,
   validation, and interpretation are all yours.

3. **Secret callback.** The critical integration point. During the
   handshake s2n derives traffic secrets; when each is ready it calls
   your `s2n_secret_cb(ctx, conn, type, secret_bytes, secret_len)`.
   The six secret types are:
   ```c
   S2N_CLIENT_EARLY_TRAFFIC_SECRET       // 0-RTT
   S2N_CLIENT_HANDSHAKE_TRAFFIC_SECRET
   S2N_SERVER_HANDSHAKE_TRAFFIC_SECRET
   S2N_CLIENT_APPLICATION_TRAFFIC_SECRET
   S2N_SERVER_APPLICATION_TRAFFIC_SECRET
   S2N_EXPORTER_SECRET
   ```
   The secret is typically 32 or 48 bytes (SHA-256/384 of TLS 1.3).
   **The bytes are wiped after your callback returns — copy them if
   you need them later.** From each secret you HKDF-Expand-Label four
   things per packet-number-space: AEAD key, AEAD IV, header
   protection key, and (for application space) the key-update
   material.

4. **Driving the handshake.** You don't call `s2n_recv`/`s2n_send`.
   Instead:
   - To feed incoming TLS bytes (from CRYPTO frames in QUIC Initial
     and Handshake packets), write them into s2n's handshake input
     buffer via `s2n_send(conn, crypto_bytes, len)` (in QUIC mode,
     `s2n_send` is repurposed to append to the inbound handshake
     buffer — check the code, this is the bit where the API gets
     weird).
   - Advance the handshake with `s2n_negotiate()`. The return value
     tells you whether it's blocked, succeeded, or failed; the
     secret callback fires along the way.
   - After each step, drain outbound handshake bytes from s2n (for
     emission in your next CRYPTO frame). The outbound bytes live
     in s2n's output stuffer; check `s2n_connection.h` for the
     internal accessors.

5. **Post-handshake.** Once the handshake completes, call
   `s2n_recv_quic_post_handshake_message()` with each post-handshake
   TLS message you receive in a CRYPTO frame. Today that only does
   NewSessionTicket (so 0-RTT works for the *next* connection).

6. **Alerts.** QUIC encodes TLS alerts in CONNECTION_CLOSE frames.
   Call `s2n_error_get_alert()` to ask s2n which alert code it would
   have sent, and put that in the CONNECTION_CLOSE.

### What s2n does *not* help with

Everything else: packet protection, header protection, packet number
state, ACKs, loss detection, congestion control, flow control,
streams, connection IDs, path validation, version negotiation,
stateless reset, anti-amplification, migration. These are all QUIC
transport concerns with no s2n hooks.

## Crypto coverage: tomcrypt

QUIC needs the following primitives. tomcrypt status noted:

| QUIC primitive | tomcrypt surface | status |
|---|---|---|
| HKDF-Extract/Expand (SHA-256/384) | `tomcrypt::hkdf sha256 $salt $info $ikm $length` | ✓ direct |
| HKDF-Expand-Label (RFC 8446 §7.1) | HKDF + Tcl-side label wrapping | ✓ wrap in pure Tcl |
| AES-128-GCM packet AEAD | `tomcrypt::aead encrypt gcm aes $key $iv $aad $pt` | ✓ direct |
| AES-256-GCM packet AEAD | same with 32-byte key | ✓ direct |
| ChaCha20-Poly1305 packet AEAD | `tomcrypt::aead encrypt chacha20poly1305 "" ...` | ✓ direct |
| SHA-256 / SHA-384 | `tomcrypt::hash` | ✓ direct |
| **AES header protection** (RFC 9001 §5.4.3): `AES(hp, sample)` on a single 16-byte block, take first 5 bytes as mask | no raw ECB, but CFB/CTR of 16 zero bytes with `iv=sample` gives `AES(hp, sample)` | ◐ workaround |
| **ChaCha20 header protection** (RFC 9001 §5.4.4): `ChaCha20(hp, counter=sample[0..3], nonce=sample[4..15])` → first 5 bytes of keystream | tomcrypt exposes ChaCha20 only inside the AEAD; no raw stream primitive | ✗ needs adding |
| Packet-number nonce construction (`iv ⊕ pn_big_endian_padded`) | pure Tcl with `binary format` / xor | ✓ Tcl-side |

### Gap 1: AES single-block

Use `tomcrypt::encrypt {aes $size cfb}` with `iv=sample`,
`plaintext=[binary format x16]` (16 zero bytes). The output is
`0 ⊕ AES(hp, sample)` = the 16-byte mask block. Take the first 5
bytes. No kernel change needed.

Could be cleaner with a native ECB mode in tomcrypt; a ~50-line
addition if we want it.

### Gap 2: raw ChaCha20 stream

This one does need a tomcrypt addition. Options:

1. **Add `chacha20` to `tomcrypt::encrypt`'s mode list.** Wraps
   libtomcrypt's `chacha_ivctr32` / `chacha_crypt`. Would take ~100
   lines in `symmetric.c`. Useful beyond QUIC (CFRG modern-stream
   cipher for misc. uses).
2. **Expose a dedicated `tomcrypt::chacha20` command.** Smaller
   surface if we don't want to shoehorn a stream cipher into the
   block-cipher-shaped `encrypt` API.

Either way, one day's work. Worth doing regardless of the QUIC
project — it's a general-purpose primitive.

Until it lands, a client that only advertises `TLS_AES_128_GCM_SHA256`
and `TLS_AES_256_GCM_SHA384` (both AES-GCM-based, both using AES
header protection) has no ChaCha20 dependency. That's a fine Phase 1
— both are mandatory-to-implement per RFC 8446 and supported
universally.

### Zero-dep fallback: AF_ALG

Linux's `AF_ALG` socket interface covers every QUIC primitive
(including raw ChaCha20), so a tomcrypt-less build could fall back
on it. Measured overhead is ~14× tomcrypt per op even with socket
reuse (`sha256`: af_alg 3.9 µs vs tomcrypt 0.35 µs; single-block
AES: af_alg 5.1 µs), because each op is ≥2 syscalls. Per-packet cost
adds ~6-10 µs over tomcrypt — noticeable but not fatal. Kept as a
last-resort fallback, not part of the plan.

## What to implement in Tcl (or jitc)

Roughly in bottom-up layer order. Crossed off items are already
solved:

- ~~Crypto primitives~~ (tomcrypt, modulo the two gaps above).
- ~~TLS 1.3 handshake + keying~~ (s2n, via the QUIC API).
- ~~UDP I/O~~ (user's existing UDP extension, to be refreshed;
  event-driven datagram API, not chan-streamed).

What remains:

### 1. Variable-length integer codec (RFC 9000 §16)

Two-bit prefix determines 1/2/4/8-byte encoding. Trivial. Used
pervasively; worth putting through a jitc pass for the hot path.

### 2. Packet header encode/decode (RFC 9000 §17)

- **Long header**: Initial, 0-RTT, Handshake, Retry, Version
  Negotiation. Each has its own field layout.
- **Short header (1-RTT)**: spin bit, key phase, destination
  connection ID, packet number.
- Packet number encoding: 1/2/3/4 bytes, dependent on the
  largest-acknowledged state.

Natural fit for the "straight-line bytecoded Tcl" approach: one
`binary scan` per header variant. Multiple fields per call amortizes
to ~0.15 µs/call regardless of field count. ~20 variants total.

### 3. Initial-packet keying (RFC 9001 §5.2)

`HKDF-Expand-Label` from a spec-fixed salt and the client's
destination connection ID to derive the Initial-packet AEAD key and
header-protection key. This happens *before* the TLS handshake —
the Initial ClientHello has to be encrypted with keys derived from
a public constant plus the DCID you chose. Pure Tcl with tomcrypt.

### 4. Packet protection (RFC 9001 §5 + §5.4)

Per-packet:

1. **Derive per-PN-space keys** from the traffic secret s2n gave
   you (one-time, per secret-callback event). HKDF-Expand-Label for
   `key`, `iv`, `hp`. Cache the expanded keys on the packet-number
   space struct.
2. **Compute nonce**: `iv XOR pn_padded_to_iv_length_big_endian`.
3. **AEAD seal** the packet body: tomcrypt::aead encrypt gcm.
4. **Header protect**: AES-CFB on 16 bytes of sample, XOR the first
   mask byte into the first packet byte's low bits (4 or 5 depending
   on long/short header), XOR the next 1-4 mask bytes into the
   packet-number field.
5. On receive: unprotect the header to recover the PN length, then
   AEAD-open.

Hot path. Per-packet budget dominated by the AEAD call (tomcrypt →
libtomcrypt → AES-NI, ~5-15 µs for a 1200-byte datagram). Everything
else, including the two `binary format` / XOR dances, is script
overhead well under 10 µs.

### 5. Frame codec (RFC 9000 §19)

~24 frame types. Client-only HTTP/3 MVP needs about a dozen:
CRYPTO, ACK (with ACK-range vector), PADDING, PING, STREAM,
CONNECTION_CLOSE, MAX_DATA, MAX_STREAM_DATA, HANDSHAKE_DONE,
NEW_CONNECTION_ID, RETIRE_CONNECTION_ID, NEW_TOKEN. Add
STREAMS_BLOCKED, DATA_BLOCKED, RESET_STREAM, STOP_SENDING for
correctness. Later: PATH_CHALLENGE/RESPONSE for migration.

Straight `binary scan` work, ideal for the metaprogramming-
generated dispatcher pattern.

### 6. Per-PN-space state machine

Three spaces: Initial, Handshake, Application. Each has its own:

- Packet-number sender/receiver counters.
- Outstanding-for-ACK table.
- AEAD read/write keys.
- Header-protection keys.
- Retransmission logic (lost packets get their frames re-queued, not
  the packets themselves — distinct from TCP).

Initial and Handshake spaces are dropped at specific handshake
transitions; getting those drops right is security-sensitive (RFC
9001 §4.9).

### 7. Stream multiplexer

- Stream IDs: 2-bit encoding for direction + initiator (client-
  bidi/server-bidi/client-uni/server-uni) + implicit stream creation
  via highest-seen ID.
- Per-stream credit windows and per-connection credit window
  (`MAX_DATA` / `MAX_STREAM_DATA`).
- Out-of-order byte reception → ordered delivery on each stream.
  This is exactly the kind of reassembly buffer pgwire doesn't need
  but TCP's kernel gave you for free — now you implement it.

### 8. Loss detection & congestion control (RFC 9002)

Two parts:

- **Loss detection**: RTT sampling (with ACK-delay adjustment),
  per-PN-space loss-detection timers, PTO (probe timeout) with
  exponential backoff.
- **Congestion control**: RFC 9002 specifies a NewReno variant, but
  the CC algorithm is deliberately swappable — BBR implementations
  are common. An initial NewReno is ~200-400 lines of Tcl and gets
  you usable throughput. BBRv1 or BBRv2 can come later if you're
  driving bulk transfer.

This is the single most underestimated part of a QUIC implementation.
Getting it wrong means a spec-compliant but empirically unusable
protocol. But it's also self-contained (doesn't touch crypto or
framing) so can evolve independently after the basic stack works.

### 9. Connection ID management

Issue/retire CIDs, track the active DCID/SCID, stateless reset
tokens. Required for the protocol to function; not complex.

### 10. Anti-amplification & amp limit (client-irrelevant mostly)

Server-side 3x received bytes rule until address validated. Client
doesn't care; if you ever do a server, it matters.

### 11. HTTP/3 (RFC 9114)

Once you have a stream transport: HTTP/3 framing (HEADERS, DATA,
GOAWAY, SETTINGS, PUSH_PROMISE) is genuinely simpler than HTTP/1.1
chunked-transfer-encoding once you accept stream semantics.

### 12. QPACK (RFC 9204)

The one genuinely gnarly bit left. Header compression with a
*shared dynamic table* maintained via a separate encoder-to-decoder
stream with back-pressure. You can ship a "static-table-only, empty
dynamic table, stream cancellation if peer requires dynamic entries"
stub and still interop with most servers — many tolerate a client
that says `SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0`. That reduces
QPACK to "basically static-HPACK" which is a weekend's work.

## Performance: Tcl-script QUIC viability

### Budget math (revised with your techniques)

Per-packet hot path on a typical ~1200-byte datagram:

| Work | Time (µs) |
|---|---|
| UDP datagram read + dispatch | 5-15 (depends on UDP extension + event loop) |
| Header unprotect (AES-CFB 16B through tomcrypt) | 2-5 |
| Payload AEAD-open (AES-GCM ~1200B through tomcrypt, AES-NI) | 5-12 |
| Header decode (1 × `binary scan`) | 0.15 |
| Frame decode (N × `binary scan`, script dispatch) | 1-10 (N frames) |
| PN-space state update, ACK scheduling | 5-20 |
| Stream-layer delivery (if STREAM frames) | 5-30 |
| **Total realistic** | **~30-90 µs** |

Versus my original 100-200 µs estimate, which assumed generic
command-per-field decoding. Your numbers:

> simple fully-bytecoded Tcl commands: ~0.005 µs
> binary scan (multi-field, fixed dispatch): ~0.15 µs
> straight-line bytecoded scripts generated via metaprogramming

put the frame/header decode cost well below the crypto cost. That
flips the budget — **crypto becomes the floor, not the Tcl script.**
At 30-90 µs/packet that's ~11k-33k packets/sec single-threaded →
13-40 MB/s per stream on 1200B datagrams. Good enough for everything
except bulk downloads.

### jitc escape hatch

The two places it'd pay off:

1. **Packet protection inner loop** (seal + unseal, header-protect +
   unprotect). A single C function that takes key material and
   packet bytes and does the full protect/unprotect pass, avoiding
   the Tcl→tomcrypt→Tcl roundtrip per step. The pgwire result-set-
   parser precedent is directly applicable: the thing that stopped
   being a bottleneck in pgwire is exactly the same shape of work.
2. **Frame parse dispatch** if profiling says so. Probably not
   needed given your metaprogramming + bytecoding pattern, but an
   option if ACK-frame decoding shows up in a flamegraph (ACK ranges
   can be many, especially on a loss-heavy link).

Neither is a day-one requirement — ship pure-Tcl first, profile,
promote paths to jitc if needed.

### Event-loop cadence

QUIC wants timers at ~ms granularity (PTO, ACK delay) and can burst
packets. Tcl's `after` is fine for timer accuracy on Linux (few-ms
drift, adequate). The real question is *draining* UDP at the event
loop's edge.

With a chan-based UDP extension, each readable event = one
datagram = one event-loop trip. At 30k packets/sec that's 30k
events/sec, which is on the edge of comfortable for Tcl. Options:

- **Batched drain**: one readable event → loop calling
  `recv` non-blocking until EAGAIN. Reduces event dispatch by 10-50x
  under load. Needs the UDP extension to support non-blocking recv.
- **recvmmsg binding**: one syscall pulls up to N datagrams. Saves
  both event dispatch *and* syscalls. Worth it if bulk throughput
  matters.
- **io_uring**: further out, but Linux-native. Pairs naturally with
  a ulp-based substrate.

## Architectural options

### Option A: extend rl_http

Pros:
- Matches existing stance: rl_http is already an HTTP protocol
  implementation in Tcl script, and QUIC is the transport for H3.
- Cross-platform (macOS, Windows, Linux, BSDs).
- Reuses the keepalive-pool and resolve-cache machinery (connection
  migration fits the pool model surprisingly well).

Cons:
- rl_http has never been a UDP client. Adding it means either a new
  dependency (the UDP extension) or making UDP an optional
  "H3 available" capability.
- rl_http's design doesn't currently distinguish cleartext and
  encrypted framing the way QUIC needs.

Natural shape:
- Top-level `rl_http` command grows `http3` / `h3` scheme support.
- A new `rl_http::quic` internal class handles the QUIC connection,
  plugging into the existing `_connect` / `_keepalive_park` shape
  where analogous.
- `push_tls` becomes one of two drivers; QUIC is the other.
- The HTTP/3 and QPACK layers sit above the stream multiplexer,
  replacing the HTTP/1.1 request/response path for H3 URLs.

### Option B: build on ulp

[ulp](/home/cyan/git/ulp) is "a nascent high-performance network
client/server framework", currently TCP-streams-based with a
resumable-parser layer, epoll event loop (with io_uring likely in
future), Linux-only.

For QUIC, *all* of that changes shape:

- **Drop the stream layer entirely** at ulp's base. QUIC reads
  datagrams, not streams. The stream abstraction in ulp is about
  reassembling TCP byte streams — QUIC reassembles into application
  streams *above* the transport.
- **Drop the resumable-parser layer** for the same reason. QUIC
  frames are delimited inside each decrypted packet; once you've
  decrypted you have a bounded buffer. No cross-call-resumption
  needed at the transport layer.
- **What remains** from ulp is the high-performance substrate: the
  epoll-based reactor, the obstack pool (useful for per-packet
  scratch allocation), the object lifecycle plumbing.
- **What it gains**: UDP I/O via recvmmsg / sendmmsg in a tight C
  loop, with Tcl-script callbacks only at packet/frame boundaries.

Pros:
- Linux-only → can use recvmmsg, sendmmsg, io_uring, GSO/GRO for
  UDP, SO_ATTACH_REUSEPORT_CBPF for server-side flow affinity,
  `SO_RXQ_OVFL` for drop detection, without fallbacks.
- Potentially much higher throughput ceiling — the ulp substrate can
  batch UDP I/O and amortize the Tcl dispatch cost across many
  packets.
- No rl_http back-compat constraints.

Cons:
- Linux-only (stated acceptable).
- A new "ulp flavour" — diverges code organization from rl_http.
- Starts from a smaller base than rl_http.

Natural shape:
- `ulp` grows a UDP-datagram server/client primitive (using whatever
  Linux gives it — epoll for now, io_uring later).
- A new Tcl-shaped `ulp::quic` layer on top.
- HTTP/3 + QPACK sit on ulp::quic's stream multiplexer.
- rl_http can be taught to use ulp::quic for H3 URLs, getting the
  best of both (rl_http's API surface, ulp's substrate) without
  merging them.

### My lean

Start with **Option B (ulp)**, for three reasons:

1. **Performance ceiling matters more than portability for H3.** H3
   on Linux is where the interesting throughput wins are; non-Linux
   users already have TCP+TLS working fine in rl_http.
2. **Fresh start.** QUIC is sufficiently different from HTTP/1.1
   that trying to unify them in one codebase creates more friction
   than having two cleanly-separated stacks.
3. **ulp's existing structure is already aimed at this kind of
   work.** The resumable-parser layer was carrying weight that QUIC
   doesn't need; taking it out makes ulp simpler *and* more aligned
   with how QUIC wants to be driven.

Cross-pollinate: rl_http learns to call into `ulp::quic` for H3
connections. That keeps the top-level API familiar and lets existing
rl_http users get H3 transparently once the lower stack lands.

## Linux KTLS and in-kernel QUIC

### KTLS: dead end as a QUIC substrate

KTLS (kernel TLS) offloads TLS record encryption/decryption for TCP
sockets. You set keys with setsockopt, and reads/writes on the
socket transparently en/decrypt. Introduced in 4.13 (TX) / 4.17 (RX),
TLS 1.3 support in 5.19.

Why it doesn't help QUIC:
- KTLS is *record-framed over TCP*. QUIC is *datagram-packet-framed
  over UDP*. The frame boundaries, nonce construction, and header
  protection step are all different.
- Even if you could hypothetically drive KTLS from a UDP socket,
  QUIC's header protection is a *second* AEAD pass that KTLS doesn't
  know about.

The crypto primitives KTLS uses (AES-GCM, ChaCha20-Poly1305) are
exactly what QUIC uses. If there were a `setsockopt`-style interface
to just *use KTLS's AEAD engine* outside of TCP records, that'd be
useful. There isn't one.

### In-kernel QUIC (`net/quic`): different architecture

Xin Long (Red Hat) has been upstreaming an in-kernel QUIC
implementation. Status is moving; check `net/quic/` and
`include/uapi/linux/quic.h` in the latest mainline. When complete,
it'd give you an `AF_QUIC` socket: open(), connect(), recv(), send()
semantics, kernel owns the protocol.

If that lands and stabilizes, it obsoletes this whole project — you
bind `AF_QUIC` from Tcl the way you bind `AF_INET`, and the kernel
does everything. But:

- Gating on a very recent kernel with the feature compiled in is a
  deployment constraint many environments don't satisfy.
- The user-space QUIC-implementation ecosystem (ngtcp2, quiche,
  msquic, picoquic) shows no signs of being displaced, so the kernel
  implementation is more a coexistence story than a replacement.
- For rl_http-style deployments (batteries-included Tcl runtime
  shipped to varied targets), portable user-space QUIC stays
  relevant.

Not a reason to not build a user-space Tcl implementation; *is* a
reason to design the code so that a future "just use `AF_QUIC`"
driver can slot in alongside, the same way rl_http today has both
`tls` and `s2n` drivers.

## Plan B: wrap a C QUIC library

If the Tcl-script implementation runs into a hard wall (scope
creep, interop debugging, or simply needing H3 shipped on a shorter
timeline), the best wrap targets:

- **ngtcp2 + picotls**: MIT / BSD-3. ngtcp2 is crypto-agnostic by
  design and has upstream TLS-backend adapters for OpenSSL,
  BoringSSL, GnuTLS, wolfSSL, picotls. No s2n-tls backend upstream
  today. Picotls is the natural pair — small, focused, low-dep.
- **ngtcp2 + s2n-tls**: requires writing a new TLS-backend adapter
  (~1k lines, adapter pattern is well-documented in ngtcp2). Worth
  doing if we want to stay in the s2n ecosystem AND wrap a C impl;
  would also be a useful upstream contribution to ngtcp2.
- **picoquic**: BSD-3. Tied to picotls. Smaller community than
  ngtcp2 but simpler codebase. Research-oriented but interop-
  tested.
- **s2n-quic**: Amazon's own. Apache-2. Rust. C API exists but
  partial; Rust toolchain is a meaningful dep to add.

Avoid: msquic (too heavy), quiche (Rust toolchain), lsquic
(BoringSSL tie-in, bigger footprint).

## Recommended next steps

Ordered roughly by commit level:

1. **Cheap: add raw ChaCha20 to tomcrypt.** Useful regardless.
   One-day job.
2. **Cheap: one-week spike.** Open a UDP socket, construct an
   Initial packet with a hand-built ClientHello (or driven through
   s2n's QUIC mode), send it to Cloudflare's `cloudflare-quic.com`,
   receive + unprotect the response. Validates the s2n secret-
   callback plumbing and the Initial-key derivation path against a
   real server. If this spike works, the rest is engineering-through-
   the-spec; if it doesn't, the issues surface early.
3. **Decision point: rl_http vs ulp.** Based on the spike
   experience, pick the substrate.
4. **Medium: Handshake + 1-RTT single-stream.** Get to the point
   where a QUIC connection establishes and you can send/receive
   STREAM frame bytes. That's about 60% of the transport.
5. **Medium: HTTP/3 + minimal QPACK.** Enough to GET a URL.
6. **Harder: interop debugging.** Point at the QUIC interop test
   matrix servers (Cloudflare, Google, LiteSpeed, Facebook) and fix
   whatever breaks.
7. **Harder: congestion control quality.** NewReno first, BBR if
   warranted.
8. **Optional: promote hot paths to jitc** once profiling says so.
9. **Optional: add the other tomcrypt gap** (clean ECB) and
   ChaCha20-Poly1305 ciphersuite support.
10. **Release vehicle**: whichever substrate wins, expose through
    rl_http so existing callers get H3 transparently via URL scheme.

## References

- RFC 9000 — QUIC transport
- RFC 9001 — Using TLS to Secure QUIC
- RFC 9002 — QUIC Loss Detection and Congestion Control
- RFC 9114 — HTTP/3
- RFC 9204 — QPACK
- RFC 8446 — TLS 1.3 (handshake + HKDF-Expand-Label)
- s2n-tls: `deps/s2n-tls/tls/s2n_quic_support.{h,c}`
- QUIC interop test runner: https://interop.seemann.io/
- ngtcp2: https://github.com/ngtcp2/ngtcp2
- picoquic: https://github.com/private-octopus/picoquic
