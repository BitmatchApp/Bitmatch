# Remote monitoring: proposed protocol contract

Status: design only. Remote monitoring, pairing, and controls are not implemented by this document. The Mac remains the sole authority for transfers, storage, journal, and verdicts.

## Discovery and pairing

The host advertises only an opt-in, operator-chosen station alias and connection information. Discovery alone grants no access. Pair using a short-lived, single-use code or QR that binds an authenticated encrypted session to the host's persistent identity and the client's identity; use platform cryptography and a reviewed pairing protocol, not a custom cipher. Display the devices being paired on both sides. Limit attempts and lifetime, handle simultaneous pairing and cancellation, and persist only the credentials needed for later authentication in platform credential storage.

The host lists paired clients, supports individual revocation, and stops accepting a revoked client's sessions and requests. Rotate or invalidate session credentials on revocation and reject old sessions after host identity changes. Disabling the host stops discovery and listening. Do not send user files, paths, reports, or diagnostics as part of discovery or pairing.

## Read-only session

After authentication, send a bounded snapshot with host identity, session identity, a monotonically increasing state revision, and an explicit snapshot time. Send only data needed for the current screen; use opaque host-generated IDs, privacy-safe names, and bounded pagination for History. Client caches belong to that exact host and session and never establish a new card's verdict.

Updates carry the host/session identity and revision. Coalesce progress updates and bound queues; preserve terminal transitions and require a fresh snapshot when a gap, overflow, reconnect, host restart, or incompatible protocol version prevents reconciliation. Duplicate or out-of-order messages never roll state backward. A stale connection, old 100% progress, a timeout, or a client backgrounded by iOS cannot imply completion. Present connection freshness separately from the authoritative transfer phase, operator-needed reason, and recorded verdict.

No remote control is included in the first monitoring slice. Host sleep, quit, disconnection, network changes, and client suspension mark information stale without changing Mac work. Networks that block Bonjour or peer traffic need a clear connection error; direct USB networking is not promised without public-API evidence.

## Later commands

Each future mutation carries an authenticated client identity, a stable request ID, opaque host-side resource IDs, and the relevant operation or queue revision. The host persists or otherwise durably reconciles idempotency results before reporting an irreversible success. On retries, return the original result or a clear unknown/reconciliation state; never execute a duplicate Start, cancel, or retry merely because a response was lost. Reject stale or unauthorized requests, and revalidate permissions, identity, readiness, overlap, no-overwrite rules, and media at execution time. Confirmation-sensitive actions require explicit operator confirmation. Disconnected clients cannot submit commands.

## Validation gates

Review the selected pairing protocol, key storage, discovery privacy, revocation, and local-network declarations before release. Exercise replay, expired codes, wrong hosts, stale identities, revoked clients, concurrent clients, restart, missed and reordered events, queue overflow, delayed snapshots, background suspension, and network changes. Future command tests must also cover duplicate IDs, stale revisions, replaced media, permission loss, failed preflight, collision and overwrite attempts, and cancel/retry races. Verify narrow layouts, Wi-Fi and wired Ethernet, and real iPhone/iPad background behavior separately from simulators. Do not add a relay, daemon, screen-control layer, filesystem browser, or automatic card formatting to this scope.
