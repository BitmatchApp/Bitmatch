# Destination self-test: proposed contract

Status: design only. This is not a hardware certification or an implemented user action.

The operator explicitly selects a destination and starts the check. Generate a bounded internal source fixture, never on a card, and write only under an exclusively created, ownership-marked test root. Reuse the production copy, independent readback, and evidence paths. Include empty files, chunk boundaries, Unicode names, many small files, and moderate files; disclose fixture size, expected coverage, and the selected location before starting.

Record each stage and compare the actual results with the complete planned fixture. An incomplete plan, failed write or readback, cancellation, unavailable evidence, identity change, or conflicting output cannot produce a pass. Explain separately when media readback succeeded but an optional report or manifest could not be saved. Do not update prior transfer evidence or the current card's safety state.

On cancellation or failure, retain a truthful result and enough ownership evidence for later inspection. Cleanup may remove only the exact pinned and revalidated root and entries created by this attempt. A changed identity, unexpected entry, symlink, replaced root, or uncertain ownership prevents automatic cleanup and is surfaced to the operator. Never delete or modify another writer's data.

Report that an internal fixture does not exercise the card, reader, camera data, all file sizes, power-loss durability, or every future transfer. A small successful check cannot establish large-transfer memory bounds. Offer privacy-safe diagnostics without automatically uploading them.

Before release, cover output races, unknown contents, interrupted writes and cleanup, device removal, source and destination replacement, low space, permissions, report failures, restart, and all supported platform file-provider restrictions. Run larger fault and stress cases separately on marked disposable media.
