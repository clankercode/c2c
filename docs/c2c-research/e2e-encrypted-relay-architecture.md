# E2E Encrypted Relay Architecture for Agent-to-Agent Messaging

**Date**: 2026-04-15
**Scope**: Architectures and protocols for building a secure end-to-end encrypted relay server for agent-to-agent messaging (like c2c)

---

## Executive Summary

Building an E2E encrypted relay for agent-to-agent messaging is well-trodden ground with several production-grade reference implementations to learn from. The recommended approach for a c2c-style system is:

- **Cryptographic identity**: Ed25519 identity key pair generated at first boot, public key registered on the relay (with optional TLS client certificates for transport authentication). This is simpler than ZK-based identity and sufficient for an agent-to-agent use case.
- **E2E encryption**: X3DH key agreement (or Noise IK pattern) followed by Double Ratchet for forward secrecy. libsodium provides all needed primitives.
- **Group/room messaging**: Use Signal-style "Sender Keys" (Megolm approach) for simplicity, or MLS for correctness with larger groups. For c2c's scale, Sender Keys are likely sufficient.
- **Relay threat model**: The relay stores and forwards only encrypted blobs. It cannot read message content, cannot correlate sender/recipient without metadata, and cannot decrypt even if fully compromised.

The key reference implementations are **libsignal** (Signal Protocol), **libolm** (Olm/Megolm for Matrix), **simplexmq** (SimpleX), and **MLS (RFC 9420)**. libsodium is the recommended crypto library.

---

## 1. Cryptographic Identity and Onboarding

### 1.1 Identity Key Pairs (Recommended)

The simplest and most battle-tested approach: each agent generates an Ed25519 key pair at first boot and registers the public key on the relay server.

**Protocol flow**:

1. Agent generates `identity_sk` (Ed25519 private key) and `identity_pk` (Ed25519 public key) at first boot.
2. Agent connects to relay over TLS and submits `identity_pk` along with a signed proof-of-possession:
   ```
   signed_proof = Ed25519Sign(identity_sk, "REGISTER:" || relay_id || timestamp)
   ```
3. Relay stores `(alias, identity_pk, timestamp)` in its registry. No pre-shared secret required.
4. Subsequent connections prove identity by signing a challenge from the relay (or signing all messages with `identity_sk`).

**Properties**:
- No pre-shared secrets. Identity is self-contained.
- The relay learns the agent's public key but not the private key.
- Anyone can create any identity -- this is a bootstrapping problem (see Section 5 for solutions).
- Ed25519 provides 128-bit security; compatible with Curve25519 for DH operations.

**Tradeoffs**: This is the approach used by Matrix (device identity keys), Session (long-lived X25519 keys), and Signal.

### 1.2 TLS Client Certificates

Use mutual TLS (mTLS) where the relay server and agents authenticate each other with X.509 client certificates. The agent's certificate contains its identity public key as the certificate's public key.

**Advantages**:
- Identity proof is embedded in the TLS handshake itself.
- The relay can ban agents by revoking their certificate (without being able to decrypt messages).
- Transport-layer identity is separate from message-layer identity.

**Disadvantages**:
- PKI bootstrapping: who issues certificates? For a self-hosted relay, a self-signed CA works. For a federated system, you need a certificate authority.
- Certificate lifecycle management (rotation, revocation) adds complexity.
- Less flexible than raw Ed25519 for key rotation and device migration.

**Best for**: Environments that already use a PKI, or where transport-layer identity verification is strictly required.

### 1.3 WireGuard / Noise Protocol-Style Key Exchange

WireGuard uses the Noise Protocol Framework with the `IK` handshake pattern:

```
Noise_IK(
  e, ee, es, s, se, ss
)
```

Where:
- `e` = agent generates an ephemeral key pair
- `s` = agent sends its static identity public key
- `ee` = DH between agent ephemeral and relay ephemeral
- `es` = DH between agent ephemeral and relay static (authenticates relay to agent)
- `se` = DH between relay ephemeral and agent static (authenticates agent to relay)
- `ss` = DH between both static keys (mutual authentication)

**Properties**:
- Provides mutual authentication.
- Forward secrecy: ephemeral key compromises do not expose past sessions.
- Identity hiding: the relay's static key is revealed to the agent but the agent's static key is encrypted (`es` DH).
- Used by WireGuard, WhatsApp (uses Noise for transport encryption), Lightning Network.

**Tradeoffs**: More complex to implement than simple Ed25519 registration. Better suited for long-lived transport sessions than one-off message relay. Noise is excellent for the transport layer but overkill for message-layer identity alone.

### 1.4 ZK-Based Identity (MACI / Semaphore)

Zero-knowledge proofs can be used to prove identity without revealing the underlying key. For example, MACI (Minimal Anti-Collusion Infrastructure) uses ZK proofs to allow voting/messaging without revealing the identity of the sender.

**Approaches**:
- **MACI**: Proves you have a valid identity key without revealing which one. Prevents double-signing.
- **Semaphore**: Zero-knowledge identity signals. Prove membership in a group without revealing the specific member.
- **Darkwing**: Anonymous credentials with ZK proofs.

**Properties**:
- Maximum privacy: identity is proven without revelation.
- Prevents Sybil attacks via ZK constraints.
- Complex: requires trusted setup ceremonies, large proofs, significant computational overhead.

**Tradeoffs**: ZK-based identity is powerful but adds substantial complexity. For a relay server where the threat model includes "relay operators who want to identify users," ZK proofs may be unnecessary. For applications requiring strong anonymity against the relay itself, ZK identity is compelling.

**Recommendation for c2c**: Ed25519 identity key pairs with signed proofs. Simple, battle-tested, and sufficient for an agent-to-agent messaging context. Add Noise-style transport encryption if you want forward secrecy at the transport layer.

---

## 2. End-to-End Encrypted Messaging Through a Relay

The relay should act as a "message store and forward" service that never sees plaintext content.

### 2.1 X3DH + Double Ratchet (Signal Protocol) (Recommended)

This is the gold standard for E2E encrypted messaging. Used by Signal, WhatsApp, Google Messages, and others.

**X3DH Key Agreement** (used when initiating a conversation):

```
DH1 = DH(IKA, SPKB)      // Alice identity key with Bob signed prekey
DH2 = DH(EKA, IKB)       // Alice ephemeral with Bob identity key
DH3 = DH(EKA, SPKB)      // Alice ephemeral with Bob signed prekey
DH4 = DH(EKA, OPKB)      // Alice ephemeral with Bob one-time prekey (if available)

SK = HKDF(DH1 || DH2 || DH3 || DH4)
```

X3DH is designed for the asynchronous case where Bob is offline -- Alice can establish a shared secret using Bob's published prekeys. Once established, both parties use the Double Ratchet.

**Double Ratchet**:

Each party maintains:
- A **DH ratchet key pair** (ratcheted on each received message)
- **Root chain key** (RK)
- **Sending chain key** (SKs) and **Receiving chain key** (SKr)

The ratchet:
1. **DH ratchet step**: On receiving a new public key, perform DH with it to advance the root KDF chain twice, producing new sending and receiving chain keys.
2. **Symmetric ratchet step**: Derive a message key from the chain key, then advance the chain key forward. Each message gets a unique message key.

**Security properties**:
- **Forward secrecy**: Compromise of current chain key does not expose past message keys.
- **Post-compromise security**: After a key compromise, ratcheting recovers security for future messages.
- **Skipped message keys**: Handles out-of-order delivery via stored skipped keys.

**For the relay**: The relay stores encrypted blobs. It sees the Double Ratchet header (ratchet public key, message number, previous chain length) but not the encrypted content. Forward secrecy means that a future compromise of the relay's stored data does not allow decryption of past messages.

### 2.2 libsodium Sealed Box

libsodium's `crypto_sealed_box` provides anonymous encryption:

```
ciphertext = ephemeral_pk || crypto_box(message, nonce, ephemeral_sk || recipient_pk)
```

**Properties**:
- Uses X25519 for ephemeral key exchange, XSalsa20-Poly1305 for authenticated encryption, BLAKE2b for nonce derivation.
- Sender is anonymous -- recipient can verify integrity but cannot identify the sender.
- No forward secrecy by itself -- the same key is used for all messages.
- Very simple API.

**Use case**: For single messages or when forward secrecy is not required. For c2c, you would typically wrap this in a ratcheting protocol.

### 2.3 Noise Protocol Framework

Noise provides a menu of handshake patterns. For E2E messaging relay:

- **Noise_IK**: Mutual authentication with static key transmission. Forward secrecy level 5.
- **Noise_XX**: Full handshake where both parties exchange ephemeral and static keys. Zero round-trip after handshake.
- **Noise_KK**: Both already know each other's static keys. Only ephemeral DH each session.

**Properties**:
- Modular: choose the pattern that fits your identity model.
- Provides identity hiding based on pattern choice (IK hides receiver identity better than KK).
- Forward secrecy configurable (level 0-5).
- WireGuard, WhatsApp, and Lightning use Noise.

**For the relay**: Use Noise_IK at the transport layer for authenticated, forward-secret channels. Messages within those channels can use application-layer encryption.

### 2.4 Comparison

| Approach | Forward Secrecy | Post-Compromise Security | Complexity | Used By |
|---|---|---|---|---|
| X3DH + Double Ratchet | Yes | Yes | High | Signal, WhatsApp, Google Messages |
| libsodium sealed_box | No | No | Low | Good for single messages |
| libsodium secret_box | No | No | Low | Shared-key scenarios |
| Noise Protocol | Yes (configurable) | Yes (configurable) | Medium | WireGuard, WhatsApp (transport) |
| Olm (3-party DH) | Partial | Partial | Medium | Matrix (pairwise only) |

**Recommendation for c2c**: X3DH + Double Ratchet via libsignal or a direct implementation. This provides the strongest security properties (forward secrecy + post-compromise security). If complexity is a concern, use libsodium's `secret_box` with periodic key rotation (simpler but weaker). The best available library is **libsignal** (Rust, with bindings to many languages) or **libsodium** with manual Double Ratchet implementation.

---

## 3. Room Membership with Cryptographic Verification

### 3.1 Signal Sender Keys (Megolm Approach) (Recommended for c2c Scale)

Each sender in a room maintains its own sender key. When sending a message, the sender ratchets its sender key and encrypts the message with the current message key. All other members in the room receive the sender key during room initialization.

**Protocol flow**:

1. **Room initialization**: When a member joins, they receive sender keys from all existing members via a pairwise Double Ratchet channel.
2. **Sending**: Sender generates a new message key by ratcheting its sender key chain, encrypts the message, and sends the ciphertext with the current ratchet state.
3. **Receiving**: Recipients use the sender's public ratchet state to derive the same message key and decrypt.
4. **New member joining**: Existing members send their current sender keys to the new member.

**Megolm specifics**:
- Uses AES-CBC + HMAC for encryption (older Megolm) or AES-GCM (newer).
- Message index increments with each message for out-of-order handling.
- A new sender key is generated when the index approaches 2^32.

**Properties**:
- Efficient: each sender encrypts only once, regardless of group size.
- New member can read history only if sender keys are provided.
- Removing a member requires generating new sender keys for all remaining members -- O(N) cost.

**Tradeoff**: If one sender key is compromised, only messages from that sender are exposed (not the whole group's history).

### 3.2 Signal Private Groups (Pairwise Encryption)

Instead of a shared group key, Signal uses pairwise encryption: each group message is sent as N separate encrypted copies, one per recipient, via existing pairwise Double Ratchet channels.

**Protocol flow**:
1. Sender generates an ephemeral symmetric key K.
2. Encrypts message content with K: `C = AES_K(message)`.
3. Sends one copy of C to the relay (or server).
4. For each recipient, encrypts the message hash + K with the pairwise key.
5. Relay distributes one copy per recipient.

**Properties**:
- Server does not need to know the concept of a "group".
- No group key management.
- Scales poorly: O(N) encryption cost for the sender. Acceptable for small groups.
- Maximum forward secrecy per recipient.

**Used by**: Signal's closed group chats (up to ~1000 members, but practical limit is much lower).

### 3.3 MLS (Messaging Layer Security) (RFC 9420)

MLS is an IETF standard (RFC 9420) that provides authenticated group key exchange with strong security properties.

**Key features**:
- **Ratchet trees**: A perfect binary tree structure where each node holds an HPKE public key. Private keys are distributed among group members.
- **Tree-based ratchet**: Logarithmic-cost operations for adding/removing members. Adding a member to a 1000-person group costs the same as adding to a 2-person group.
- **Welcome messages**: New members receive a Welcome message that initializes their group state. Existing members send this directly to the new member (not via the relay).
- **Handshake messages**: PublicMessage (signed, unencrypted for handshake) and PrivateMessage (signed + encrypted for application data).
- **Forward secrecy + post-compromise security**: Achieved through epoch-based key updates.

**Properties**:
- O(log N) cost for member add/remove.
- Sender keys are one per sender (similar to Megolm) but with tree-based optimization.
- Standardized, well-reviewed, production-quality implementations available (OpenMLS in Rust/C, MLS.js in TypeScript).
- Handles large groups (2 to thousands of members) efficiently.

**Tradeoff**: More complex to implement than Sender Keys. Better for larger groups or when formal verification is required.

### 3.4 Comparison

| Approach | Member Add/Remove Cost | Large Group Efficiency | Complexity | Standard |
|---|---|---|---|---|
| Signal Sender Keys (Megolm) | O(N) | Poor (>100 members) | Medium | De facto |
| Signal Private Groups | O(N) per recipient | Poor | Low | De facto |
| MLS (RFC 9420) | O(log N) | Excellent | High | IETF RFC 9420 |
| Double Ratchet Tree | O(log N) | Good | Very High | Research |

**Recommendation for c2c**: Start with **Sender Keys** (Megolm approach). It's simpler to implement, works well for small-to-medium groups (under 50 members), and has proven production deployments (Matrix). If group sizes grow large or formal protocol correctness matters, migrate to **MLS**.

---

## 4. Existing Implementations

### 4.1 Matrix / libolm / Megolm

**Repository**: https://github.com/matrix-org/libolm (C), https://github.com/matrix-org/megolm

**Architecture**:
- **Olm**: Three-party DH key agreement for pairwise sessions. Designed for the case where both parties interact with the same server (a "three-party" DH rather than two-party X3DH).
- **Megolm**: Sender-key based group encryption built on Olm's cryptographic primitives.
- The relay (homeserver) stores encrypted events. It cannot decrypt them.

**What it provides**:
- C library (libolm) with ports to JavaScript, Python, Rust.
- Olm provides: session creation, message encryption/decryption, key exchange.
- Megolm provides: room-level group encryption with ratcheting sender keys.
- Key sharing via "room keys" (Megolm keys) distributed to room members.
- Device verification via cross-signing.

**What the server sees**:
- Encrypted event blobs (ciphertext only).
- Room membership lists (which users are in which rooms).
- Send/receive timestamps.
- Key share requests (but not the actual keys).

**Strengths**: Battle-tested in production by Element, Beeper, and many others. Good documentation.

**Weaknesses**: Olm's three-party DH is non-standard (Signal uses X3DH). Megolm's O(N) re-key cost on member removal. The architecture is complex with multiple layers.

### 4.2 libsignal (Signal)

**Repository**: https://github.com/signalapp/libsignal

**Architecture**:
- Rust implementation of Signal Protocol (X3DH + Double Ratchet + Sealed Sender).
- Contains: `signal-crypto` (AES-GCM primitives), `zkgroup` (zero-knowledge groups), `poksho` (ZK proof utilities).

**What it provides**:
- X3DH key agreement.
- Double Ratchet with sender key support (for groups).
- Prekey bundle management.
- Device sealing (hide sender identity from server).
- Zero-knowledge group membership proofs.

**What the server sees**:
- Prekey bundles (public keys published for key agreement).
- Encrypted message blobs.
- Optional: sealed sender hides the sender's identity from the server.

**Strengths**: Best-in-class implementation of the Signal Protocol. Well-audited Rust codebase.

**Weaknesses**: Server-side components are proprietary. Primarily a client-side library.

### 4.3 SimpleX (simplexmq)

**Repository**: https://github.com/simplex-chat/simplexmq

**Architecture**:
- **SMP (SimpleX Messaging Protocol)**: Relay server with anonymous queuing.
- **Agents**: High-level API layer that handles E2E encryption, queue management, and routing.
- Double Ratchet for E2E encryption (Curve448 keys + X3DH with 2 ephemeral keys per side + AES-GCM + SHA512 HKDF).
- 2-hop onion routing for sender privacy.
- NaCl `crypto_box` (Curve25519 + XSalsa20 + Poly1305) for relay-level encryption.

**What it provides**:
- Haskell server (`smp-server`) and client libraries.
- Anonymous messaging queues -- the relay has separate queue IDs for sender, recipient, and notifications subscriber.
- Relay does NOT know who is communicating with whom.
- Fixed-size 16KB blocks for traffic uniformity.
- The relay re-encrypts messages (proxy functionality) for anti-correlation.

**What the relay sees**:
- Encrypted queue contents.
- Queue access credentials (but not message content).
- Connection metadata (which can be mitigated via Tor/onion routing).
- The relay CAN correlate sender and recipient if it is the ONLY SMP server involved, but the 2-hop routing separates this.

**Strengths**: Unique privacy architecture where the relay genuinely cannot correlate sender and recipient (via 2-hop routing). Haskell implementation is clean and well-documented. Excellent threat model documentation.

**Weaknesses**: Haskell-only server limits deployment options. The protocol is complex. Smaller community than Matrix.

### 4.4 Session Protocol (Oxen)

**Architecture**:
- Built on **libsodium** for all cryptographic operations.
- **Closed groups**: Up to 100 members, with all group messages encrypted with a shared group key.
- **SOGS (Server of Servers)**: Decentralized swarm-based message storage. Messages stored on 5-7 nodes ("swarms"), automatically deleted after TTL.
- **Onion routing**: No single server knows both source and destination.

**What it provides**:
- E2E encryption using libsodium primitives.
- Decentralized storage (no central server).
- Closed groups with sender-key-like distribution.
- Account IDs separate from message content.

**What the relay sees**:
- Encrypted blobs only.
- Swarm metadata (which 5-7 nodes store a given message).
- No group metadata (no central server concept of "group").

**Strengths**: Large decentralized network (~1500 nodes). Strong privacy via onion routing.

**Weaknesses**: Closed groups have a 100-member cap. Protocol details are less formally documented than Signal or Matrix. Active development continues.

### 4.5 MLS Implementations

**OpenMLS** (https://github.com/openMLS) -- Rust implementation, production-quality.
**MLS.js** -- TypeScript implementation.
**Amazon s2n MLS** -- C implementation.

MLS is the newest approach and is gaining adoption. Key benefits: IETF standard, log-scale operations, formal security proofs, multiple independent implementations.

### 4.6 Comparison Matrix

| Project | Language | Group Chat | Relay Can Correlate? | Forward Secrecy | Maturity |
|---|---|---|---|---|---|
| libolm/Matrix | C/JS/Python/Rust | Megolm (Sender Keys) | Partially | Yes | Production |
| libsignal | Rust | Pairwise | Yes (with sealed sender: no) | Yes | Production |
| SimpleX | Haskell/Rust | Double Ratchet | No (2-hop) | Yes | Production |
| Session/Oxen | C++ | Closed Groups | Partially | Yes | Production |
| MLS (OpenMLS) | Rust | Tree-based | Server must be trusted for group ops | Yes | RFC 9420 |

---

## 5. Identity Bootstrapping

How does a new agent prove its identity to join a room?

### 5.1 First-Message Proofs

The simplest approach: the first message from a new agent is self-authenticating.

**Protocol flow**:
1. Agent generates identity key pair at first boot.
2. Agent sends first message to relay with: `(identity_pk, signature, timestamp, room_id)`.
3. Signature = `Ed25519Sign(identity_sk, "JOIN:" || room_id || timestamp || relay_pk)`.
4. Relay verifies signature matches a registered `identity_pk`. If not registered, the relay can:
   - Auto-register (if open membership).
   - Queue for approval.
   - Reject if rate-limited.

**Properties**: Simple. No pre-shared secrets. Relay can ban by identity_pk.

### 5.2 Referral from Trusted Agents

Agents that are already members can vouch for new agents.

**Protocol flow**:
1. Existing agent A generates a referral token: `Ed25519Sign(A_sk, "REFER:" || new_agent_pk || room_id || expiry)`.
2. New agent presents the referral token when joining.
3. Relay verifies A's signature and that A is a room member.
4. Relay registers new agent and grants room access.

**Properties**:
- Prevents Sybil by tying new identities to established ones.
- Similar to keybase-style proofs or Signal's invite system.
- The relay cannot create referrals without an existing trusted agent.

**Variants**:
- **Referral chains**: Trusted agent refers new agent, who then becomes trusted themselves.
- **Referral with rate limits**: Each trusted agent can only refer N new agents per time period.

### 5.3 Proof-of-Work / Rate-Limiting

To prevent Sybil attacks during open registration:

**Proof-of-Work**:
- Require the new agent to solve a CPU-intensive puzzle during key registration.
- Similar to Hashcash (used by Bitcoin) or CPace (password-authenticated key exchange).
- Adds computational cost to identity creation without pre-shared secrets.

**Rate-limiting**:
- Relay tracks registration rate per IP, per CIDR, per time window.
- CAPTCHA or proof-of-human for additional friction.
- Combined with PoW, makes mass identity creation expensive.

**Properties**: Not foolproof but raises the cost of Sybil attacks significantly.

### 5.4 Recommendation for c2c

For a c2c-style agent messaging system, the simplest and most practical approach is:

1. **First-message proofs** with Ed25519 identity keys -- sufficient for trusted environments.
2. **Referral from trusted agents** as an opt-in layer for tighter security.
3. **Rate-limiting** on the relay to prevent registration flooding.

ZK-based proof-of-work is powerful but adds complexity that is likely unnecessary for an agent-to-agent use case where the threat model is not "nation-state mass Sybil" but rather "unknown agents joining a relay."

---

## 6. Relay Server Threat Model

### 6.1 What the Relay MUST Be Able to Do

- **Store and forward encrypted blobs**: The relay receives ciphertext from sender agents and delivers it to recipient agents.
- **Authenticate agents**: Verify that messages come from registered agents (via signed messages or TLS client certs).
- **Ban agents**: Prevent banned agents from sending/receiving messages (by maintaining a blocklist of identity public keys).
- **Manage room membership**: Track which agents are members of which rooms, for routing purposes.

### 6.2 What the Relay MUST NOT Be Able to Do

- **Read message content**: The relay never receives plaintext. All messages are encrypted with E2E keys before leaving the sending agent.
- **Decrypt messages**: Even if the relay is fully compromised, E2E encryption ensures message content remains secret.
- **Correlate sender and recipient** (ideally): Through techniques like SimpleX's 2-hop routing or sealed sender, the relay should not know both the source and destination of a message.
- **Retroactively decrypt**: Forward secrecy ensures that compromise of current keys does not expose past messages.

### 6.3 Metadata the Relay WILL See (Unavoidable)

- **Timing**: When messages are sent and received (at minimum precision).
- **Connectivity**: Which agents connect to the relay and when.
- **Room membership**: Which agents are in which rooms (for routing).
- **Message size**: Rough size of encrypted blobs (mitigated by padding).
- **Relay operators can always drop or delay messages.**

### 6.4 Threat Model Summary

| Capability | Relay | Passive Network Observer | Active Network Attacker | Compromised Relay |
|---|---|---|---|---|
| Read message content | No | No | No | No |
| Correlate sender/recipient | No (SimpleX), Partially (Matrix) | No (TLS) | No (TLS) | Partially |
| Ban agents | Yes | No | Yes (traffic injection) | Yes |
| Drop messages | Yes | No | Yes | Yes |
| Retroactively decrypt | No (FS) | No | No | No |
| See message timing | Yes | Yes (if on path) | Yes | Yes |

### 6.5 Mitigation Strategies

- **Fixed-size message padding**: Prevents traffic analysis via message size.
- **Onion routing / 2-hop proxying**: Prevents relay from learning both endpoints (SimpleX approach).
- **Sealed sender**: The relay does not know who sent a message, only that it is for a specific recipient.
- **Noise traffic**: Random traffic to mask real communication patterns.
- **Tor / onion service deployment**: The relay can be deployed as a Tor hidden service to hide its IP address.

---

## 7. Networking

### 7.1 WebSocket (Recommended)

WebSocket (RFC 6455) is the standard choice for real-time bidirectional communication through NAT.

**Why WebSocket**:
- Works through most NAT and firewall configurations.
- Native browser support.
- Persistent connections allow push-style message delivery without polling.
- Fallback to HTTP long-poll for firewalled environments.
- Low overhead per message once connected.

**Protocol design**:
- Messages are binary-encoded encrypted blobs (MessagePack, Protocol Buffers, or CBOR).
- Framing: WebSocket handles framing; messages are application-level blobs.
- Heartbeat: Periodic ping/pong to detect connection death.
- Reconnection: Clients reconnect and request missed messages via sequence numbers.

**Libraries**:
- Rust: `tokio-tungstenite`, `websockets` (common with Rustls for TLS).
- Go: `gorilla/websocket`, `nhooyr.io/websocket`.
- Python: `websockets`, `aiodegui`.
- JavaScript: `ws`, browser native `WebSocket`.

### 7.2 Server-Sent Events (SSE)

SSE is a simpler alternative for server-to-client push. One-directional (server pushes to client). For c2c, WebSocket's bidirectional capability is more appropriate.

**When to use SSE**:
- When clients only need to receive messages (e.g., a monitoring agent that never initiates).
- When simplicity is preferred over bidirectional capability.

### 7.3 TLS Transport

All transport should be over TLS 1.3:

- Server authentication (clients know they are talking to the real relay).
- Transport confidentiality (prevents passive network observers from seeing message sizes and timing).
- Integrity protection.

**Note**: TLS protects transport but NOT message content (E2E encryption is separate). The relay still sees encrypted blobs over TLS.

### 7.4 Long-Poll Fallback

For firewalled environments where WebSocket connections are blocked:

- Client polls a REST endpoint for new messages.
- Server holds the request open (or returns quickly) until messages are available.
- Less efficient than WebSocket but more reliable.
- Many WebSocket libraries include long-poll fallbacks automatically.

### 7.5 DTLS for UDP

For low-latency requirements, DTLS (Datagram TLS) over UDP can replace TLS over TCP:

- Preserves message boundaries.
- No head-of-line blocking.
- Better for high-frequency, low-latency messaging.
- More complex to implement correctly through NAT.

**Recommendation for c2c**: WebSocket over TLS 1.3 is sufficient for most use cases. Add long-poll fallback for maximum compatibility. DTLS is overkill unless you have specific low-latency requirements.

---

## 8. Recommended Architecture for c2c

Based on the research, here is the recommended protocol stack for a c2c-style E2E encrypted relay:

### 8.1 Identity Layer

```
Agent:
  - identity_sk: Ed25519 private key (generated at first boot, stored locally)
  - identity_pk: Ed25519 public key (registered on relay)
  - (optional) device_sk / device_pk: for device-specific keys

Relay stores:
  - Map[alias -> identity_pk]
  - Map[identity_pk -> banned: bool]
```

**Flow**: Agent connects over TLS, signs a challenge with `identity_sk` to prove ownership of `identity_pk`. Relay verifies and establishes the session.

### 8.2 Session Establishment

Use X3DH for initial key agreement between two agents:

1. Alice retrieves Bob's prekey bundle from the relay: `(IK_B, SPK_B, OPK_B)`.
2. Alice generates ephemeral key `EK_A`.
3. Alice computes DH1-DH4 (as described in Section 2.1), derives shared secret `SK`.
4. Alice sends an initialization message containing `EK_A`, prekey IDs, and an initial ciphertext.
5. Bob receives, performs the same DH calculations, derives `SK`.
6. Both enter Double Ratchet mode.

**Alternative**: For simpler deployment, use Noise IK pattern at transport level, then use session keys for message encryption. libsodium's `crypto_box` can serve as the AEAD if Double Ratchet is deferred.

### 8.3 Message Encryption

Each message is encrypted using the Double Ratchet session:

```
sender:
  1. Derive message_key from current chain_key
  2. ratchet chain_key forward
  3. Encrypt: AEAD_Encrypt(message_key, plaintext, header)

header contains:
  - sender_ratchet_pubkey: current DH ratchet public key
  - previous_chain_length: PN (for skipped key recovery)
  - message_index: n (for ordering)
```

**Relay receives**: `header || ciphertext || auth_tag` (all opaque to relay).

### 8.4 Room Messaging

For rooms with multiple agents (c2c group messaging):

**Approach**: Megolm-style Sender Keys (Sender Key distribution)

1. **Room initialization**: When Alice creates a room, she generates a sender key `(sender_ratchet_pk, chain_key)`.
2. **Member join**: Existing members send their sender keys to the new member via pairwise Double Ratchet.
3. **Sending**: Sender ratchets their sender key, derives message key, encrypts message. Sends ciphertext + ratchet state to relay.
4. **Relay stores**: One ciphertext blob per sender (not one per recipient).
5. **Receiving**: Recipients receive the sender's ciphertext + state, derive the message key from the sender's sender key chain.
6. **Member removal**: All remaining members generate new sender keys for the removed member (O(N) cost).

**For rooms with >50 members**, consider migrating to MLS for O(log N) group operations.

### 8.5 Relay Server Design

```
Relay Server responsibilities:
  - Maintain registry: alias -> identity_pk
  - Maintain room membership: room_id -> [alias]
  - Message storage: per-room, per-sender message queues
  - Message delivery: push to connected clients, store for offline
  - Banning: blocklist of identity_pk
  - Rate limiting: per-IP registration limits

Relay Server does NOT:
  - Decrypt messages (never receives plaintext)
  - Know sender of a sealed-sender message
  - Correlate sender and recipient (with 2-hop routing)
```

### 8.6 Full Protocol Flow: Alice Sends a Message to Bob

```
1. IDENTITY BOOTSTRAPPING (once at first boot):
   - Alice generates (identity_sk_A, identity_pk_A)
   - Alice connects to relay, sends identity_pk_A + signed_proof
   - Relay stores (alice, identity_pk_A)

2. SESSION ESTABLISHMENT (X3DH):
   - Alice fetches Bob's prekey bundle from relay: (IK_B, SPK_B, OPK_B)
   - Alice generates EK_A
   - Alice computes SK = HKDF(DH1||DH2||DH3||DH4)
   - Alice sends init message: (EK_A, prekey_ids, ciphertext) to relay
   - Relay forwards to Bob
   - Bob computes SK, verifies, enters Double Ratchet

3. MESSAGE SENDING (Double Ratchet):
   - Alice derives message_key from chain_key
   - Alice ratchets chain_key
   - Alice encrypts: header || AEAD(message_key, plaintext, header)
   - Alice sends to relay

4. RELAY HANDLING:
   - Relay receives: room_id, sender_alias, header, ciphertext
   - Relay stores/forwards to room members
   - Relay cannot decrypt (no key material)
   - Relay updates room membership if needed

5. MESSAGE RECEIVING (Bob):
   - Bob receives header || ciphertext
   - Bob checks header: is this a DH ratchet step or symmetric ratchet?
   - Bob derives message_key, decrypts plaintext
   - Bob advances ratchet state
```

---

## 9. Libraries and Building Blocks

### 9.1 Cryptographic Libraries

| Library | Language | What It Provides | License | Recommendation |
|---|---|---|---|---|
| **libsodium** | C (+ bindings) | All primitives: X25519, Ed25519, AES-GCM, ChaCha20-Poly1305, HKDF, sealed_box, secret_box | ISC | **Primary crypto library** |
| **libsignal** | Rust (+ bindings) | X3DH, Double Ratchet, Sealed Sender, ZK proofs | AGPL-3.0 | Best Signal Protocol implementation |
| **libolm** | C | Olm (3-party DH), Megolm (Sender Keys) | Apache-2.0 | Matrix E2E reference |
| **OpenMLS** | Rust | MLS implementation (RFC 9420) | Apache-2.0 | Best for MLS |
| **ring** | Rust/C | Ed25519, X25519, AES-GCM, ChaCha20 | ISC/Apache-2.0 | Good Rust crypto |
| **cryptonum** | Rust | Post-quantum crypto (Kyber, Dilithium) | Apache-2.0 | For post-quantum E2E |
| **noiseprotocol** | Rust | Noise Protocol Framework | MIT | Noise IK pattern |

### 9.2 Protocol Libraries

| Library | Language | What It Provides | License |
|---|---|---|---|
| **signal-protocol-rs** | Rust | X3DH, Double Ratchet | MPL-2.0 |
| **hqx** | Rust | Matrix protocol (Olm/Megolm) | AGPL-3.0 |
| **mls-implementations** | Rust/C | MLS | Apache-2.0 |
| **simplexmq** | Haskell | SMP protocol, agent layer | AGPL-3.0 |
| **smp.rs** | Rust | SimpleX SMP client | AGPL-3.0 |

### 9.3 Networking Libraries

| Library | Language | What It Provides |
|---|---|---|
| **tokio-tungstenite** | Rust | WebSocket server/client over Tokio |
| **gorilla/websocket** | Go | WebSocket server/client |
| **websockets** | Python | WebSocket server/client (async) |
| **ws** | JavaScript | WebSocket client |

### 9.4 Full-Stack References

| Project | Repo | Language | Best For |
|---|---|---|---|
| **libolm** | matrix-org/libolm | C | Matrix E2E encryption |
| **SimpleX Chat** | simplex-chat/simplex-chat | Haskell/Rust | Privacy-preserving relay |
| **Briar** | briar/briar | Java | Secure messaging with offline delivery |
| **nheko** |/nheko/nheko | C++/Qt | Matrix client with E2E |
| **Element** | vector-im/element-web | TypeScript | Matrix client reference |

---

## 10. Feasibility Assessment

### 10.1 What's Feasible to Build From Scratch

**Low complexity** (can be implemented directly):
- Ed25519 identity key generation and registration (1-2 days).
- libsodium `sealed_box` / `secret_box` for static-key encryption (1 day).
- WebSocket relay server that stores and forwards opaque blobs (1-2 days).
- Room membership tracking (1 day).

**Medium complexity** (requires care but doable):
- Double Ratchet implementation (1-2 weeks to implement, test, and audit).
- X3DH key agreement (1 week).
- Sender Key room encryption (Megolm-style, 1-2 weeks).
- Banning via identity public key blocklist (1 day).

**High complexity** (use existing libraries):
- Full Signal Protocol (libsignal) -- do not implement from scratch.
- MLS (OpenMLS) -- use the library.
- Post-quantum key exchange (Kyber/X25519) -- use an established library.
- Onion routing (2-hop proxy) -- adapt from SimpleX's approach.

### 10.2 What's NOT Recommended to Implement From Scratch

- **Cryptographic primitives** (AES, ChaCha20, Ed25519, X25519) -- use libsodium or ring.
- **Signal Protocol** (X3DH + Double Ratchet) -- use libsignal.
- **Olm three-party DH** -- use libolm or replace with standard X3DH.
- **Post-quantum crypto** -- use established libraries (cryptonum,oqx).

### 10.3 Recommended Implementation Path for c2c

**Phase 1: Minimum Viable E2E Relay** (1-2 weeks)
1. Ed25519 identity key pairs for agents.
2. Relay stores and forwards encrypted blobs.
3. libsodium `secret_box` with a shared room key for simplicity (NOT forward secret yet).
4. Room membership management on relay.
5. WebSocket transport over TLS.

**Phase 2: Proper E2E Encryption** (2-3 weeks)
1. Integrate libsignal (Rust) for X3DH + Double Ratchet.
2. Replace shared room key with per-sender ratcheting.
3. Add device verification and key fingerprints.
4. Implement sealed sender (hide sender from relay).

**Phase 3: Group Messaging** (2 weeks)
1. Implement Megolm-style Sender Keys.
2. Handle member join/leave with sender key rotation.
3. Key distribution to new members via pairwise Double Ratchet.
4. Evaluate MLS for larger groups.

**Phase 4: Privacy Hardening** (1-2 weeks)
1. 2-hop onion routing for sender/recipient unlinkability.
2. Fixed-size message padding.
3. Noise traffic generation.
4. Rate limiting on registration.

---

## 11. Protocol Flow Summary

### Agent Registration (One-Time)

```
agent:
  identity_sk, identity_pk = Ed25519.generate()
  signed_proof = Ed25519Sign(identity_sk, "REGISTER:" || relay_id || timestamp)

relay (on connection):
  verify Ed25519Verify(signed_proof, identity_pk)
  store (alias, identity_pk)
```

### Session Establishment (X3DH)

```
alice:
  bundle = relay.get_prekey_bundle(bob)
  EK_A = X25519.generate_ephemeral()
  DH1 = X25519.dh(EK_A, bundle.spk)
  DH2 = X25519.dh(identity_sk_A, bundle.ik)
  DH3 = X25519.dh(EK_A, bundle.ik)
  DH4 = X25519.dh(EK_A, bundle.opk)  # if available
  SK = HKDF(DH1 || DH2 || DH3 || DH4)
  send: EK_A, prekey_ids, ciphertext = AEAD(SK, plaintext, AD=IK_A || IK_B)

bob (on receive):
  DH1 = X25519.dh(spk, EK_A)  # etc.
  SK = HKDF(...)  # same as alice
  plaintext = AEAD_Decrypt(SK, ciphertext, AD)
  enter Double Ratchet with SK
```

### Direct Message (Double Ratchet)

```
sender:
  mk = ratchet_symmetric()
  ct = AEAD_Encrypt(mk, message, header)
  send: room_id, header, ct
  advance ratchet state

relay:
  store/forward: room_id, sender_alias, header, ct
  (relay cannot read ct or header content)
```

### Room Message (Sender Keys / Megolm)

```
sender:
  sk = get_sender_key(room_id, sender_alias)
  ratchet_sender_key(sk)
  mk = derive_message_key(sk)
  ct = AEAD_Encrypt(mk, message, sender_ratchet_state)
  send: room_id, sender_alias, sender_ratchet_state, ct

relay:
  store/forward per room, one ct per sender
  (relay knows room_id, sender_alias, ct size -- not content)

recipient:
  receive: sender_ratchet_state, ct
  derive mk from stored sender_key + received ratchet_state
  decrypt
  update stored sender_key
```

---

## 12. Key Design Decisions

| Decision | Recommended Choice | Rationale |
|---|---|---|
| Identity system | Ed25519 key pairs | Simple, self-contained, no PKI needed |
| Transport | TLS 1.3 + WebSocket | NAT-friendly, well-supported |
| Key exchange | X3DH | Standard, handles async, post-compromise recovery |
| Message encryption | Double Ratchet | Forward secrecy + post-compromise security |
| Group encryption | Megolm-style Sender Keys | Simple, efficient for c2c scale |
| Crypto library | libsodium | Battle-tested, all-in-one, good bindings |
| Signal Protocol impl | libsignal | Do not reimplement -- use the library |
| Room membership | Relay tracks aliases, not content | Relay routes but never decrypts |
| Sealed sender | Yes | Relay does not know message author |
| Message padding | Fixed-size | Prevents traffic analysis via size |

---

## Sources and References

### Protocol Specifications

1. [Signal X3DH Key Agreement](https://signal.org/docs/specifications/x3dh/) -- The official X3DH specification defining the 4-DH key agreement for asynchronous settings.
2. [Signal Double Ratchet Algorithm](https://signal.org/docs/specifications/doubleratchet/) -- The complete Double Ratchet algorithm with DH ratchet, symmetric ratchet, and skipped keys.
3. [MLS RFC 9420](https://www.rfc-editor.org/rfc/rfc9420) -- The IETF standard for Messaging Layer Security with tree-based group key exchange.
4. [Noise Protocol Framework](https://noiseprotocol.org/) -- Framework for building crypto protocols with configurable authentication and forward secrecy.
5. [SimpleX Messaging Protocol (SMP)](https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/protocol/simplex-messaging.md) -- Protocol specification for the SimpleX E2E messaging architecture with anonymous queues.
6. [SimpleX Overview](https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/protocol/overview-tjr.md) -- Design goals, comparison with Signal/Matrix, and threat model documentation.

### Implementation Repositories

7. [libsignal](https://github.com/signalapp/libsignal) -- Rust implementation of the Signal Protocol (X3DH, Double Ratchet, ZK proofs).
8. [libolm](https://github.com/matrix-org/libolm) -- C implementation of Olm and Megolm cryptographic protocols for Matrix.
9. [simplexmq](https://github.com/simplex-chat/simplexmq) -- Haskell implementation of SimpleX Messaging Protocol and Agents.
10. [OpenMLS](https://github.com/openMLS) -- Production-quality Rust implementation of MLS (RFC 9420).
11. [session-server](https://github.com/oxen-io/session-server) -- Session Protocol's server-of-servers for decentralized message storage.

### Documentation and Analysis

12. [Signal Private Groups](https://signal.org/blog/private-groups/) -- Technical description of Signal's pairwise group messaging approach.
13. [libsodium Sealed Box Documentation](https://doc.libsodium.org/public-key_cryptography/sealed_boxes) -- API and security properties of anonymous encryption.
14. [Matrix E2E Encryption](https://spec.matrix.org/latest/specification/protocol_layers/e2ee/) -- Matrix's end-to-end encryption architecture.
15. [Session FAQ](https://getsession.org/faq) -- High-level description of Session protocol's E2E encryption and closed groups.

---

*Research compiled 2026-04-15. This document reflects the state of the art as of early 2026. MLS is the most recently standardized (2023), Signal Protocol has been in production since 2013, and Matrix E2E since 2016.*
