> **Status: Reduced to a benchmark task.** Parked on 2026-10-21 after review. Not scheduled. The original proposal follows unchanged below the line.
>
> **Blockers found in review**
> - Every byte must still be read to hash it and SHA-256 still runs on every match, so the clean path gains nothing; the corrupt path saves hash CPU on a rare event.
> - "Fails in microseconds" is wrong for multi-GB clips.
> - xxHash64 already exists in the engine (SavedChecksumCheck.swift).
>
> **Worth keeping:** The benchmark gate is the keeper: measure on two real drives whether hashing or I/O is the bottleneck. This fits the engine-performance item in the feature-freeze list.
>
> **Un-park when:** The benchmark shows hashing, not I/O, bounds verify throughput on representative media.

---

# 3. Fast-hash first pass

## Goal

Catch copy mismatches with a fast non-cryptographic digest *before* paying for the verdict
digest, so a mismatched file fails in microseconds — without ever weakening the SHA-256
verdict or the independent readback.

## Scope

**In scope**

- A fast digest (xxHash64) computed during the copy pass and on readback, used only as a
  **mismatch pre-filter**.
- A `FastHasher` abstraction in the engine so the algorithm is swappable and testable.
- Optional emission of the fast digest into MHL output as an *additional* field, never as a
  replacement for the required digest.
- A benchmark gate that decides whether the pre-filter actually ships as the default.

**Out of scope**

- Replacing SHA-256 (Standard) or SHA-256+MD5 (Thorough) as the verdict digest.
- Changing the verdict semantics of any existing mode.
- Using a fast hash alone as evidence. A fast-hash match is never a green.

## Where it lands

- `Packages/BitMatchEngine/Sources/BitMatchEngine/ChecksumEngine.swift` (or a sibling
  `FastHasher.swift`) — the `FastHasher` protocol and its xxHash implementation.
- `Packages/BitMatchEngine/Sources/BitMatchEngine/File/DestinationWriter.swift` — the
  pre-filter in the verify path (`verifyPinnedDestinationFile`).
- `Packages/BitMatchEngine/Sources/BitMatchEngine/Evidence/ASCMHLGenerator.swift` — optional
  extra digest field, only where the chosen format permits it.

## Design

### The pre-filter

The verify path for a freshly copied file today computes the verdict digest(s) on the
destination read. The pre-filter splits that into two steps:

1. **Fast pass.** Compute xxHash64 over the destination file while it is already being read.
   Compare it to the xxHash64 computed during the copy pass.
2. **Verdict pass.** If the fast digests **mismatch**, the file is definitively mismatched —
   skip the expensive digest and record `checksumMismatch`. If they **match**, run the full
   SHA-256 (and MD5 where required) and record the verdict from that.

A fast-hash *match* is never treated as verification; it only lets the expensive digest run on
files that are plausibly intact. A fast-hash *mismatch* is a definitive mismatch because any
difference in bytes is a difference in the fast digest, and a false fast-match is harmless
(the SHA-256 still runs).

```swift
// Packages/BitMatchEngine/Sources/BitMatchEngine/FastHasher.swift
public protocol FastHasher: Sendable {
    func reset() async
    func update(_ bytes: [UInt8]) async
    func finalize() async -> UInt64
}

public struct XXHash64FastHasher: FastHasher { /* 64-bit xxHash, streaming */ }
```

```swift
// DestinationWriter — pre-filter sketch
func verifyPinnedDestinationFile(_ file: DestinationFile) async -> FileVerification {
    // 1. Read the destination bytes once.
    // 2. Feed the same bytes to the FastHasher; finalize.
    // 3. If fastDigest != expectedFastDigest { return .mismatch }
    // 4. Else compute the verdict digest(s) over the bytes and return the real result.
}
```

The `ChecksumEngine` gains a parallel "fast" lane. The fast hash is computed on the *same*
bytes the verdict digest will see, so there is no extra read and no TOCTOU between the two.

### MHL emission

Where the MHL format has room for extra fields, emit the fast digest as an additional,
clearly-labeled field alongside the required SHA-256 (and MD5 where the format requires it).
Never emit only the fast digest. A reader that does not know the extra field ignores it; a
reader that requires SHA-256 is unchanged.

## Safety & verdict semantics

- The verdict is still `ResultOutcome` from the SHA-256 (or SHA-256+MD5) result. The fast hash
  changes only *how fast* a mismatch is found.
- A fast match does not advance the file to `verified`; the full digest must still pass.
- `Quick` mode (size-only) is unaffected and still never earns a safe verdict.
- Independent readback is unchanged: the fast pass reads the same destination bytes as the
  verdict pass, and Thorough/Paranoid still re-read the source where they do today.

## The gate (do not skip this)

The pre-filter is only worth shipping if it **replaces measured work**. It does not when the
verdict digest is already I/O-bound (reading the bytes dominates, not hashing). Before making
it the default:

1. Run a representative two-drive physical benchmark through a final verdict, recording source
   read, hashing, destination write/readback, MHL/report time, overlap, per-drive rates, peak
   memory, and CPU, in both warm and cold cache conditions.
2. Compare "SHA-256 only" vs "xxHash pre-filter + SHA-256 on matches", including a
   deliberately corrupted file so the fast path is exercised.
3. Ship the pre-filter only if the mismatch path measurably improves without regressing the
   clean path. Otherwise keep the code behind a disabled-by-default flag and revisit when the
   benchmark justifies it.

Do not change the verification *default* based on a microbenchmark.

## Acceptance criteria

- **Correctness:** a corrupted file is reported `checksumMismatch` via the fast path without
  running the verdict digest; an intact file still runs the verdict digest and reports
  `verified`. `Plant:` make the fast hasher always return a constant and see the intact-file
  test fail (or the mismatch test fail) — both must be exercised.
- **No false green:** a file whose fast hash matches but whose SHA-256 mismatches is still
  `checksumMismatch`. `Plant:` skip the SHA-256 when the fast hash matches and see the test
  fail.
- **MHL:** the emitted inventory always contains the required SHA-256; the fast digest is an
  extra field and its absence or presence never breaks a SHA-256-only reader.
- **Engine isolation:** `FastHasher` has no UI imports and lives in the engine package.

## Validation gates

- `bash test.sh engine-test`, `bash test.sh mac-test`, `bash test.sh ipad-build`.
- The physical benchmark above, recorded in `docs/validation/`, before any default change.
- Confirm `Quick` and `Paranoid` semantics are byte-for-byte unchanged.
