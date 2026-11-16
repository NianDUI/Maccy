import AppKit.NSPasteboard
import Defaults
import Foundation
import OSLog
import SwiftData

nonisolated struct PayloadMigrationBatchResult: Equatable, Sendable {
  let migratedCount: Int
  let migratedByteCount: Int
  let hasMore: Bool
}

nonisolated struct PayloadRollbackBatchResult: Equatable, Sendable {
  let restoredCount: Int
  let restoredByteCount: Int
  let hasMore: Bool
}

nonisolated struct StorageDiagnosticsSnapshot: Equatable, Sendable {
  let historyItemCount: Int
  let representationCount: Int
  let externalRepresentationCount: Int
  let inlineRepresentationCount: Int
  let pendingPayloadMigrationCount: Int
  let pendingMetadataBackfillCount: Int
}

enum MaccySchemaV2: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)
  static var models: [any PersistentModel.Type] {
    [HistoryItem.self, HistoryItemContent.self]
  }
}

enum MaccySchemaMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    [MaccySchemaV2.self]
  }

  static var stages: [MigrationStage] {
    []
  }
}

@MainActor
class Storage {
  static let shared = Storage()

  private let logger = Logger(subsystem: "org.p0deje.Maccy", category: "Storage")

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init(configuration: ModelConfiguration? = nil) {
    var config = configuration ?? ModelConfiguration(url: url)

    #if DEBUG
    if configuration == nil && AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(
        for: Schema(versionedSchema: MaccySchemaV2.self),
        migrationPlan: MaccySchemaMigrationPlan.self,
        configurations: config
      )
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  func removeUnpersistableContents() throws -> Int {
    let contents = try context.fetch(FetchDescriptor<HistoryItemContent>())
    let unwanted = contents.filter {
      !Clipboard.shared.isPersistable(NSPasteboard.PasteboardType($0.type))
    }

    guard !unwanted.isEmpty else {
      return 0
    }

    unwanted.forEach(context.delete)
    context.processPendingChanges()
    try context.save()

    return unwanted.count
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    try context.save()

    return count
  }

  /// Migrates a bounded batch while retaining inline BLOBs. Progress is
  /// persisted on each representation, so interruption simply resumes from
  /// the next record without a separate migration cursor.
  func migrateLegacyPayloadBatch(
    store: PayloadStore = .shared,
    maximumCount: Int = 20,
    maximumBytes: Int = 16 * 1_024 * 1_024
  ) async throws -> PayloadMigrationBatchResult {
    var descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.payloadHash == nil && $0.value != nil }
    )
    descriptor.fetchLimit = max(1, maximumCount)
    let candidates = try context.fetch(descriptor)

    var selected: [(token: Int, data: Data)] = []
    var selectedBytes = 0
    for content in candidates {
      guard let data = content.value else { continue }
      if !selected.isEmpty && selectedBytes + data.count > maximumBytes {
        break
      }
      selected.append((selected.count, data))
      selectedBytes += data.count
    }

    guard !selected.isEmpty else {
      return PayloadMigrationBatchResult(migratedCount: 0, migratedByteCount: 0, hasMore: false)
    }

    let references = try await Task.detached(priority: .utility) {
      try selected.map { input in
        (token: input.token, reference: try store.write(input.data))
      }
    }.value

    for (content, result) in zip(candidates, references) {
      let reference = result.reference
      content.recordVerifiedPayload(reference)
    }
    var refreshedItems = Set<PersistentIdentifier>()
    for content in candidates {
      guard let item = content.item,
            refreshedItems.insert(item.persistentModelID).inserted else { continue }
      item.refreshMetadata()
    }
    context.processPendingChanges()
    try context.save()

    var moreDescriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.payloadHash == nil && $0.value != nil }
    )
    moreDescriptor.fetchLimit = 1
    let hasMore = try !context.fetch(moreDescriptor).isEmpty
    return PayloadMigrationBatchResult(
      migratedCount: references.count,
      migratedByteCount: selectedBytes,
      hasMore: hasMore
    )
  }

  func backfillHistoryMetadataBatch(maximumCount: Int = 10) throws -> (updatedCount: Int, hasMore: Bool) {
    let currentMetadataVersion = HistoryItem.currentMetadataVersion
    var descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.metadataVersion < currentMetadataVersion }
    )
    descriptor.fetchLimit = max(1, maximumCount)
    let items = try context.fetch(descriptor)
    for item in items {
      let previousPrimaryContentKind = item.primaryContentKind
      item.refreshMetadata()
      if previousPrimaryContentKind == "image", item.primaryContentKind == "text" {
        item.title = item.generateTitle()
      }
    }
    if !items.isEmpty {
      context.processPendingChanges()
      try context.save()
    }

    var moreDescriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.metadataVersion < currentMetadataVersion }
    )
    moreDescriptor.fetchLimit = 1
    return (items.count, try !context.fetch(moreDescriptor).isEmpty)
  }

  /// SwiftData uses schema defaults when adding fields to an existing store.
  /// UUID defaults can therefore be shared by legacy rows. Assign identities
  /// explicitly before using stable IDs as cache keys or diagnostics keys.
  func backfillStableIdentitiesBatch(maximumCount: Int = 50) throws -> (updatedCount: Int, hasMore: Bool) {
    let limit = max(1, maximumCount)
    var itemDescriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.identityVersion == 0 }
    )
    itemDescriptor.fetchLimit = limit
    let items = try context.fetch(itemDescriptor)
    for item in items {
      item.stableID = UUID()
      item.identityVersion = 1
    }

    let remainingCapacity = max(0, limit - items.count)
    var contents: [HistoryItemContent] = []
    if remainingCapacity > 0 {
      var contentDescriptor = FetchDescriptor<HistoryItemContent>(
        predicate: #Predicate { $0.identityVersion == 0 }
      )
      contentDescriptor.fetchLimit = remainingCapacity
      // Updating a legacy row identity must not fault its potentially large
      // inline payload. Fetch only the columns touched by this backfill.
      contentDescriptor.propertiesToFetch = [
        \HistoryItemContent.id,
        \HistoryItemContent.identityVersion
      ]
      contents = try context.fetch(contentDescriptor)
      for content in contents {
        content.id = UUID()
        content.identityVersion = 1
      }
    }

    let updatedCount = items.count + contents.count
    if updatedCount > 0 {
      context.processPendingChanges()
      try context.save()
    }

    var moreItems = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.identityVersion == 0 })
    moreItems.fetchLimit = 1
    var moreContents = FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.identityVersion == 0 })
    moreContents.fetchLimit = 1
    let hasMore = try !context.fetch(moreItems).isEmpty || !context.fetch(moreContents).isEmpty
    return (updatedCount, hasMore)
  }

  /// Removes inline fallbacks only after every referenced payload in this
  /// batch has been re-verified. This is intentionally separate from migrate.
  func removeVerifiedInlinePayloadBatch(
    store: PayloadStore = .shared,
    maximumCount: Int = 20
  ) async throws -> Int {
    var descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate {
        $0.value != nil && $0.payloadHash != nil && $0.payloadByteCount != nil && $0.payloadVerifiedAt != nil
      }
    )
    descriptor.fetchLimit = max(1, maximumCount)
    let candidates = try context.fetch(descriptor)
    let references = candidates.enumerated().compactMap { index, content -> (Int, PayloadReference)? in
      guard let reference = content.payloadReference else { return nil }
      return (index, reference)
    }

    let verifiedIndices = try await Task.detached(priority: .utility) {
      try references.map { index, reference in
        try store.verify(reference)
        return index
      }
    }.value
    for index in verifiedIndices {
      candidates[index].value = nil
    }
    context.processPendingChanges()
    try context.save()
    return verifiedIndices.count
  }

  /// Rehydrates inline BLOBs before disabling the external store or installing
  /// a build that does not understand payload references.
  func restoreInlinePayloadBatch(
    store: PayloadStore = .shared,
    maximumCount: Int = 20,
    maximumBytes: Int = 16 * 1_024 * 1_024
  ) async throws -> PayloadRollbackBatchResult {
    var descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate {
        $0.value == nil && $0.payloadHash != nil && $0.payloadByteCount != nil
      }
    )
    descriptor.fetchLimit = max(1, maximumCount)
    let candidates = try context.fetch(descriptor)

    var references: [(token: Int, reference: PayloadReference)] = []
    var selectedBytes = 0
    for content in candidates {
      guard let reference = content.payloadReference else { continue }
      if !references.isEmpty && selectedBytes + reference.byteCount > maximumBytes {
        break
      }
      references.append((references.count, reference))
      selectedBytes += reference.byteCount
    }

    guard !references.isEmpty else {
      return PayloadRollbackBatchResult(restoredCount: 0, restoredByteCount: 0, hasMore: false)
    }

    let restored = try await Task.detached(priority: .utility) {
      try references.map { input in
        (token: input.token, data: try store.read(input.reference, operation: .rollback))
      }
    }.value
    for (content, result) in zip(candidates, restored) {
      content.value = result.data
    }
    context.processPendingChanges()
    try context.save()

    var moreDescriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate {
        $0.value == nil && $0.payloadHash != nil && $0.payloadByteCount != nil
      }
    )
    moreDescriptor.fetchLimit = 1
    let hasMore = try !context.fetch(moreDescriptor).isEmpty
    return PayloadRollbackBatchResult(
      restoredCount: restored.count,
      restoredByteCount: selectedBytes,
      hasMore: hasMore
    )
  }

  func garbageCollectPayloads(
    store: PayloadStore = .shared,
    gracePeriod: TimeInterval = 7 * 24 * 60 * 60
  ) async throws -> PayloadGarbageCollectionResult {
    var descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.payloadHash != nil }
    )
    // A full HistoryItemContent fetch also materializes legacy inline BLOBs,
    // even though GC needs only the reference column. On a real 345 MiB store
    // that made every external-storage launch briefly exceed 1 GiB RSS.
    descriptor.propertiesToFetch = [\HistoryItemContent.payloadHash]
    let contents = try context.fetch(descriptor)
    let referencedHashes = Set(contents.compactMap(\.payloadHash))
    let graceDate = Date(timeIntervalSinceNow: -gracePeriod)
    return try await Task.detached(priority: .utility) {
      try store.garbageCollect(referencedHashes: referencedHashes, olderThan: graceDate)
    }.value
  }

  func diagnosticsSnapshot() throws -> StorageDiagnosticsSnapshot {
    let currentMetadataVersion = HistoryItem.currentMetadataVersion
    let historyItemCount = try context.fetchCount(FetchDescriptor<HistoryItem>())
    let representationCount = try context.fetchCount(FetchDescriptor<HistoryItemContent>())
    let externalRepresentationCount = try context.fetchCount(FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.payloadHash != nil && $0.payloadVerifiedAt != nil }
    ))
    let inlineRepresentationCount = try context.fetchCount(FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.value != nil }
    ))
    let pendingPayloadMigrationCount = try context.fetchCount(FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.payloadHash == nil && $0.value != nil }
    ))
    let pendingMetadataBackfillCount = try context.fetchCount(FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.metadataVersion < currentMetadataVersion }
    ))
    return StorageDiagnosticsSnapshot(
      historyItemCount: historyItemCount,
      representationCount: representationCount,
      externalRepresentationCount: externalRepresentationCount,
      inlineRepresentationCount: inlineRepresentationCount,
      pendingPayloadMigrationCount: pendingPayloadMigrationCount,
      pendingMetadataBackfillCount: pendingMetadataBackfillCount
    )
  }

  func prepareForHistoryLoad() async throws {
    var hasMoreIdentities = true
    while hasMoreIdentities {
      hasMoreIdentities = try backfillStableIdentitiesBatch(maximumCount: 50).hasMore
      await Task.yield()
    }

    var hasMoreMetadata = true
    while hasMoreMetadata {
      hasMoreMetadata = try backfillHistoryMetadataBatch(maximumCount: 25).hasMore
      await Task.yield()
    }
  }

  @discardableResult
  func deleteHistoryBatch(
    includePinned: Bool,
    copiedBeforeOrAt cutoff: Date = .distantFuture,
    maximumCount: Int = 20
  ) throws -> Int {
    var descriptor: FetchDescriptor<HistoryItem>
    if includePinned {
      descriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.lastCopiedAt <= cutoff })
    } else {
      descriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate {
        $0.pin == nil && $0.lastCopiedAt <= cutoff
      })
    }
    descriptor.fetchLimit = max(1, maximumCount)
    let items = try context.fetch(descriptor)
    guard !items.isEmpty else {
      _ = try cleanupOrphanedContents()
      return 0
    }

    for item in items {
      item.contents.forEach(context.delete)
      context.delete(item)
    }
    context.processPendingChanges()
    try context.save()
    return items.count
  }

  func deleteHistoryInBatches(
    includePinned: Bool,
    copiedBeforeOrAt cutoff: Date = .distantFuture,
    maximumCount: Int = 20
  ) async throws {
    while !Task.isCancelled {
      guard try deleteHistoryBatch(
        includePinned: includePinned,
        copiedBeforeOrAt: cutoff,
        maximumCount: maximumCount
      ) > 0 else {
        return
      }
      await Task.yield()
    }
  }

  func deleteHistoryImmediately(
    includePinned: Bool,
    copiedBeforeOrAt cutoff: Date = .distantFuture
  ) throws {
    while try deleteHistoryBatch(
      includePinned: includePinned,
      copiedBeforeOrAt: cutoff,
      maximumCount: 100
    ) > 0 {}
  }

  func runBackgroundMaintenance(store: PayloadStore = .shared) async {
    do {
      let externalStorageEnabled = StorageRollout.externalPayloadStorageEnabled
      let inlineCleanupEnabled = externalStorageEnabled && StorageRollout.verifiedInlinePayloadCleanupEnabled
      logger.info("Storage maintenance started; external=\(externalStorageEnabled, privacy: .public) inlineCleanup=\(inlineCleanupEnabled, privacy: .public)")
      var hasMoreIdentities = true
      while hasMoreIdentities && !Task.isCancelled {
        let result = try backfillStableIdentitiesBatch()
        hasMoreIdentities = result.hasMore
        if result.updatedCount > 0 {
          logger.info("Backfilled \(result.updatedCount, privacy: .public) stable storage identities")
        }
        await Task.yield()
      }

      if externalStorageEnabled {
        var hasMorePayloads = true
        while hasMorePayloads && !Task.isCancelled {
          let result = try await migrateLegacyPayloadBatch(store: store)
          hasMorePayloads = result.hasMore
          if result.migratedCount > 0 {
            logger.info("Migrated \(result.migratedCount, privacy: .public) payload representations (\(result.migratedByteCount, privacy: .public) bytes)")
          }
          await Task.yield()
        }

        if inlineCleanupEnabled {
          var removedCount = 0
          while !Task.isCancelled {
            let removed = try await removeVerifiedInlinePayloadBatch(store: store)
            guard removed > 0 else { break }
            removedCount += removed
            await Task.yield()
          }
          if removedCount > 0 {
            logger.info("Removed \(removedCount, privacy: .public) verified inline payloads")
          }
        }

        let garbageCollection = try await garbageCollectPayloads(store: store)
        if garbageCollection.removedFileCount > 0 {
          logger.info("Garbage-collected \(garbageCollection.removedFileCount, privacy: .public) payload files (\(garbageCollection.reclaimedByteCount, privacy: .public) bytes)")
        }
      }

      var hasMoreMetadata = true
      while hasMoreMetadata && !Task.isCancelled {
        let result = try backfillHistoryMetadataBatch(maximumCount: 5)
        hasMoreMetadata = result.hasMore
        if result.updatedCount > 0 {
          logger.info("Backfilled metadata for \(result.updatedCount, privacy: .public) history items")
        }
        await Task.yield()
      }

      try await Task.detached(priority: .background) {
        try ThumbnailStore.shared.trim()
      }.value
    } catch {
      // Maintenance is resumable from persisted per-record state. A later
      // launch retries without making clipboard capture unavailable.
      logger.error("Storage maintenance failed: \(String(reflecting: error), privacy: .public)")
    }
  }
}
