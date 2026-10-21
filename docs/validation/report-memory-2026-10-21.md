# Actual-app report memory hold — October 21, 2026

A retained Mac app-host stress run crossed its test memory guard while generating the requested PDF report for a 20,000-file transfer. This is a controlled local test failure. It is not an OS crash and does not reproduce field report #23.

## Workload and result

Gate `mac-manyfiles-20261021T053629Z` ran one selected `CoordinatorManyFilesMemoryTests` XCTest from source commit `6ca018015bc75427c3349b2177b9a34e1e37f6ba`. XCTest reported **one test, zero skips, one failure**, after **763.822 seconds**. Its 20,000 synthetic 1 KiB source files were copied and verified to two host-filesystem destinations (40,000 result rows); abstract disk identities made the two-destination workflow eligible, so this is not independent physical-backup coverage.

The first report-off transfer passed in **288.020 seconds**, with **2,281 active-view renders** and **1,572 progress updates**. The second transfer had completed copy and verification before reporting began: the process monitor was at **392 MiB** after copy/verification and **421 MiB** at `reportStarted`. The unchanged **1 GiB test guard** later latched at **1,099 MiB**; later diagnostic samples reached **1,309 MiB**. The test failed with `memoryLimit` and cancelled its owned work. The guard is a cooperative test guard, not an OS memory cap. ASC MHL and PDF thumbnails were disabled for both passes.

The report event establishes that the test crossed its guard during the report-enabled phase, after copy and verification. The exact PDF subphase and allocation cause remain unknown. The source candidate's optional renderer phase observer and 40,000-row probe were not built or run, and no production memory fix is established.

## Separate evidence and limits

A private test-only diagnostic recorder reported an error during the first, report-off pass, before the report-enabled run. Its cause is unknown. It is separate from the memory-guard failure and is not evidence of an app-startup failure or PDF cause. No default/user log was read or repaired. The test fixture and failure evidence were retained.

The separately prepared `mac-pdf-scale` phase-probe gate remains unrun: its first launch was refused by the host-space floor. At 06:17 UTC, host free space was about 36 GiB against the 50 GiB external-build stop floor, so further builds remain paused. This resource pause is independent of the completed app-host XCTest and does not change its result. The phase observer remains unbuilt; no compiler, app or memory run is claimed for it.

This synthetic app-host workload does not establish behavior on the reporter's machine or reproduce #23. The reported app version and failing phase remain unknown. Keep #23 open and retain the fixture until phase-specific evidence supports any bounded fix. Draft PRs #79, #80 and #81 remain held; this record authorizes no merge or release. GitHub Actions CI was not run.
