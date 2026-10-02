# Local data, isolation and recovery

The trusted utility process owns one `workspace.sqlite` database per profile. `DatabaseSync` uses SQLite WAL, foreign keys and explicit `BEGIN IMMEDIATE` transactions. Tables use installation UUIDs; records have the composite key `(appId,id)`. This allows coherent snapshots, schema changes and multi-record updates while keeping a portable logical package representation independent of database layout. SQLite and ZIP work run outside the renderer and Electron main process.

Definitions are versioned separately from row revision numbers. Rows use a validated JSON field map, indexed by instance/entity, allowing live schemas without application-authored SQL. Types include text, numeric, boolean, date, select, relationship, managed attachment and structured JSON. Required/unique constraints, defaults, referential integrity, delete restrictions and runtime validation apply to every write. `records.batch` validates the complete proposed state and commits up to 1,000 operations atomically. Forward references inside a batch are supported.

The public query API provides search, equality/contains/numeric filters, sorting, offset/limit pagination and totals. The current implementation loads entity rows before filtering/sorting; large full-text indexes and SQL query planning are not yet implemented. The shell's global search covers installed accessible instances; extensions cannot call global search.

## Caller identity

The shell IPC bridge is privileged and routes only registered operations. Extension calls use `CoreService.callScoped` with an instance ID supplied by the trusted extension host, never one chosen by extension code. Its allowlist includes own-app metadata, CRUD/batch, attachment reads and explicit connected-data reads. Mismatched IDs and administrative methods are rejected. Settings/state, grant management, import paths and raw filesystem APIs are not extension capabilities.

Inter-app links are explicit rows identifying a source instance, target instance and entity. A query is checked against the source identity on every call. Revoking the link immediately stops subsequent reads. A stopped target is unavailable. Deletion previews report all links; deleting removes the corresponding links through foreign-key cascades. Links currently publish read-only entities; generalized action/event publication is handled separately by the runtime and is not provided by this data service.

## Definition changes

Prepare validates schema/dependencies and tests every existing row against the candidate. Removing populated fields/entities and incompatible type changes fail instead of deleting data. Added defaults are validated across the complete candidate dataset, including unique constraints. A draft captures definition version and data revision. Activate rejects either mismatch, revalidates, creates a snapshot, applies defaults and switches the active definition inside one transaction. A failed migration leaves the old definition and rows intact.

Themes use centrally declared palette tokens (`dark`, `gray`, `red`, `pink`, `grape`, `violet`, `indigo`, `blue`, `cyan`, `teal`, `green`, `lime`, `yellow`, `orange`) and radius tokens (`xs`, `sm`, `md`, `lg`, `xl`). Unknown tokens and raw hex colors are rejected before activation because the current renderer expects named Mantine palettes.

Three separate histories exist: document edit history in the document service, definition versions in `definitions`, and full definition/data snapshots in `snapshots`. Snapshot restore requires `confirm:true`, creates a new safety snapshot, preserves version monotonicity and stops the app. It intentionally discards later record changes. Referenced attachment bodies are retained while snapshots need them. Restoring only an old definition must still pass current-data validation.

## Files and cleanup

Managed attachment bytes live under `<profile>/attachments/<uuid>`; metadata holds instance, filename, size and SHA-256. Access checks scope before opening a managed path. Referenced files cannot be deleted. Import copies selected bodies to newly generated names and remaps fields. Rolled-back imports clean files; startup garbage collection removes UUID-named bodies not referenced by metadata. Deleting an instance deletes its metadata/records/snapshots/documents and collects attachment bodies.

Split and merge create independent copies and preserve sources. Preview is required; commit checks source revisions. Split includes selected entity definitions and data and rejects missing relationships. Merge prefixes declarative identities and remaps standard `entityId`, `actionId`, `screenId`, `extensionId`, `automationId` and `targetEntity` configuration references. Split/merge of programmable extensions is explicitly rejected because arbitrary source references cannot be rewritten safely. Advanced conflict resolution and moving data with source deletion are not yet implemented.

## Measured fixture, 2026-10-02

Command: `npx tsx --test tests/core-performance.test.ts`. Actual host: Apple M4, arm64, 32 GiB RAM, macOS 27.0 (26A428), Node v24.18.0. Dependencies are locked by `package-lock.json` (fflate 0.8.3, Zod 4.6.5). A fresh temporary profile contains 10,000 rows with sequential Russian titles and deterministic SHA-512 text. It writes ten atomic batches, searches/sorts a page, exports a data package and imports an independent instance.

| Measurement | Observed single run |
|---|---:|
| Write 10,000 records | 999.9 ms |
| Search, sort and return first 50 / 111 matches | 35.3 ms |
| Export | 97.3 ms |
| Import preview and verification | 71.1 ms |
| Import verification + commit | 238.1 ms |
| Package bytes | 1,112,546 |
| Process peak RSS | 354.7 MiB |

These are local Node test measurements, including the test runner's memory, not Electron UI latency or guarantees. No real UI responsiveness, battery, long-running watcher load or maximum-size package measurements are inferred from them. Repeat the fixture on release hardware; practical provisional targets are query under 200 ms and 10k import under 2 s for this exact dataset, while keeping work off the main process. The test checks data integrity, not machine-dependent timing thresholds.

`tests/core.test.ts` verifies instance boundaries, constraints, concurrent migration refusal, rollback, explicit snapshot recovery, repeated imports with relation/attachment remapping, template privacy, archive tampering, path traversal, bounded inflation with forged ZIP sizes, selected document transfer, three-way package updates/conflicts, links/revocation, split/merge, restart persistence and batch atomicity.
