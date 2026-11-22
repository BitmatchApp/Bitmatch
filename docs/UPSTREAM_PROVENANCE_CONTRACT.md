# Upstream source evidence: proposed contract

Status: design only. Existing Check reads supported saved inventories; it does not establish camera-origin provenance.

The operator may choose an inventory supplied with or before the media. Read it as untrusted, bounded input, and show its format, supported algorithms, recorded scope, and origin as supplied. Check path safety, exact selected-file coverage, sizes where recorded, all supported supplied digests, and unchanged evidence and media across the check. Unsupported records, conflicting values, malformed or incomplete input, and unavailable files must produce an explicit incomplete or failed evidence result rather than a partial match.

A match means the observed source bytes match the supplied inventory within its declared scope. An unsigned inventory does not authenticate its creator, prove custody, or prove the camera originally captured correct bytes. A BitMatch inventory generated after arrival is evidence of unchanged content since that recording, not independent pre-arrival provenance. Chain consistency does not establish authenticity or prove an unanchored tail was never removed.

Keep this verdict independent from the transfer's preservation outcome. A malformed or mismatched manifest must not prevent the operator from making verified backups of damaged but irreplaceable media. Retain the source-evidence result and any warnings in the new attempt's History and exports without converting it into a stronger safe-to-erase claim.

Only reuse digests already computed during a transfer when the exact source file identity, complete byte range, algorithm, ordering, and unchanged state are proven for both uses. Otherwise perform the separate read. Do not infer identity from path or timestamps alone, and never reuse partial hashes after a read fault.

Before release, use independent writer fixtures and schema checks, corruption and truncation controls, conflicting algorithms and sizes, unsafe paths, replaced manifests and media, incomplete scopes, cancellation, and app restart. Exercise all platforms and document whether evidence and media were checked independently. Keep physical-device, reference-tool, and synthetic results separate.
