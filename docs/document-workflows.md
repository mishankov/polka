# Documents and local editing

The text and raster screens open multiple files or a folder and accept native file/folder drops. Folder traversal skips hidden entries and symbolic links, limits traversal to 2,048 entries and 16 directory levels, and opens at most 256 files / 64 MiB per selection (32 MiB per file). A file already open in the same app activates its existing draft instead of replacing it from disk. All document kinds share the tab list; initial activation prefers the screen’s document kind, and opening a tab chooses its text, binary, or raster editor automatically.

Text documents expose encoding and line-ending controls, close, save/save-as, persistent draft undo/redo, and the existing CodeMirror editing history. Draft edits check document revisions and do not write over external files. Saving retains external-change detection and atomic replacement.

The raster editor supports brush, eraser, resize, rectangular crop by coordinates, clockwise/counterclockwise rotation, horizontal/vertical reflection, and undo/redo of both drawing and geometry changes. Operations modify canvas pixels and export PNG; dimensions are limited to 8,192 pixels per side and 16 megapixels. The document's draft/history records committed edits for recovery.

Validation:

- `npx tsx --test tests/document-workflows.test.ts`: native path scanning, revision-checked drafts, formatting undo/redo, preservation of unsaved content when reopening, and raster bounds.
- `npx tsx scripts/document-workflows-smoke.ts` after a build: native folder chooser fixture, multiple tabs, native dropped File handling, pixel-preserving raster crop/rotation/undo, and opening edited images from shared document tabs.

JPEG/GIF/WebP editing in the raster editor emits PNG, and saving a changed codec opens Save As with the correct extension. Crop uses numeric coordinates rather than a draggable marquee. Native directory grants belong only to the user-selected import; they do not grant extensions arbitrary filesystem access.

The `converter` screen provides JSON, XML, YAML, Base64 and hex operations with CodeMirror input and a read-only result. Choose an operation, enter text, run it, then optionally save the result as a new text document. Editing the input or operation clears stale results; parser errors preserve the input. JSON/XML/YAML inputs are syntax highlighted, including `.json`, `.xml`, `.yaml` and `.yml` documents. Base64/hex are plain encoded text, with separate operations for UTF-8 text and byte arrays.

`transforms.list` describes input/output types and warnings; `transforms.run` performs one operation. A declared `transform` action uses the same service. Processing runs in a separate worker: two concurrent operations, 5 seconds, 64 MiB heap, 1 MiB serialized input, 2 MiB serialized output, at most 100,000 visited data nodes and depth 100. YAML accepts a single document, rejects duplicate keys, unsupported tags, cyclic/non-JSON values and excessive alias expansion. Formatting YAML retains comments; JSON conversion does not. XML rejects DTD/entities; its mapping uses `@_` attributes and `#text`, with explicit loss warnings. These APIs do not write documents. Pipelines, image transformations, batch-apply and dedicated document-clipboard endpoints remain removed.

`npm run test:formats` checks the converter, parser errors, saving, syntax highlighting, and a custom React screen using the shared `CodeEditor` and scoped format API.
