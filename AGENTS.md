# TokenMeter repository guidance

## Scope and structure

- The active app is the native Swift implementation under `swift/`. Tauri code belongs to the historical branch.
- Read `docs/architecture.md` and `docs/development.md` before structural changes. Keep view presentation, pure models, service IO and shell lifecycle responsibilities separate.
- Preserve unrelated work. Avoid broad AppState/provider refactors during a focused fix; move complete types when organizing files.
- `swift/project.yml` is the editable XcodeGen definition and version source. Regenerate with `make project` and commit the generated `swift/TokenMeter.xcodeproj` changes together. Preserve the established Bundle ID and Keychain identity.

## Validation

- Use the root Makefile. `make test` runs XCTest; `make release-check` also builds Release and verifies metadata.
- UI checks use `make ui-smoke`, `make ui-render` or `make ui-render-overview`. These force Debug and isolate configuration, history, collectors and account access.
- Never use normal startup or Release preview flags as a substitute for isolated validation. Do not access real sessions or accounts merely to validate a layout.
- Keep meaningful tests for windows, source filters, read failures, asynchronous refresh results and update trust/rollback. Mechanical moves do not need tests that merely duplicate code.
- Build/test/fixture success does not establish signing, notarization, real installation, updates or account behavior. Follow `docs/release.md` for those checks.

## Data and compatibility

- Never commit credentials, certificate material, real session logs, personal screenshots or private diagnostics. Public UI examples use synthetic data.
- A read failure must not overwrite a previous successful snapshot with zero. Keep unavailable/loading/error states distinct from confirmed zero.
- Optional live quota queries must respect user opt-in and discard obsolete asynchronous results. Preserve validation-environment early returns.
- Maintain updater publisher identity, Bundle ID/version/architecture checks, safe staging and rollback. Do not bypass signing checks, remove quarantine or request elevation to make tests pass.
- API reference prices are estimates, not bills. Append dated price snapshots; do not rewrite historical prices or infer absent cache metrics.
- Update the relevant guide when behavior changes. Keep CHANGELOG history and original MIT attribution.

Local plans, review output, screenshots and build products remain ignored. Do not delete caches, history, branches or user data as part of routine cleanup.
