# Private document storage — FormScan 2.4

## Owner setup

Run the complete, repeatable migration [001_document_cloud.sql](../Backend/001_document_cloud.sql)
in the SQL Editor of the FormScan project `zqptfsammjpdqqoonevu`. A successful
execution can say **Success. No rows returned**. This is normal for schema setup.
No second project, administrative key in the app or public storage bucket is needed.
The owner ran this migration and its read-only health check returned schema 1 with
a private bucket on 21 October 2026. Anonymous catalogue access was denied.

## Account and file ownership

The official Auth SDK refreshes the session before storage requests. The verified
user UUID, rather than an email typed by a client, determines access. Requests use
the public publishable key and that user's bearer token over HTTPS.
`formscan-documents` is a private, PDF-only bucket with a 50 MiB per-file limit.
Object names are canonical `userUUID/documentUUID/revisionUUID.pdf` paths.
Policies restrict file operations and catalogue reads to the current UUID. Direct
catalogue mutations are denied: the revision-checked RPC performs commits.

The service stores the PDF and field metadata, including entered text, checkbox
values and labels. The PDF is uploaded before its catalogue revision is committed.
Local field analysis does not send images to a model service. Document storage is
private account storage; it is not a claim of end-to-end encryption.

## Saving and restoring

Changes save locally first and schedule a server pass after approximately 800 ms.
The foreground app also checks about once a minute and when becoming active or
closing an editor. This does not promise background uploads while iOS suspends the
app. No permanent synchronization panel is shown. Connection, storage and session
errors remain visible with a retry action; sign-out warns about pending changes.

Every pass reads the remote catalogue successfully before uploading local content.
A network failure never means an empty remote account. A fresh installation
downloads the catalogue and PDFs. Metadata is validated, and restored text and
checkbox values are synchronized into the document before it opens.

A per-account atomic local journal records acknowledged revisions and pending
requests. Lost responses can be retried without creating another document or
acknowledging edits that have not been saved. Immutable upload retries compare
stored bytes. Corrupt or foreign journals stop writes without removing documents.
Confirmed obsolete PDF revisions are queued for deletion; cleanup failures retain
that queue. Unknown commit results never authorize deletion of an uploaded PDF.

## Concurrent editing and removal

The RPC compares the expected revision under a per-user/document transaction lock.
Only one simultaneous writer succeeds. A stale writer cannot overwrite new data.
Incoming changes wait while an editor is open. If both copies changed, the local
version becomes a separate document labelled “copia conservada” and both are kept.
Removing a document first records durable local intent, then commits a remote
tombstone. A stale copy cannot silently resurrect it. A newer remote edit found
while processing a removal is retained and explained to the user.

## Verification and limits

- Ten tests execute the exact migration twice in disposable PostgreSQL 17, including
  actual role permissions, cross-account isolation, CAS races and tombstones.
- Swift tests use an isolated service and an injected HTTP transport for offline
  changes, fresh-install restoration, filled PDF export, conflicts, lost responses,
  deletion races, wrong owners, expired sessions and quota errors.
- Native simulator UI tests restore a filled checkbox, edit text, remove the local
  library, recover from a failed request and verify both values after restoration.
  The fixture and its test state view compile only in Debug and use no real account.
- Publication checks the live public Auth configuration and cloud health, then
  validates the actual IPA and the matching SideStore versions and download.

These checks do not claim a real Google login or a real-account PDF upload. Final
physical-device acceptance is: sign in, import and edit a disposable PDF, leave the
app online until saving completes without an error, then sign in on a second test
installation and verify the text, checkbox and exported PDF. Preserve/export the
only copy of important files before testing reinstalls. SMTP delivery is a separate
owner configuration check. Supabase free-plan quotas and availability apply; the
app does not promise unlimited space or permanent free-plan uptime.

## Typing and stored PDFs (2.4.1)

The document consists of its PDF plus authoritative editable field metadata.
Ordinary text/checkbox edits atomically save the small metadata file without
rewriting the scanned PDF. New/replaced PDFs and removed embedded widgets still
persist the required PDF content. A fresh session, thumbnail, cloud installation
and exported PDF apply the metadata, including older source PDF appearances.
Cloud revisions always include both parts; downloading the PDF alone is not a
substitute for restoring its field metadata.

Keystrokes update only affected annotations. Unrelated pages and text annotation
instances remain intact. PDFKit stays alive when switching modes but does not
redraw while hidden; visible changed pages are refreshed on returning to Document.
The hidden library retains its thumbnail during edits and refreshes it on closing
the full-screen editor, rather than rasterizing a scanned page on every save.
Regression tests check unchanged PDF bytes across repeated saves, removal of an
embedded widget, restored values and flattened export. Simulator tests type in
both pages of a rasterized scan, change modes and reopen the saved document.
