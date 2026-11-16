# Clipboard Compatibility Matrix

## Gate policy

`externalPayloadStorageEnabled`, `manifestReplayEnabled`, and verified inline cleanup remain off in source-code defaults until the manual rows below pass on an installed, signed build. The current installed validation copy has all three switches persisted on in its active host preference domain. Automated results prove storage and byte preservation, but they do not prove how every receiving application interprets the restored pasteboard.

## Automated evidence

| Scenario | Evidence | Status |
| --- | --- | --- |
| Item boundaries | Two pasteboard items are captured and replayed separately | Passed |
| Representation order | Original advertised types retain their relative order | Passed |
| Exact bytes | UTF-16, HTML, RTF, PNG, JPEG, and a private binary type compare byte-for-byte | Passed |
| External lazy read | Replay succeeds when inline `Data` is absent and only the payload reference exists | Passed |
| Legacy fallback | Legacy flattened replay remains available behind the manifest version gate | Passed |
| Multiple files | Existing specialized file-URL replay test remains passing | Passed |
| Paste without formatting | Plain text and file URLs remain; RTF is removed | Passed |
| Storage interruption | Bounded migration resumes after interruption without rewriting completed rows | Passed |
| Downgrade preparation | External payloads can be restored into inline BLOBs in bounded batches | Passed |
| Production-copy downgrade | All 536 referenced representations in an external-only copy were restored into 345.6 MiB of inline BLOBs; integrity and hash samples passed | Passed |
| Real 2.8.0 database | Earlier pre-restore snapshot had 200 history / 570 content rows, zero inline BLOBs, 520 verified external references, and passing SQLite integrity | Passed |
| Referenced payload integrity | The restored snapshot references 436 unique payload hashes; earlier full verification found zero missing, size-mismatched, or hash-mismatched files | Passed |
| Installed steady-state memory | Clean launch after inline cleanup measured 116–126 MiB RSS through 35 seconds and 138 MiB after about ten minutes | Passed |
| Installed scrolling and image preview | Five pages measured about 501 ms down / 116 ms up; a 36.9 MB image rendered sharply | Passed |
| Oversized long-image preview | A real 2468×77474 / 20.9 MB PNG would inflate about 770 MiB even through ImageIO thumbnailing, so the popup immediately reuses its derived disk thumbnail and does not re-decode the original; original dimensions remain metadata | Passed |
| Composite spreadsheet presentation | WPS/Excel/OpenXML bundles containing plain text plus PNG/private formats use searchable text for list/preview while retaining the complete manifest; generic text+image bundles remain image-primary | Passed |
| Test payload isolation | UI-test payloads use a per-process temporary root and cannot garbage-collect production payload files | Passed |
| Installed restored store | 200 history / 610 content rows, zero inline BLOBs, 553 verified external references, and passing SQLite integrity after restoring the pre-test snapshot and merging eight legitimate records | Passed |

The latest complete `MaccyTests` result contains 128 tests in 15 suites: 126 passed, 2 platform-dependent cases were skipped, and zero failed. The added regressions cover retained-inline fallback after an external payload disappears, payload-identity duplicate comparison without reading an external file, Universal Clipboard JPEG preview, and recovery of true source dimensions instead of reusing disk-thumbnail dimensions. Durable pre-cleanup and pre-install rollback backups were retained. Clipboard tests must run with the installed Maccy process stopped because an in-memory test database does not isolate the system pasteboard.

macOS may advertise additional synonymous text/RTF pasteboard types. The test therefore checks that every original type keeps its relative order and exact bytes rather than requiring the system-generated aliases to disappear.

## Manual source/target application gate

For each row: copy in the source, capture with Maccy, clear the system pasteboard, restore from Maccy, compare the manifest and hashes, then paste into the target.

| Source / target | Required content | Status |
| --- | --- | --- |
| Safari | text, HTML, image, link | Pending |
| Chrome | text, HTML, PNG/JPEG, private Chromium types | Pending |
| Edge | text, HTML, multi-item behavior | Pending |
| Firefox | text, HTML, image | Pending |
| Preview | PNG, TIFF, JPEG, HEIC, transparency, color profile, multi-page TIFF | Pending |
| Photos | image import/paste | Pending |
| Word | formatted text, attachments, private Office types | Pending |
| Excel | cells, formatted ranges, image | Pending |
| PowerPoint | text, shape/image, private Office types | Pending |
| Finder | single file and multiple files | Pending |
| VS Code | plain text and editor-specific types | Pending |
| Qt application | text and image | Pending |
| WeChat | text and image | Pending |
| DingTalk | text and image | Pending |
| Universal Clipboard | text, image, file marker behavior | Pending |

## Maccy behavior gate

| Behavior | Status |
| --- | --- |
| Copy and paste | Automated byte-level replay passed; installed target-application checks pending |
| Paste without formatting | Automated passed; installed-app pending |
| Duplicate detection | Existing tests passed; installed-app pending |
| Pin, delete, clear, clear all | Bounded 200-item disposable-store timing and pin/cutoff behavior pass; destructive production clearing is intentionally not used | Passed |
| Missing/corrupt payload keeps unaffected representations available | Storage fallback passed; installed-app diagnostic presentation pending |

## Optional format synthesis decision

No format synthesis is enabled. Until the application matrix proves equivalence, Maccy stores and replays every verified standard or private representation verbatim. Consequently there is no safe allowlist yet; adding one before evidence would violate the compatibility contract.
