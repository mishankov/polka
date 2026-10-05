# Polka portable package, version 1

Extension: **`.everyapp`**, media type `application/vnd.everything-app`. The desktop package associates this extension with Polka. The format identifier and media type retain their original names for compatibility with existing packages. A package is a ZIP archive, never an executable or standalone macOS app. Opening a package stages a preview; it does not execute its source code.

## Contents

| Entry | Purpose |
|---|---|
| `manifest.json` | `format: "everything-app"`, format/API version 1, template UUID, definition version, human metadata, export mode, dependencies, licensing notices, external connection descriptions and SHA-256 hashes |
| `definition.json` | Validated `AppDefinition`: entities, fields, relations, screens, actions, automations, extension source, permission requests and theme tokens |
| `demo-data.json` | Explicit synthetic examples from separate demo storage; optional in earlier v1 archives |
| `data.json` | Selected records: record ID, entity ID, values, creation/update timestamps; no installation IDs |
| `attachments.json` | Selected attachment metadata: ID, name, byte size, SHA-256, creation time; no absolute paths |
| `documents.json` | Explicitly selected documents: ID, name, kind, content, encoding and line endings; omitted in early v1 archives is equivalent to `[]` |
| `attachments/<id>` | Raw managed attachment bytes |

All files other than the manifest must have a SHA-256 entry in `manifest.hashes`. Extra undeclared files, missing entries, duplicate paths, traversal, native binaries, ZIP links, unsupported compression and invalid definitions are rejected. Integrity hashes are not signatures and do not establish author trust.

The dependency contract identifies the built-in platform ABI (`platform: "1.0.0"`). Extension dependency declarations accept only exact versions of bundled React/React DOM; the extension compiler checks those versions against the installed runtime. No npm installation or CDN execution is needed on the receiver. The manifest records author-defined application licensing; the sender must provide permission to redistribute their own content. Platform dependency licenses ship with the platform, independently of each application package.

## Export selection and consistency

`template` contains definitions and no personal records, attachments or documents. The unchecked-by-default `includeDemo` option includes separately authored examples in `demo-data.json`; it never copies personal rows. Examples are edited as `{id, entityId, values}` objects and saved independently using `packages.demoSave`. Maximum 1,000 example rows / 1 MiB; examples cannot reference personal attachments or records. Template import initializes the new instance with remapped copies of these examples. Data-copy import installs only `data.json` as working records; demo fixtures remain separate for future template exports. `data` includes the selected entities/record IDs and attachment IDs; attachments referenced by included records are automatically included. Records pointing to excluded related records cause a clear error rather than silently broken links. Document contents are included only through `documentIds`; external paths, disk hashes and edit history are stripped.

Definition and structured-data selection occur in one SQLite transaction. Agent conversations, logs, jobs, provider settings, accounts, secrets, grants, window state and clipboard history are never collected implicitly. Clipboard content stored as an ordinary record is included only by a data export containing that record. Explicit file-path configuration and secret keys in definitions prevent export; the author must model them as reconnectable connections. Arbitrary user-authored strings cannot be semantically classified as secrets, so application authors must not embed credentials in code or prose.

External application links are described by entity and human name, with no recipient-side binding. External connections require setup on the recipient. Imported instances start stopped, have no permission grants, and every automation is disabled.

## Import and resource limits

Limits: 64 MiB compressed, 128 MiB actual expanded bytes, 1,000 archive entries, 100,000 records, 100 entities, 100 fields/entity, 100 screens and 30 extensions. A locally attached file is limited to 32 MiB. The schema limits each record to 1 MiB.

The importer checks archive completion, safe filenames, duplicates, compatibility, content hashes, typed data, unique constraints, relations and attachment integrity. Streaming inflation consumes compressed input in 1 KiB increments and counts actual output; forged ZIP uncompressed sizes cannot bypass the expanded-byte limit. Headers are checked against actual output. All extraction stays in memory; filenames from the archive are never passed to filesystem writes.

Desktop preview runs decompression and validation in a dedicated archive worker and produces a process-local token for an immutable validated bundle. Commit installs exactly the staged content even if the original path changes afterward. The compatibility direct-core preview API retains hash revalidation; desktop routes use immutable staging. Repeated imports allocate independent instance, record, attachment and document UUIDs. Relation and attachment fields are remapped to the new IDs. Cross-instance data access grants are not transferred. SQLite mutation is one transaction; files written before an unsuccessful commit are removed. Startup removes attachment bodies with no metadata, including possible leftovers from a process crash.

The file save uses a temporary file and rename. This prevents readers from seeing a partial replacement; it is not a guarantee against storage hardware failure. SQLite uses WAL transactions and its configured durability policy.

## Updating an existing instance

Updating is a separate preview/commit API. The template ID must match and the source definition version must increase. The service stores the original imported definition separately from personal versions. A recursive three-way merge compares original, local and new definitions; ID-bearing arrays merge by item identity. Divergent edits to the same value are reported as conflicts and activation is refused. This release reports conflict paths for manual resolution; it does not provide an interactive conflict editor.

Before applying, all current records must validate under the merged schema. Both application version and data revision must still match the preview. A snapshot is created, defaults applied, definition history advanced and source baseline updated in one transaction. Existing personal records/documents are preserved; incoming package example/data records do not replace them. Updated apps stop and automations are disabled pending review.

## Explicit limitations

Packages contain application source and managed resources, not arbitrary native adapters. Cross-app dependencies are reconnectable descriptions, not recursively bundled applications. Archive preview and export compression run in dedicated workers. Progress reports actual compressed input consumed (import) or uncompressed input written to the compressor (export), not a prediction of time remaining. Cancellation terminates that worker and removes scratch files and incomplete output; no instance exists before explicit activation and an existing destination is preserved until the final atomic rename. Cancellation stops being available during the short final commit. Snapshot selection and attachment reads still run synchronously in the trusted core utility worker before export starts; they are not interruptible. Full worst-case memory/UI-latency measurements remain outstanding. Extension compilation/execution is a separate host responsibility and must be completed by the trusted worker before activation.

## Import result and reconnection

The import dialog remains open with a result report. It lists transferred counts, separate demo counts, requested permissions and external connection instructions. “Настроить доступ и связи” opens the imported instance’s access panel directly so the user can grant capabilities or reconnect a data source; opening the app is a separate action. Automations remain off. File/account reconnection depends on the application’s declared connection UI; the platform does not silently bind sender resources.
