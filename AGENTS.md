# TokenMeter repository guidance

## Scope and structure

- The active app is the native Swift implementation under `swift/`. Tauri code belongs to the historical branch.
- Read `docs/architecture.md` and `docs/development.md` before structural changes. Keep view presentation, pure models, service IO and shell lifecycle responsibilities separate.
- Preserve unrelated work. Avoid broad AppState/provider refactors during a focused fix; move complete types when organizing files.
- `swift/project.yml` is the editable XcodeGen definition and version source. Regenerate with `make project` and commit the generated `swift/TokenMeter.xcodeproj` changes together. Preserve the established Bundle ID and Keychain identity.

## Validation

- Use the root Makefile. `make test` runs XCTest; `make release-check` also builds Release and verifies metadata.
- UI checks use `make ui-smoke`, `make ui-render` or `make ui-render-overview`. These force Debug and isolate configuration, history, collectors and account access.
- `make ui-render-determinism` (run in CI) asserts same-build renders agree under a three-run consensus (identical in two runs; a two-run mismatch is arbitrated by a third to absorb macOS glyph-raster jitter); render paths must consume the frozen render clock (`PreviewData.renderNow` / injected `usageNow`), never a live `Date()`.
- Never use normal startup or Release preview flags as a substitute for isolated validation. Do not access real sessions or accounts merely to validate a layout.
- Keep meaningful tests for windows, source filters, read failures, asynchronous refresh results and update trust/rollback. Mechanical moves do not need tests that merely duplicate code.
- Build/test/fixture success does not establish signing, notarization, real installation, updates or account behavior. Follow `docs/release.md` for those checks.

## Engineering contract

- Prefer the smallest change that makes an invalid state or dependency impossible. Turn repeated, objectively detectable mistakes into focused tests or static checks; do not grow prose rules as a substitute for enforcement.
- Keep UI code behind the existing service boundaries for history, credentials and account IO. Do not add parallel access paths or abstractions solely to satisfy a check.
- Before implementation, identify the observable behavior and how to verify it. Parser changes should replay representative synthetic inputs; persistence changes should read back results; UI changes should operate the affected controls in an isolated Debug window, including relevant empty/error, repeated and return flows.
- A same-build render consensus proves repeatability only, not correct layout, copy or interaction. Inspect changed renders against the intended design or baseline; use behavior assertions for values and state transitions. Do not replace failed UI interaction checks with model-only checks and call the UI verified.
- For a regression or new validation mechanism, demonstrate that the check detects the target fault before accepting the fix, where feasible. Keep temporary fault injection out of the final branch; if the environment cannot run a check, report it as unverified rather than passed.
- Review the final diff and validate the final commit. Seek independent review for behavioral changes and changes to tests, CI or safety boundaries. Never skip, soft-fail, relax assertions or widen allowlists merely to obtain green CI; legitimate gate changes need an explicit rationale and independent evidence.
- Before an authorized merge, confirm checks belong to the exact PR head and no unresolved blocker remains; verify the remote merge afterward. Keep merge and release authorization separate. Report what changed, what was actually verified, and remaining limits without treating test or PR counts as quality evidence.

## Comments and documentation

- Prefer clear names and simple code over narration. Add short comments only for non-obvious reasons, invariants, safety boundaries or compatibility traps; preserve necessary API documentation and attribution.
- Do not add teaching prose, implementation diaries or task-history markers to code or product UI. Preserve useful errors, operating guidance and accessibility labels.
- Update the relevant existing guide when behavior or an interface changes; do not create duplicate summaries, plans or reports unless requested. Before committing, remove unnecessary text introduced by this diff, not unrelated existing documentation.

## Data and compatibility

- Never commit credentials, certificate material, real session logs, personal screenshots or private diagnostics. Public UI examples use synthetic data.
- A read failure must not overwrite a previous successful snapshot with zero. Keep unavailable/loading/error states distinct from confirmed zero.
- Optional live quota queries must respect user opt-in and discard obsolete asynchronous results. Preserve validation-environment early returns.
- Maintain updater publisher identity, Bundle ID/version/architecture checks, safe staging and rollback. Do not bypass signing checks, remove quarantine or request elevation to make tests pass.
- API reference prices are estimates, not bills. Append dated price snapshots; do not rewrite historical prices or infer absent cache metrics.
- Update the relevant guide when behavior changes. Keep CHANGELOG history and original MIT attribution.

Local plans, review output, screenshots and build products remain ignored. Do not delete caches, history, branches or user data as part of routine cleanup.
