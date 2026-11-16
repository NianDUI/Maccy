import AppKit
import Defaults
import Foundation
import SwiftData
import Testing
@testable import Maccy

@Suite(.serialized)
struct PayloadStoreTests {
  @Test("Atomic write, read, and exact-byte deduplication")
  func writeReadAndDeduplicate() throws {
    try withStore { store, root in
      let data = Data("same exact clipboard bytes".utf8)
      let first = try store.write(data)
      let second = try store.write(data)

      #expect(first == second)
      #expect(try store.read(first) == data)
      #expect(try store.payloadURL(for: first.hash).pathExtension == "blob")
      #expect(try store.payloadURL(for: first.hash).deletingLastPathComponent().lastPathComponent == String(first.hash.prefix(2)))

      let files = try regularFiles(under: root)
      #expect(files.filter { $0.pathExtension == "blob" }.count == 1)
      #expect(files.allSatisfy { !$0.lastPathComponent.hasSuffix(".tmp") })

      let diagnostics = store.diagnosticsSnapshot()
      #expect(diagnostics.writeCount == 2)
      #expect(diagnostics.newFileCount == 1)
      #expect(diagnostics.deduplicatedWriteCount == 1)
      #expect(diagnostics.deduplicatedByteCount == data.count)
      #expect(diagnostics.modelReadByteCount == data.count)
      #expect(try store.inventory() == PayloadStoreInventory(fileCount: 1, totalByteCount: Int64(data.count)))
    }
  }

  @Test("Corrupt payloads are rejected")
  func rejectsCorruptPayload() throws {
    try withStore { store, _ in
      let reference = try store.write(Data("original".utf8))
      let url = try store.payloadURL(for: reference.hash)
      try Data("changed!".utf8).write(to: url)

      #expect(throws: PayloadStoreError.self) {
        try store.read(reference)
      }
      #expect(!store.contains(reference))
    }
  }

  @Test("Invalid hashes cannot escape the payload directory")
  func rejectsInvalidHash() throws {
    try withStore { store, _ in
      #expect(throws: PayloadStoreError.self) {
        try store.payloadURL(for: "../../Library/Preferences")
      }
      #expect(throws: PayloadStoreError.self) {
        try store.payloadURL(for: String(repeating: "A", count: 64))
      }
    }
  }

  @Test("Garbage collection preserves references and honors grace period")
  func garbageCollection() throws {
    try withStore { store, root in
      let retained = try store.write(Data("retained".utf8))
      let orphan = try store.write(Data("orphan".utf8))
      let recent = try store.write(Data("recent".utf8))
      let oldDate = Date(timeIntervalSinceNow: -3_600)
      let cutoff = Date(timeIntervalSinceNow: -60)

      try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: try store.payloadURL(for: retained.hash).path
      )
      try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: try store.payloadURL(for: orphan.hash).path
      )

      let staleTemporary = root.appending(path: "aa/.stale.tmp")
      try FileManager.default.createDirectory(
        at: staleTemporary.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("temporary".utf8).write(to: staleTemporary)
      try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleTemporary.path)

      let result = try store.garbageCollect(
        referencedHashes: [retained.hash],
        olderThan: cutoff
      )

      #expect(result.removedFileCount == 2)
      #expect(store.contains(retained))
      #expect(!store.contains(orphan))
      #expect(store.contains(recent))
      #expect(!FileManager.default.fileExists(atPath: staleTemporary.path))
      #expect(store.diagnosticsSnapshot().garbageCollectedFileCount == 2)
    }
  }

  private func withStore(_ body: (PayloadStore, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "MaccyPayloadStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(PayloadStore(baseURL: root), root)
  }

  private func regularFiles(under root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
      return []
    }

    return try enumerator.compactMap { element in
      guard let url = element as? URL,
            try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        return nil
      }
      return url
    }
  }
}

@MainActor
@Suite(.serialized)
struct StoragePayloadMigrationTests {
  @Test("Background maintenance externalizes then removes only verified inline payloads")
  func maintenanceExternalizationAndCleanup() async throws {
    let savedExternal = Defaults[.externalPayloadStorageEnabled]
    let savedCleanup = Defaults[.verifiedInlinePayloadCleanupEnabled]
    defer {
      Defaults[.externalPayloadStorageEnabled] = savedExternal
      Defaults[.verifiedInlinePayloadCleanupEnabled] = savedCleanup
    }

    try await withStores { storage, payloadStore in
      let bytes = Data("maintenance payload".utf8)
      let item = HistoryItem(contents: [
        HistoryItemContent(type: "public.test", value: bytes)
      ])
      storage.context.insert(item)
      try storage.context.save()
      Defaults[.externalPayloadStorageEnabled] = true
      Defaults[.verifiedInlinePayloadCleanupEnabled] = true

      await storage.runBackgroundMaintenance(store: payloadStore)

      let content = try #require(storage.context.fetch(FetchDescriptor<HistoryItemContent>()).first)
      #expect(content.value == nil)
      #expect(content.isExternallyStored)
      #expect(content.resolvedValue(from: payloadStore) == bytes)
      #expect(try payloadStore.inventory().fileCount == 1)
    }
  }

  @Test("Migration is bounded, resumable, and retains rollback bytes")
  func boundedMigrationAndRollback() async throws {
    try await withStores { storage, payloadStore in
      let values = ["first", "second", "third"].map { Data($0.utf8) }
      for (index, value) in values.enumerated() {
        let item = HistoryItem(contents: [
          HistoryItemContent(type: "public.test.\(index)", value: value)
        ])
        storage.context.insert(item)
      }
      try storage.context.save()

      let first = try await storage.migrateLegacyPayloadBatch(
        store: payloadStore,
        maximumCount: 2,
        maximumBytes: 1_024
      )
      #expect(first.migratedCount == 2)
      #expect(first.hasMore)

      let second = try await storage.migrateLegacyPayloadBatch(
        store: payloadStore,
        maximumCount: 2,
        maximumBytes: 1_024
      )
      #expect(second.migratedCount == 1)
      #expect(!second.hasMore)

      let migrated = try storage.context.fetch(FetchDescriptor<HistoryItemContent>())
      #expect(migrated.count == 3)
      #expect(migrated.allSatisfy { $0.value != nil })
      #expect(migrated.allSatisfy { $0.isExternallyStored })
      let diagnostics = try storage.diagnosticsSnapshot()
      #expect(diagnostics.historyItemCount == 3)
      #expect(diagnostics.representationCount == 3)
      #expect(diagnostics.externalRepresentationCount == 3)
      #expect(diagnostics.pendingPayloadMigrationCount == 0)

      let removed = try await storage.removeVerifiedInlinePayloadBatch(
        store: payloadStore,
        maximumCount: 2
      )
      #expect(removed == 2)
      let afterRemoval = try storage.context.fetch(FetchDescriptor<HistoryItemContent>())
      #expect(afterRemoval.filter { $0.value == nil }.count == 2)

      let restored = try await storage.restoreInlinePayloadBatch(
        store: payloadStore,
        maximumCount: 1,
        maximumBytes: 1_024
      )
      #expect(restored.restoredCount == 1)
      #expect(restored.hasMore)
    }
  }

  @Test("Interrupted migration resumes without rewriting completed records")
  func interruptedMigrationResumes() async throws {
    try await withStores { storage, payloadStore in
      let item = HistoryItem(contents: [
        HistoryItemContent(type: "public.one", value: Data("one".utf8)),
        HistoryItemContent(type: "public.two", value: Data("two".utf8))
      ])
      storage.context.insert(item)
      try storage.context.save()

      let first = try await storage.migrateLegacyPayloadBatch(
        store: payloadStore,
        maximumCount: 1,
        maximumBytes: 1_024
      )
      #expect(first.migratedCount == 1)
      #expect(first.hasMore)

      let resumed = try await storage.migrateLegacyPayloadBatch(
        store: payloadStore,
        maximumCount: 10,
        maximumBytes: 1_024
      )
      #expect(resumed.migratedCount == 1)
      #expect(!resumed.hasMore)
    }
  }

  @Test("Legacy metadata backfill is bounded and resumable")
  func metadataBackfill() async throws {
    try await withStores { storage, _ in
      for value in ["one", "two", "three"] {
        let item = HistoryItem()
        item.contents = [
          HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(value.utf8))
        ]
        storage.context.insert(item)
      }
      try storage.context.save()

      let first = try storage.backfillHistoryMetadataBatch(maximumCount: 2)
      #expect(first.updatedCount == 2)
      #expect(first.hasMore)

      let second = try storage.backfillHistoryMetadataBatch(maximumCount: 2)
      #expect(second.updatedCount == 1)
      #expect(!second.hasMore)

      let items = try storage.context.fetch(FetchDescriptor<HistoryItem>())
      #expect(items.allSatisfy { $0.metadataVersion == HistoryItem.currentMetadataVersion })
      #expect(items.allSatisfy { $0.storedHasPlainText })
    }
  }

  @Test("Legacy stable identities are replaced in bounded batches")
  func identityBackfill() async throws {
    try await withStores { storage, _ in
      let sharedItemID = UUID()
      let sharedContentID = UUID()
      for value in ["one", "two", "three"] {
        let content = HistoryItemContent(type: "public.test", value: Data(value.utf8))
        content.id = sharedContentID
        content.identityVersion = 0
        let item = HistoryItem(contents: [content])
        item.stableID = sharedItemID
        item.identityVersion = 0
        storage.context.insert(item)
      }
      try storage.context.save()

      var hasMore = true
      var updated = 0
      while hasMore {
        let result = try storage.backfillStableIdentitiesBatch(maximumCount: 2)
        updated += result.updatedCount
        hasMore = result.hasMore
      }

      let items = try storage.context.fetch(FetchDescriptor<HistoryItem>())
      let contents = try storage.context.fetch(FetchDescriptor<HistoryItemContent>())
      #expect(updated == 6)
      #expect(Set(items.map(\.stableID)).count == 3)
      #expect(Set(contents.map(\.id)).count == 3)
      #expect(items.allSatisfy { $0.identityVersion == 1 })
      #expect(contents.allSatisfy { $0.identityVersion == 1 })
    }
  }

  @Test("Stable identity backfill preserves inline payload bytes")
  func identityBackfillPreservesPayload() async throws {
    try await withStores { storage, _ in
      let bytes = Data(repeating: 0xA5, count: 2 * 1_024 * 1_024)
      let content = HistoryItemContent(type: "public.test", value: bytes)
      content.identityVersion = 0
      let item = HistoryItem(contents: [content])
      item.identityVersion = 1
      storage.context.insert(item)
      try storage.context.save()

      let result = try storage.backfillStableIdentitiesBatch(maximumCount: 1)
      #expect(result.updatedCount == 1)
      #expect(!result.hasMore)

      let fetched = try #require(storage.context.fetch(FetchDescriptor<HistoryItemContent>()).first)
      #expect(fetched.identityVersion == 1)
      #expect(fetched.value == bytes)
    }
  }

  @Test("Large history deletion is bounded and preserves pins")
  func boundedHistoryDeletion() async throws {
    try await withStores { storage, _ in
      // Match the default production history cap with 200 unpinned records
      // plus three pins, while keeping the store disposable.
      for index in 0..<203 {
        let item = HistoryItem(contents: [
          HistoryItemContent(type: "public.test", value: Data("\(index)".utf8))
        ])
        item.pin = index < 3 ? "p\(index)" : nil
        storage.context.insert(item)
      }
      try storage.context.save()

      let cutoff = Date.now
      let deletionStarted = ContinuousClock.now
      let firstBatch = try storage.deleteHistoryBatch(
        includePinned: false,
        copiedBeforeOrAt: cutoff,
        maximumCount: 20
      )
      #expect(firstBatch == 20)
      #expect(try storage.context.fetchCount(FetchDescriptor<HistoryItem>()) == 183)

      let copiedAfterClear = HistoryItem(contents: [
        HistoryItemContent(type: "public.test", value: Data("new".utf8))
      ])
      copiedAfterClear.lastCopiedAt = cutoff.addingTimeInterval(1)
      storage.context.insert(copiedAfterClear)
      try storage.context.save()

      try await storage.deleteHistoryInBatches(
        includePinned: false,
        copiedBeforeOrAt: cutoff,
        maximumCount: 20
      )
      let deletionDuration = deletionStarted.duration(to: .now)
      print("MACCY_200_ITEM_CLEAR duration=\(deletionDuration)")
      #expect(deletionDuration < .seconds(5))
      #expect(try storage.context.fetchCount(FetchDescriptor<HistoryItem>()) == 4)
      #expect(try storage.context.fetchCount(FetchDescriptor<HistoryItemContent>()) == 4)

      try await storage.deleteHistoryInBatches(includePinned: true, maximumCount: 2)
      #expect(try storage.context.fetchCount(FetchDescriptor<HistoryItem>()) == 0)
      #expect(try storage.context.fetchCount(FetchDescriptor<HistoryItemContent>()) == 0)
    }
  }

  private func withStores(
    _ body: (Storage, PayloadStore) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "MaccyStorageMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let storage = Storage(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    try await body(storage, PayloadStore(baseURL: root))
  }
}

@MainActor
@Suite(.serialized)
struct RealStoreMigrationSmokeTests {
  @Test(
    "A 2.8.0 store copy opens and accepts bounded backfills",
    .enabled(if: FileManager.default.fileExists(atPath: "/tmp/MaccyMigrationSmoke/Storage.sqlite"))
  )
  func opensLegacyStoreCopy() throws {
    let storeURL = URL(fileURLWithPath: "/tmp/MaccyMigrationSmoke/Storage.sqlite")
    let storage = Storage(configuration: ModelConfiguration(url: storeURL))
    let itemCount = try storage.context.fetchCount(FetchDescriptor<HistoryItem>())
    let contentCount = try storage.context.fetchCount(FetchDescriptor<HistoryItemContent>())
    #expect(itemCount > 0)
    #expect(contentCount >= itemCount)

    let identities = try storage.backfillStableIdentitiesBatch(maximumCount: 25)
    let metadata = try storage.backfillHistoryMetadataBatch(maximumCount: 5)
    #expect(identities.updatedCount > 0)
    #expect(metadata.updatedCount > 0)

    var descriptor = FetchDescriptor<HistoryItemContent>()
    descriptor.fetchLimit = 10
    let sample = try storage.context.fetch(descriptor)
    #expect(sample.contains { $0.resolvedValue != nil })
  }

  @Test(
    "An external-only real store copy can be rehydrated for downgrade",
    .enabled(if: FileManager.default.fileExists(
      atPath: FileManager.default.temporaryDirectory
        .appending(path: "MaccyRollbackSmokeFixture/Storage.sqlite").path
    ))
  )
  func rehydratesExternalOnlyStoreCopy() async throws {
    let fixture = FileManager.default.temporaryDirectory
      .appending(path: "MaccyRollbackSmokeFixture", directoryHint: .isDirectory)
    let root = FileManager.default.temporaryDirectory
      .appending(path: "MaccyRollbackSmoke-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: fixture, to: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let storage = Storage(configuration: ModelConfiguration(
      url: root.appending(path: "Storage.sqlite")
    ))
    let payloadStore = PayloadStore(baseURL: root.appending(path: "Payloads", directoryHint: .isDirectory))

    let before = try storage.diagnosticsSnapshot()
    #expect(before.externalRepresentationCount > 0)

    var restoredCount = 0
    var restoredByteCount = 0
    var hasMore = true
    while hasMore {
      let result = try await storage.restoreInlinePayloadBatch(
        store: payloadStore,
        maximumCount: 20,
        maximumBytes: 16 * 1_024 * 1_024
      )
      restoredCount += result.restoredCount
      restoredByteCount += result.restoredByteCount
      hasMore = result.hasMore
    }

    let after = try storage.diagnosticsSnapshot()
    #expect(restoredCount == before.externalRepresentationCount)
    #expect(restoredByteCount > 0)
    #expect(after.externalRepresentationCount == before.externalRepresentationCount)
    #expect(after.inlineRepresentationCount >= before.externalRepresentationCount)
    let pendingRollbackCount = try storage.context.fetchCount(FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.value == nil && $0.payloadHash != nil && $0.payloadByteCount != nil }
    ))
    #expect(pendingRollbackCount == 0)

    var descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.payloadHash != nil && $0.value != nil }
    )
    descriptor.fetchLimit = 25
    let sample = try storage.context.fetch(descriptor)
    #expect(!sample.isEmpty)
    #expect(sample.allSatisfy { content in
      guard let value = content.value, let reference = content.payloadReference else { return false }
      return value.count == reference.byteCount && PayloadStore.hash(value) == reference.hash
    })
  }
}
