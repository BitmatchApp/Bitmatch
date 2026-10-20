# BitMatch project guidance

Read [docs/THESIS.md](docs/THESIS.md) first. It states what BitMatch promises and the current plan for bringing the code in line with it.

## Platform scope

macOS, iPad, and iPhone are core product targets. New features and UI improvements should generally work on all three. The `BitMatch-iPad` target supports both iPhone and iPad despite its name.

- Plan the source selection, destinations, verification, queue, recovery, history, and reporting workflow across all three platforms before implementing changes.
- Share transfer logic, safety rules, state, and presentation models where practical. Adapt layout and navigation to each platform.
- Design for a narrow iPhone screen, iPad multitasking widths, and resizable Mac windows. Essential information and actions must work with touch and without hover.
- Respect iOS file-access and background-execution constraints. Explain actual limitations and preserve recoverable state; do not promise unattended work the platform cannot support.
- Existing Mac-only capabilities, such as SFTP uploads, are explicit exceptions. Do not silently make a new core workflow Mac-only.
- Validate shared changes with the Mac tests and iOS build as appropriate. For UI changes, check iPhone and iPad layouts as well as Mac; distinguish simulator/build validation from physical-device testing.

Keep the product simple on every platform: choose a source, choose backups, copy and verify, review the outcome.

## Local validation

GitHub Actions CI is intentionally disabled. Run the required engine, Mac and iPhone/iPad checks locally and record their exact results and limits. Local validation remains required before merging or releasing.

Do not repair GitHub runners, spend Actions credits or re-enable CI unless Mike explicitly asks. Preserve the local test scripts and release process.
