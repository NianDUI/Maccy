# Clipboard Storage and Memory Architecture

## Status

Accepted; implementation and installed-store rollout validation are in progress. This document defines a compatibility-first redesign of Maccy's clipboard persistence and image memory management. The target architecture is implemented incrementally so every phase can be measured, tested, and rolled back independently.

## Implementation Strategy

The target architecture is not reduced to a short-term patch, but it is also not delivered as a single storage rewrite. Work proceeds through compatibility-preserving checkpoints:

1. isolate type metadata from image decoding and bound decoded-image memory without changing the database;
2. add the external payload store behind dual-read interfaces;
3. migrate legacy BLOBs incrementally while retaining a verified fallback;
4. enable manifest-preserving lazy replay for new entries;
5. consider format synthesis only after application-level compatibility evidence exists.

Each phase must leave the application releasable. Phase 2 cannot start until Phase 1 memory tests pass, and the legacy inline-BLOB read path cannot be removed until migration verification and rollback tests pass.

### Delivery Checklist

#### Phase 1: Metadata and cache isolation

- [x] Record the compatibility contract and target architecture.
- [x] Determine image/text/file presence from pasteboard type metadata, never by decoding payloads.
- [x] Stop retaining decoded original images on `HistoryItem`.
- [x] Introduce shared thumbnail and preview caches with pixel-cost and count limits.
- [x] Clear preview and thumbnail caches in priority order under memory pressure.
- [x] Avoid computing image-only preview text during decorator initialization.
- [x] Cancel off-screen thumbnail work and release active preview references.
- [x] Add unit tests for type-only detection, cache invalidation, and decorator deallocation.
- [x] Run the automated 200-image scroll/preview/release memory regression.
- [x] Run the 1,000+ image replacement/eviction plateau regression required by the original acceptance criteria.
- [x] Measure installed-app launch and steady-state memory with the production store.
- [x] Measure installed-app scrolling and preview responsiveness with the production store.
- [x] Measure bounded 200-item clear responsiveness on a disposable store; keep destructive production clearing out of manual validation.
- [x] Present spreadsheet clipboard bundles as text when they also contain a rendered image, while retaining every image/rich-text/private representation for replay.

#### Phase 2: External payload store

- [x] Define versioned metadata and payload-reference schemas.
- [x] Implement atomic SHA-256-addressed payload writes and exact-byte deduplication.
- [x] Add dual-read access for inline BLOBs and external payloads.
- [x] Store new captures externally behind a feature flag.
- [x] Add bounded, resumable legacy migration with verification before BLOB removal.
- [x] Implement a separate verified inline-BLOB removal pass and bounded downgrade rehydration.
- [x] Validate inline-BLOB removal against the installed production store under an explicit rollout flag and retain pre-cleanup backups.
- [ ] Enable inline-BLOB removal by default only after the installed-app compatibility gate passes.
- [x] Add orphan/temp-file garbage collection with a grace period.
- [x] Prove interrupted migration, downgrade, and rollback behavior with automated storage tests.

#### Phase 3: Manifest-preserving replay

- [x] Persist pasteboard item boundaries and representation order for new captures.
- [x] Add lazy `NSPasteboardItemDataProvider` replay.
- [x] Retain the legacy flattened replay path for legacy entries.
- [x] Pass automated byte-level manifest, ordering, external lazy-read, and fallback compatibility tests.
- [ ] Pass the real-application compatibility matrix.
- [ ] Enable external storage and manifest replay by default only after the release gates pass.

#### Phase 4: Optional format synthesis

- [ ] Collect compatibility evidence per source/target application and image type.
- [ ] Define a narrow allowlist and feature flag for safe lazy synthesis.
- [x] Keep private, unknown, and unverified formats verbatim.

### Implementation Audit (2026-11-13)

The checklist above is verified against code and tests rather than intent:

- `MaccySchemaV2` and `MaccySchemaMigrationPlan` provide a formal SwiftData schema version; the installed 2.8.0 production store containing 200 history items and, at the final audit, 614 representation rows opened, backfilled, and passed SQLite `quick_check` without history-count changes.
- `PayloadStore` writes exact bytes to SHA-256 paths using temporary files and atomic rename, validates length/hash, deduplicates identical bytes, and performs grace-period garbage collection.
- `HistoryItemContent` carries versioned payload-reference metadata and dual-reads verified external bytes with an inline fallback.
- `Storage` migrates and rolls back in batches bounded by record count and byte count; completed records are the durable resume cursor.
- inline BLOB removal is a separate verified pass and is never part of the initial migration transaction.
- new captures record pasteboard item and representation indices; lazy replay is feature-gated and legacy records retain flattened replay.
- lightweight `HistoryItem` metadata is backfilled in bounded batches so list/search code can stop traversing payload relationships.
- derived PNG thumbnails are cached separately and are regenerated from the original only on a cache miss; a regression test proves a second load succeeds without original bytes.
- clear and clear-all update the UI immediately, delete SwiftData rows in bounded batches with scheduler yields, preserve pins for normal clear, and retain synchronous completion only for tests and app termination.
- privacy-safe diagnostics cover metadata/payload counts, payload inventory and deduplication, reads by operation, missing/corrupt references, GC reclamation, image-cache insertion/eviction cost, and OCR queue duration.
- the final 200-image automated run measured 376 MiB baseline, 430 MiB peak, and 258 MiB after release on the test machine (54 MiB peak growth).
- the 1,050-image replacement test, while retaining at most 200 history entries, measured 321 MiB at the midpoint and 324 MiB at the endpoint; the second half added 3 MiB rather than another history-sized tranche.
- the complete `MaccyTests` run contains 128 tests in 15 suites: 126 passed and 2 platform-dependent cases were skipped, with zero failures. This includes bounded image-memory stress, exact manifest replay, retained-inline fallback after an external payload disappears, migration/rollback, test payload isolation, metadata-only decorator creation, payload-identity duplicate comparison without external reads, Universal Clipboard JPEG preview, recovery of true source dimensions when a disk thumbnail is cached, oversized long-image routing to the derived-thumbnail path, and WPS/Excel/OpenXML composite spreadsheet presentation.
- bounded clear, pin preservation, and protection of copies created after clearing begins pass in the complete suite.
- the signed/ad-hoc installed 2.8.0 build migrated 536 external representation references, removed every verified inline BLOB under an explicit cleanup flag, and left 420 unique referenced payload files (214.8 MiB). Every referenced file passed existence, byte-count, and SHA-256 verification; SQLite `quick_check` remained `ok`.
- after cleanup, a clean installed-app launch stabilized at 116–126 MiB RSS during the first 35 seconds and 138 MiB after roughly ten minutes. `vmmap` reported a 42.3 MiB physical footprint at the sampled steady state. Before inline cleanup, the same production store stabilized near 368 MiB and external migration/GC launches could reach roughly 1.0 GiB because SwiftData materialized inline `Data` values.
- a disposable copy of the external-only production store restored all 536 referenced representations into 345.6 MiB of inline BLOBs in bounded batches; the restored copy passed `quick_check` and sampled values matched their recorded SHA-256 hashes.
- installed scrolling over five pages measured approximately 501 ms downward and 116 ms upward. A 36.9 MB image preview rendered sharply. A real 2468×77474 / 20.9 MB long screenshot exposed that ImageIO still inflated roughly 770 MiB even when asked for a 65×2048 result. Images whose decoded bitmap would exceed the 96 MiB preview budget therefore reuse the already-generated disk thumbnail immediately and never re-decode the original for the popup; original dimensions remain metadata.
- the same 20.9 MB WPS source also advertised UTF-8/UTF-16 text, HTML, RTF, PNG, and private spreadsheet formats. Metadata version 2 now recognizes WPS, Microsoft Excel, and OpenXML spreadsheet markers: these composite records use searchable text for the list and popup preview, but manifest replay still retains every original representation. Installed verification showed the full table text immediately and did not enter image decoding.
- an earlier installed 2.8.0 validation launch measured about 112 MiB RSS at five seconds with 200 history rows, 570 representation rows, zero inline BLOBs, 520 verified external references, and SQLite `quick_check` equal to `ok`. The payload directory contained 489 files / 236.1 MiB, including 416 unique hashes referenced by that snapshot.
- an attempted UI-test run exposed that its in-memory database could still point at the production payload directory. The production store was restored from the verified dual-read backup, all references were regenerated and reverified, and `PayloadStore.shared` now uses a per-process temporary directory under UI testing. Full UI tests are not rerun against production data until database and payload-root isolation are both independently proven.
- a later unit-test run proved a separate isolation boundary: even with an in-memory test database, clipboard tests still exercise the system pasteboard, so a simultaneously running installed Maccy can capture test UUIDs. The verified 18:03 snapshot was restored, eight legitimate records created around the test window were merged back, and the polluted store was retained separately. Installed Maccy must be stopped before clipboard tests; database/payload isolation alone is insufficient.
- the final restored validation launch contains 200 history rows, 610 representation rows, zero inline BLOBs, and 553 verified external references; SQLite `quick_check` is `ok`, RSS was about 127 MiB after maintenance, and both long WPS records remain text-primary while retaining image metadata.
- the real-application compatibility matrix remains a release gate. The source-code defaults remain off for a general release, while this installed validation copy has external storage, manifest replay, and verified cleanup persisted on in its active host preference domain.
- detailed compatibility evidence is tracked in [clipboard-compatibility-matrix.md](clipboard-compatibility-matrix.md).

### Original-plan traceability and remaining work

This table is the authoritative audit against the original plan. "Implemented" means the code path and focused automated evidence exist. It does not mean that a feature is enabled in the installed application.

| Original requirement | Current evidence | State |
| --- | --- | --- |
| List/search use metadata and do not decode images to determine type | Versioned fields on `HistoryItem`; decorator type checks use metadata; focused tests cover type-only detection | Implemented |
| Read payload bytes only for OCR, preview, comparison, export, or paste | Thumbnail and preview paths load on demand; manifest replay uses lazy providers; installed external-only launch returns to baseline memory | Implemented; interactive read diagnostics pending |
| Bound decoded-image memory independently of history size | Shared pixel-costed `NSCache`, serial off-main ImageIO schedulers, adaptive long-image preview downsampling, memory-pressure clearing, derived thumbnail cache, 1,050-entry replacement plateau regression; final installed launch was about 112 MiB RSS at five seconds | Implemented; installed scroll and normal/oversized preview checks passed |
| Release the active large preview when it closes | Preview view drops the active reference; preview cache has a one-entry/96 MiB bound | Implemented |
| Store exact payload bytes outside normal SwiftData `Data` fields | SHA-256 file store, atomic writes, exact-byte deduplication, dual read; 420 production references verified byte-for-byte | Implemented behind a default-off flag; installed validation enabled explicitly |
| Remove inline BLOBs only after verification and retain downgrade support | Production cleanup reached zero inline BLOBs; disposable external-only copy restored 536 representations / 345.6 MiB and passed integrity/hash checks | Implemented and validated; default activation awaits the compatibility gate |
| Preserve item boundaries, representation order, and exact bytes | Manifest indices, lazy providers, byte-level tests for text/rich text/images/private data | Implemented behind a default-off flag |
| Preserve legacy replay behavior | Manifest-version gate and flattened replay fallback | Implemented |
| Keep unknown/private formats verbatim | No normalization or synthesis; exact bytes and original type records are retained | Implemented |
| Make migration bounded, resumable, recoverable, and garbage-collectable | Record/byte budgets, per-record durable references, rollback, grace-period GC | Implemented |
| Keep clear-history responsive for a large store | Immediate UI removal plus bounded database batches; cutoff protects copies made during deletion; disposable 200-item timing is part of the complete suite | Implemented and tested without deleting production history |
| Record privacy-safe storage/cache/OCR/migration diagnostics | Storage, payload, image-cache, and OCR counters plus progress/failure maintenance logs exist | Implemented; interactive diagnostic inspection remains pending |
| Prove behavior with a real 2.8.0 store | Installed production migration/cleanup, exact verification of 420 unique referenced files, stable-memory restart, and full bounded downgrade rehydration on a disposable copy | Implemented |
| Pass the real-application compatibility matrix | Separate matrix exists | Pending |
| Make the new path the default | Requires installed-app performance, rollback, and compatibility evidence | Pending |

The remaining sequence is therefore fixed: execute the available rows of the real-application matrix, inspect installed-app diagnostics, and only then decide whether to enable external storage/manifest replay and verified inline-BLOB cleanup by default. The production database is currently external-only for verified payloads, but the installed validation process uses explicit command-line rollout flags and durable pre-cleanup backups remain available.

## Context

Maccy currently stores each pasteboard representation as a `Data` value in SwiftData and constructs decorators for the complete history at launch. Several code paths inspect `HistoryItem.contents`, create `NSImage` objects merely to determine whether an item is an image, and retain decoded originals, thumbnails, and previews on individual history objects.

This design has three separate costs:

- large binary values increase the SQLite store size and vacuum work;
- reading relationships can materialize binary values that the history list and search do not need;
- decoded images and per-item caches increase the process memory high-water mark.

Search does not need image bytes after OCR. It searches the stored title. Image bytes are still required for previewing and for restoring the original clipboard contents, so they must remain available without remaining resident in memory.

## Goals

- Keep clipboard replay compatibility at least equal to the current implementation.
- Load only lightweight metadata when displaying or searching history.
- Read binary payloads only for OCR, preview, comparison, export, or paste.
- Bound decoded-image memory independently of the history size.
- Preserve every original pasteboard representation unless a transformation has been proven compatible.
- Reduce duplicate disk storage without changing advertised pasteboard types or bytes.
- Support interrupted migration, rollback, and cleanup without losing clipboard history.
- Make memory and storage behavior measurable with automated regression tests.

## Non Goals

- Do not force every image into PNG or another single format.
- Do not remove private pasteboard types merely because they are not understood by Maccy.
- Do not make binary image contents searchable directly. OCR text remains the search input.
- Do not require all existing data to migrate in one blocking launch operation.

## Compatibility Contract

For every newly captured clipboard entry, replay must preserve:

- the number and order of `NSPasteboardItem` values;
- the ordered set of pasteboard types belonging to each item;
- the original bytes for representations that are stored verbatim;
- file URL and multi-file behavior;
- plain text, RTF, HTML, and application-private representations;
- image alpha, color profile, dimensions, and format-specific metadata where supplied;
- Universal Clipboard markers and current ignore rules;
- current copy, paste, paste-without-formatting, duplicate detection, pinning, and clear behavior.

Existing entries do not contain complete item-boundary information because Maccy currently merges some pasteboard items. Migration must preserve their current replay behavior rather than invent boundaries that cannot be recovered.

## Proposed Architecture

### Metadata Store

SwiftData remains the source of truth for lightweight, searchable, and sortable metadata.

`HistoryEntry` contains:

- stable UUID;
- title and OCR search text;
- source application;
- first and last copy timestamps;
- copy count and pin information;
- primary content kind;
- set of pasteboard type identifiers;
- `hasImage`, `hasText`, `hasRichText`, and `hasFileURLs` flags;
- image pixel width and height when known;
- aggregate payload byte count;
- OCR state and OCR implementation version;
- relationships to pasteboard item and representation metadata.

The history list, menu bar title, sorting, filtering, and search must use only these fields. They must not traverse payload relationships or access `Data`.

`PasteboardItemRecord` contains:

- stable UUID;
- owning history entry;
- original item index;
- ordered representation records.

`PasteboardRepresentation` contains:

- pasteboard type identifier;
- original order within the pasteboard item;
- payload hash;
- original byte count;
- storage mode and optional conversion metadata;
- whether the bytes are stored verbatim or generated lazily.

### Payload Store

Large payloads are stored as content-addressed files under Application Support:

```text
Maccy/
├── Storage.sqlite
└── Payloads/
    ├── 0a/
    │   └── 0a9f...c2.blob
    └── f4/
        └── f47b...91.blob
```

The filename is the SHA-256 digest of the exact stored bytes. Pasteboard types remain separate metadata records, so two different types may reference the same payload without changing what Maccy advertises during replay.

Only byte-identical payloads are deduplicated initially. PNG, TIFF, JPEG, HEIC, and private image formats are not considered equivalent merely because they render similarly.

Files have no semantic extension. The pasteboard type and representation metadata determine how the bytes are interpreted.

### Lightweight Thumbnails

Image ingestion creates a bounded-size thumbnail after the original payload has been persisted. The thumbnail is a derived cache, not history data, and may be regenerated or deleted at any time.

The history list loads the thumbnail rather than the original image. Image dimensions, file size, and `hasImage` come from metadata and never require decoding the original during list rendering.

## Capture Flow

1. Read the pasteboard item list and preserve its item boundaries and type order.
2. Apply current security, ignore, disabled-type, and persistence filters.
3. Read each accepted representation once.
4. Compute SHA-256 while writing to a temporary payload file.
5. Atomically rename the temporary file into the content-addressed payload store if the digest is new.
6. Create representation metadata referencing the payload hash.
7. Save the metadata transaction.
8. Schedule thumbnail generation and OCR on dedicated background queues.
9. Store OCR output in the history entry's search text and discard OCR decoding buffers.

Payload files are written before the metadata transaction. If metadata saving fails, the file is harmlessly orphaned and is removed by later garbage collection. A database record must never reference a file that was not fully written and atomically renamed.

## List and Search Flow

1. Fetch only `HistoryEntry` metadata, sorted and limited by the configured history size.
2. Construct list view models from metadata without traversing representation relationships.
3. Search `title` and OCR search text only.
4. Load small derived thumbnails only for visible image rows.
5. Never access the original payload to answer `hasImage`, obtain byte size, or display dimensions.

This removes the current pattern where checking whether an item is an image can instantiate an `NSImage` and where decorator initialization can traverse all content values.

## Preview Flow

1. Use metadata to choose the preview kind.
2. For images, load only the preferred preview representation from the payload store.
3. Keep the active preview at source resolution so Retina displays never enlarge a downsampled intermediate; retain only the currently visible preview.
4. Keep the decoded preview in a bounded cache.
5. Release the active preview when the preview closes; retain only what remains within the cache budget.

Original-size decoded images must not be retained after producing a thumbnail or screen-sized preview.

## Paste Flow

Paste reconstructs the original item and type manifest.

For verbatim representations, an `NSPasteboardItemDataProvider` reads the referenced payload only when the receiving application requests that type. The provider must remain alive until pasteboard ownership changes.

For file URLs, Maccy continues to use the specialized item-writing behavior required for multi-file paste.

No format is removed during the initial redesign. Lazy format conversion may be added later only for a tested allowlist of standard image types. Private types, multi-page TIFF, Office data, file promises, rich-text attachments, and Universal Clipboard representations remain verbatim.

## Image Cache Policy

Replace per-model strong caches with shared `NSCache` instances keyed by stable history UUID and preview class.

Suggested initial budgets:

- decoded thumbnails: 32 MiB total, approximately 50 entries maximum;
- source-resolution preview: 96 MiB total, 1 entry maximum;
- original decoded images: no persistent cache.

Thumbnail decoding and ImageIO downsampling run off the main actor through a
serial scheduler. This deliberately limits in-flight decode memory to one image;
cancelled requests that have not started are skipped before decoding.

Cache cost is based on decoded pixels, not compressed payload size:

```text
cost = pixelWidth × pixelHeight × bytesPerPixel
```

The UI follows these rules:

- list row appearance may request a thumbnail;
- list row disappearance cancels unfinished work but does not force immediate thumbnail eviction;
- preview disappearance releases its active strong reference;
- deleting a history entry invalidates all related cache entries;
- changing thumbnail settings invalidates the thumbnail cache;
- memory pressure clears previews first and then thumbnails;
- hiding or backgrounding Maccy may reduce both cache limits temporarily.

Use `NSCache` automatic eviction and a macOS memory-pressure source. Avoid clearing every thumbnail on each row disappearance because doing so would cause repeated decoding during scrolling.

## OCR Policy

OCR runs once when a new image payload is captured, unless its OCR version changes or the user explicitly requests a rerun.

Persist:

- recognized text;
- OCR status;
- OCR implementation version;
- optional language metadata.

Do not persist or retain:

- Vision request handlers;
- decoded OCR images;
- intermediate pixel buffers;
- duplicate OCR input `Data` after the task completes.

The original image payload remains on disk for paste and preview, but search reads only the recognized text.

## Format Preservation and Deduplication

The first implementation preserves all accepted representations exactly.

Safe optimization:

- representations with identical SHA-256 hashes share one payload file;
- all original pasteboard type records remain present;
- replay still advertises each original type and returns the original bytes.

Deferred optimization:

- choose a preferred stored image representation;
- lazily synthesize other standard representations during paste;
- remove the synthesized representation from persistent storage.

Deferred conversion requires a compatibility allowlist and must not apply to unknown or private types. It is an optional later phase, not a prerequisite for fixing memory use.

## Existing Data Migration

Introduce a versioned SwiftData schema and explicit migration plan before changing persisted models.

Migration is dual-read and resumable:

1. New captures use the new payload store immediately.
2. Reads support both legacy inline BLOBs and payload references.
3. A background worker migrates legacy representations in small batches.
4. For each value, write the payload file and verify its length and SHA-256.
5. Save the new reference while retaining the legacy BLOB.
6. Mark the representation as verified.
7. Clear legacy BLOBs only in a later cleanup pass after all entries are verified.
8. Record progress so force quit, crash, or upgrade resumes safely.

Migration must not run as one large main-actor transaction. Batch size should be limited by both record count and total bytes.

Existing records that lack original pasteboard item boundaries retain the current flattened replay behavior. Only newly captured entries use the complete manifest.

## Garbage Collection and Recovery

Payload deletion happens after metadata deletion commits.

A garbage collector periodically:

- builds the set of referenced payload hashes;
- finds unreferenced files older than a grace period;
- removes only files not referenced by any current or legacy record;
- removes abandoned temporary files;
- reports counts and bytes reclaimed.

Startup must not synchronously scan or hash the entire payload store. Full reconciliation is a background maintenance task.

If a payload is missing or corrupt, Maccy keeps the history metadata, marks the affected representation unavailable, continues offering unaffected representations, and records a diagnostic message rather than crashing.

## Rollout Plan

### Phase 1 Metadata and Cache Isolation

- Add content-kind, type-set, dimensions, and byte-count metadata.
- Stop using `item.image` to determine whether a history entry is an image.
- Avoid generating preview text for image-only entries.
- Introduce bounded thumbnail and preview caches.
- Add memory-pressure handling and preview cleanup.

This phase keeps the existing BLOB store and should deliver the first measurable memory reduction with low compatibility risk.

### Phase 2 External Payload Store

- Add versioned schemas and dual-read payload references.
- Persist new binary content in content-addressed files.
- Add atomic writes, exact-byte deduplication, and garbage collection.
- Migrate legacy values in bounded background batches.

### Phase 3 Manifest-Preserving Replay

- Preserve item boundaries and type ordering for new captures.
- Reconstruct the manifest with lazy data providers.
- Validate application compatibility against the legacy replay path.

### Phase 4 Optional Format Synthesis

- Collect evidence for standard-format equivalence.
- Add an explicit allowlist for safe lazy conversions.
- Keep a feature flag and legacy fallback.
- Do not convert private or unverified formats.

## Compatibility Test Matrix

Every scenario follows this sequence:

```text
copy in source application
→ capture in Maccy
→ clear the system pasteboard
→ restore from Maccy
→ compare pasteboard manifest and payload hashes
→ paste into the target application
```

Required coverage:

- plain text, UTF-8 and UTF-16 text;
- HTML, RTF, formatted text, and rich-text attachments;
- PNG, TIFF, JPEG, HEIC, transparent images, color profiles, and multi-page TIFF;
- Safari, Chrome, Edge, and Firefox;
- Preview and Photos;
- Word, Excel, and PowerPoint;
- Finder single-file and multi-file copies;
- VS Code and Qt applications;
- WeChat and DingTalk;
- Universal Clipboard;
- copy, paste, paste without formatting, duplicate detection, pin, delete, clear, and clear all.

Tests compare both semantic behavior and, for verbatim representations, exact bytes. A type may be removed or synthesized only after the compatibility matrix proves the new behavior equivalent for that type.

## Performance Acceptance Criteria

- Launch and empty search do not read original image payload files.
- Showing a text-only history list does not allocate image-sized `Data` buffers.
- Scrolling image history keeps decoded thumbnail memory within the configured cache budget.
- Closing preview releases its active large decoded image.
- Replacing more than 1,000 image entries while history remains capped at 200 reaches a stable memory plateau rather than growing linearly.
- Clearing large history runs in bounded background batches and leaves the UI responsive.
- Payload garbage collection never removes a referenced file.
- Migration can be interrupted at every batch boundary and resumes without data loss.
- Clipboard replay passes the compatibility matrix before the new path becomes the default.

## Observability

Add privacy-safe diagnostics for:

- metadata record counts;
- payload file counts and total bytes;
- exact-byte deduplication savings;
- thumbnail and preview cache cost and eviction counts;
- payload read count and bytes read by operation type;
- OCR queue depth and duration;
- migration progress and failures;
- garbage-collection candidates and reclaimed bytes;
- missing or corrupt payload references.

Diagnostics must never log clipboard contents or recognized text.

## Decision Summary

The compatibility-first optimum is not to discard alternate pasteboard formats. It is to separate lightweight metadata from heavy payloads, preserve the complete original manifest, store exact payload bytes outside the main SwiftData row, deduplicate only byte-identical values, load payloads on demand, and bound every decoded-image cache. Format normalization remains a later, allowlisted optimization after application-level compatibility testing.
