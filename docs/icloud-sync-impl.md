# iCloud sync (implementation)

Implemented on this branch. Design: `docs/design/icloud-sync.md` on
`docs/design-icloud-and-ai` (PR #21).

- `CloudKitSyncEngine` + `SyncEngineProvider` select local vs iCloud from
  `AppSettings.syncMode` (`AppSettings+Sync.swift`).
- Container: `iCloud.com.jupiterjvck.iterminal`. Entitlements in
  `Resources/iTERMiNAL.entitlements`; App Sandbox stays off; Hardened Runtime on.
- Payload is `WorkspaceArchive` JSON (same as Export). Secrets / keychain /
  `composerShell` are never synced.
- Unsigned or CI builds (`CODE_SIGN_IDENTITY "-"`) report iCloud unavailable
  and stay local-only; Settings explains why.
