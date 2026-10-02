# Core RPC contract

All methods return JSON serializable values and throw errors with human-readable Russian messages. The trusted shell may call all methods; extension callers must use `core.callScoped(appId,method,params)` where appId comes from the trusted host. Renderer uses `window.platform.call(method,params)` and `onEvent(callback)`.

- `apps.list {}` → AppInstance[] (includes definition)
- `apps.create {name, description?, icon?, definition?}` → AppInstance (empty definition if absent)
- `apps.get {appId}` → AppInstance
- `apps.updateMeta {appId,name?,icon?,favorite?,status?}` → AppInstance
- `apps.duplicate {appId,withData?:boolean}` → AppInstance
- `apps.delete {appId,confirm?:boolean}` → dependency report if !confirm, otherwise `{deleted:true}`
- `definitions.prepare {appId,definition}` → `{draftId,baseVersion,baseRevision,changes,warnings}`; validates existing data against candidate schema; no data erased
- `definitions.activate {draftId}` → AppInstance; refuses stale version/revision
- `definitions.history {appId}` → `{version,definition,createdAt}[]`
- `records.list {appId,entityId,search?,filters?:{field,op:'eq'|'contains'|'gt'|'lt',value}[],sort?:{field,direction:'asc'|'desc'},offset?,limit?}` → `{records:DataRecord[],total}`
- `records.upsert {appId,entityId,id?,values}` → DataRecord
- `records.delete {appId,entityId,id}` → `{deleted:true}`; rejects referenced rows
- `records.batch {appId,operations:{type:'upsert'|'delete',entityId,id?,values?}[]}` → `{results,revision}`; 1–1,000 operations validate the complete final state, so forward references within a batch work, and commit atomically
- `search {query,appId?}` → `{appId,entityId,id,title,excerpt}[]`
- `settings.get {key?}` → value or key/value object; `settings.set {key,value}` → value
- `state.get/set` same as settings, reserved for trusted main process (not renderer/agent/extension)
- `permissions.list {appId}` → `{permission,scope,grantedAt}[]`; `.grant {appId,permission,scope?:string}`; `.revoke {appId,permission}`
- `links.list {appId}` → links; `.grant {sourceAppId,targetAppId,entityId}` → link; `.revoke {id}`; `.query {appId,linkId,limit?}` → records, requires source app bound by trusted host
- `snapshots.create {appId,label?}` → snapshot metadata; `.list {appId}`; `.restore {appId,snapshotId,confirm:true}` → AppInstance. Restores definition + data, discards later data; creates safety snapshot first.
- `packages.preview {appId,mode:'template'|'data',entityIds?,recordIds?,attachmentIds?,documentIds?}` → composition report; documents are included only when explicitly selected
- `packages.export` same plus `{path}` → `{path,bytes,manifest}` (main process selects path)
- `packages.importPreview {path}` → `{previewId,manifest,definition,recordCount,attachments,requiredPermissions,warnings}`; no execution
- `packages.importCommit {previewId}` → `{app,report}`; fresh IDs, no permissions carried
- `packages.updatePreview {appId,path}` → `{previewId,definition,manifest,requiredPermissions,recordCount,warnings}`; three-way merge against stored original, rejects conflicts. Definition migration is checked against current records; incoming package data does not overwrite personal data.
- `packages.updateCommit {previewId}` → `{app,report}`; checks the file hash and data revision again, snapshots and activates atomically; source version advances, automations turn off
- `attachments.add {appId,path,name?}` → metadata (trusted dialog-selected path), `.list {appId}`, `.read {appId,id}` → metadata and base64, `.delete {appId,id}`
- `apps.splitPreview {appId,entityIds,name}` → `{previewId,definition,recordCount,warnings}`; `.splitCommit {previewId}` creates independent selected copy (source preserved)
- `apps.mergePreview {appIds,name}` → `{previewId,definition,recordCount,warnings}`; `.mergeCommit {previewId}` creates independent combined copy (sources preserved)

See `src/shared/types.ts` for stable definition/record shapes. Methods implementation: `src/core/service.ts` (`CoreService(root)`, `handle`, `callScoped`, `close`).
