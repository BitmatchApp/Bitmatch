# Supported ASC handoff workflow

BitMatch supports exactly one professional handoff workflow. Anything outside
it is refused or reported, never silently claimed.

## Supported

1. BitMatch copies a card to local backups and verifies every file with
   SHA-256. Local-copy verification is reported on the completion screen, in
   history, and in transfer exports, independently of anything below.
2. For each fully verified destination, BitMatch writes an **initial ASC MHL
   2.0 inventory** (`ascmhl/` with a C4-protected chain). Generation details,
   limits, and the recorded official-reference validation live in
   [README.md](README.md).
3. The receiver validates the inventory with the official ASC tooling
   (`ascmhl verify`, `ascmhl diff`) or their production pipeline before
   treating the media as handed off. Handoff status is the receiver's
   verdict, not BitMatch's local verification.

## Explicitly unsupported

- Appending to, merging, flattening, importing, or validating inherited
  histories. Existing destination histories are preserved and reported as
  unsupported; retries can recheck copies without creating new ones.
- Chain-of-custody tracking across handoffs. BitMatch does not claim it.
- Acceptance by receiving tools (Hedge/OffShoot, ShotPut Pro, Silverstack),
  production camera media, or physical iOS storage. Those checks are
  outstanding; see the validation register before relying on this workflow
  for paid work.

## Acceptance checklist for widening scope

- [ ] Round-trip: BitMatch inventory verified by at least one receiving tool.
- [ ] Representative production media (large video files, camera card
      structures with sidecars) through the same path.
- [ ] Physical cards and readers, including disconnect/reconnect and full
      destinations.
- [ ] Documented behavior for each unsupported case encountered, with
      regression tests.
