# Portable destination configuration: proposed contract

Status: design only. Folder-layer export/import is in progress; portable destination configuration is not implemented.

Export a bounded, versioned description of reusable requirements, not an existing job or destination record. The portable form may describe generic local backup slots and the required local-copy count. It must not contain paths, volume or device identifiers, bookmarks, credentials, account or server details, private names, report fields, or transfer evidence. Unknown fields and unsupported versions fail closed. Define and validate the allowed slot count and copy-count relationship before accepting an import.

Preview additions and preference changes before applying them. Create a new, locally named configuration with fresh IDs and empty slots; never replace an existing configuration or select it automatically. Persist the configuration and its settings as one logical operation, or leave both unchanged on failure. A version 1 or folder-recipe-only file leaves destination configurations untouched.

When an operator later chooses the configuration, ask them to select each local destination on the receiving device. Obtain access and rerun existing location, overlap, available-space, ownership, and independence checks at preparation and Start. Empty slots, unknown physical independence, missing permissions, or stale identities cannot silently satisfy a required-copy safety gate. Preserve valid ordinary transfers and make any project-specific requirement explicit.

Exercise malformed and oversized inputs, unknown fields, duplicate imports, naming collisions, store failure and restart, stale preview, busy work, changed destinations, same-drive folders, unresolved and composite identity, and missing permissions. Check Mac, iPhone, and iPad layouts and persistence. Export tests must assert that private paths, identifiers, credentials, and prior transfer records never appear.
