# Per-transfer result lookup

The coordinator kept partial-attempt results by scanning the growing row array
for every copy and verification callback. For 20,000 files and two destinations,
that means 80,000 updates to 40,000 final rows and quadratic lookup work on the
main actor.

The store now indexes the exact existing key: source path plus optional full
destination path. It preserves arrival order, replaces the first matching row,
and rebuilds the first-duplicate index when authoritative results replace the
list. Nil, empty and case-different paths remain distinct. No path normalization,
result replacement policy or verification behavior changed.

Four normal regressions passed: copy-to-verification replacement and order;
destination/nil/empty/case distinctions; replacement with duplicate keys; and
clearing followed by reuse. They have no timing thresholds.

An isolated optimized Swift executable used the exact production store and
`ResultRow` bodies with synthetic identifiers. The same 80,000 callbacks took
4.724–6.816 seconds with the original linear scans and 0.024–0.027 seconds with
the index. These observations were collected on a shared Mac alongside other
validation/build work. They are not app throughput benchmarks or a promised
speedup for transfers. The original body and compiled probe receipts were
retained privately.

The live published feed was measured separately and remains unchanged. Its
80,000 updates took 33.176 seconds with a sampled peak process footprint of
about 44 MiB in the isolated executable. Published-array update cost remains a
separate performance question. Neither measurement demonstrates a memory leak,
establishes issue #23's cause, or proves the complete app has bounded memory.
