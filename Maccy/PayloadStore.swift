import CryptoKit
import Foundation

nonisolated struct PayloadReference: Equatable, Sendable {
  let hash: String
  let byteCount: Int
}

nonisolated struct PayloadGarbageCollectionResult: Equatable, Sendable {
  let removedFileCount: Int
  let reclaimedByteCount: Int64
}

nonisolated enum PayloadReadOperation: Equatable, Sendable {
  case model
  case paste
  case rollback
}

nonisolated struct PayloadStoreDiagnostics: Equatable, Sendable {
  let writeCount: Int
  let newFileCount: Int
  let deduplicatedWriteCount: Int
  let writtenByteCount: Int64
  let deduplicatedByteCount: Int64
  let modelReadByteCount: Int64
  let pasteReadByteCount: Int64
  let rollbackReadByteCount: Int64
  let missingPayloadCount: Int
  let corruptPayloadCount: Int
  let garbageCollectedFileCount: Int
  let garbageCollectedByteCount: Int64
}

nonisolated struct PayloadStoreInventory: Equatable, Sendable {
  let fileCount: Int
  let totalByteCount: Int64
}

nonisolated enum PayloadStoreError: Error, Equatable {
  case invalidHash(String)
  case missingPayload(String)
  case corruptPayload(hash: String, expectedByteCount: Int?, actualByteCount: Int)
  case hashMismatch(expected: String, actual: String)
}

/// Stores exact clipboard representation bytes in content-addressed files.
///
/// Writes use a temporary file in the destination directory followed by an
/// atomic rename. A database record can therefore reference only a complete
/// payload. The store deliberately deduplicates exact bytes only; it never
/// treats different image encodings as equivalent.
nonisolated final class PayloadStore: @unchecked Sendable {
  static let shared = PayloadStore(baseURL: defaultBaseURL)

  private static var defaultBaseURL: URL {
    #if DEBUG
    if AppDelegate.isTesting {
      // UI tests use an in-memory SwiftData store. Their payload files must be
      // isolated as well; otherwise test maintenance sees only test references
      // and can garbage-collect the real user's payload directory.
      return FileManager.default.temporaryDirectory.appending(
        path: "Maccy-Test-Payloads-\(ProcessInfo.processInfo.processIdentifier)",
        directoryHint: .isDirectory
      )
    }
    #endif
    return URL.applicationSupportDirectory.appending(path: "Maccy/Payloads", directoryHint: .isDirectory)
  }

  let baseURL: URL

  private let fileManager: FileManager
  private let lock = NSLock()
  private var diagnostics = PayloadStoreDiagnostics(
    writeCount: 0,
    newFileCount: 0,
    deduplicatedWriteCount: 0,
    writtenByteCount: 0,
    deduplicatedByteCount: 0,
    modelReadByteCount: 0,
    pasteReadByteCount: 0,
    rollbackReadByteCount: 0,
    missingPayloadCount: 0,
    corruptPayloadCount: 0,
    garbageCollectedFileCount: 0,
    garbageCollectedByteCount: 0
  )

  init(baseURL: URL, fileManager: FileManager = .default) {
    self.baseURL = baseURL
    self.fileManager = fileManager
  }

  func write(_ data: Data) throws -> PayloadReference {
    try lock.withLock {
      diagnostics = diagnostics.addingWrite(byteCount: data.count)
      let hash = Self.hash(data)
      let reference = PayloadReference(hash: hash, byteCount: data.count)
      let destination = try payloadURL(for: hash)

      if fileManager.fileExists(atPath: destination.path) {
        try verifyFile(at: destination, reference: reference)
        diagnostics = diagnostics.replacingLastWriteWithDeduplication(byteCount: data.count)
        return reference
      }

      let directory = destination.deletingLastPathComponent()
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let temporary = directory.appending(
        path: ".\(hash).\(UUID().uuidString).tmp",
        directoryHint: .notDirectory
      )

      do {
        try data.write(to: temporary, options: .atomic)
        try verifyFile(at: temporary, reference: reference)

        do {
          try fileManager.moveItem(at: temporary, to: destination)
          diagnostics = diagnostics.addingNewFile()
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          // Another writer won the race. Its bytes must still match the hash.
          try? fileManager.removeItem(at: temporary)
          try verifyFile(at: destination, reference: reference)
          diagnostics = diagnostics.replacingLastWriteWithDeduplication(byteCount: data.count)
        }
      } catch {
        try? fileManager.removeItem(at: temporary)
        throw error
      }

      return reference
    }
  }

  func read(
    _ reference: PayloadReference,
    operation: PayloadReadOperation = .model
  ) throws -> Data {
    try lock.withLock {
      let url = try payloadURL(for: reference.hash)
      guard fileManager.fileExists(atPath: url.path) else {
        diagnostics = diagnostics.addingMissingPayload()
        throw PayloadStoreError.missingPayload(reference.hash)
      }

      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      do {
        try verify(data, reference: reference)
      } catch {
        diagnostics = diagnostics.addingCorruptPayload()
        throw error
      }
      diagnostics = diagnostics.addingRead(byteCount: data.count, operation: operation)
      return data
    }
  }

  func verify(_ reference: PayloadReference) throws {
    try lock.withLock {
      let url = try payloadURL(for: reference.hash)
      guard fileManager.fileExists(atPath: url.path) else {
        throw PayloadStoreError.missingPayload(reference.hash)
      }
      try verifyFile(at: url, reference: reference)
    }
  }

  func contains(_ reference: PayloadReference) -> Bool {
    (try? verify(reference)) != nil
  }

  func payloadURL(for hash: String) throws -> URL {
    guard Self.isValidHash(hash) else {
      throw PayloadStoreError.invalidHash(hash)
    }

    return baseURL
      .appending(path: String(hash.prefix(2)), directoryHint: .isDirectory)
      .appending(path: "\(hash).blob", directoryHint: .notDirectory)
  }

  /// Removes only unreferenced payloads older than the grace date and stale
  /// temporary files. Referenced hashes are never removed.
  func garbageCollect(
    referencedHashes: Set<String>,
    olderThan graceDate: Date
  ) throws -> PayloadGarbageCollectionResult {
    try lock.withLock {
      guard fileManager.fileExists(atPath: baseURL.path) else {
        return PayloadGarbageCollectionResult(removedFileCount: 0, reclaimedByteCount: 0)
      }

      let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
      guard let enumerator = fileManager.enumerator(
        at: baseURL,
        includingPropertiesForKeys: Array(keys),
        options: []
      ) else {
        return PayloadGarbageCollectionResult(removedFileCount: 0, reclaimedByteCount: 0)
      }

      var removedFileCount = 0
      var reclaimedByteCount: Int64 = 0

      for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true,
              let modifiedAt = values.contentModificationDate,
              modifiedAt < graceDate else {
          continue
        }

        let filename = url.lastPathComponent
        let isTemporary = filename.hasSuffix(".tmp")
        let hash = filename.hasSuffix(".blob") ? String(filename.dropLast(5)) : ""
        guard isTemporary || (Self.isValidHash(hash) && !referencedHashes.contains(hash)) else {
          continue
        }

        let byteCount = Int64(values.fileSize ?? 0)
        try fileManager.removeItem(at: url)
        removedFileCount += 1
        reclaimedByteCount += byteCount
      }

      diagnostics = diagnostics.addingGarbageCollection(
        fileCount: removedFileCount,
        byteCount: reclaimedByteCount
      )
      return PayloadGarbageCollectionResult(
        removedFileCount: removedFileCount,
        reclaimedByteCount: reclaimedByteCount
      )
    }
  }

  func diagnosticsSnapshot() -> PayloadStoreDiagnostics {
    lock.withLock { diagnostics }
  }

  /// Explicit, background-only inventory. Startup never calls this scan.
  func inventory() throws -> PayloadStoreInventory {
    try lock.withLock {
      guard let enumerator = fileManager.enumerator(
        at: baseURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      ) else {
        return PayloadStoreInventory(fileCount: 0, totalByteCount: 0)
      }

      var fileCount = 0
      var totalByteCount: Int64 = 0
      for case let url as URL in enumerator where url.pathExtension == "blob" {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { continue }
        fileCount += 1
        totalByteCount += Int64(values.fileSize ?? 0)
      }
      return PayloadStoreInventory(fileCount: fileCount, totalByteCount: totalByteCount)
    }
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isValidHash(_ hash: String) -> Bool {
    hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private func verifyFile(at url: URL, reference: PayloadReference) throws {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    try verify(data, reference: reference)
  }

  private func verify(_ data: Data, reference: PayloadReference) throws {
    guard data.count == reference.byteCount else {
      throw PayloadStoreError.corruptPayload(
        hash: reference.hash,
        expectedByteCount: reference.byteCount,
        actualByteCount: data.count
      )
    }

    let actualHash = Self.hash(data)
    guard actualHash == reference.hash else {
      throw PayloadStoreError.hashMismatch(expected: reference.hash, actual: actualHash)
    }
  }
}

private extension PayloadStoreDiagnostics {
  nonisolated func addingWrite(byteCount: Int) -> Self {
    Self(
      writeCount: writeCount + 1,
      newFileCount: newFileCount,
      deduplicatedWriteCount: deduplicatedWriteCount,
      writtenByteCount: writtenByteCount + Int64(byteCount),
      deduplicatedByteCount: deduplicatedByteCount,
      modelReadByteCount: modelReadByteCount,
      pasteReadByteCount: pasteReadByteCount,
      rollbackReadByteCount: rollbackReadByteCount,
      missingPayloadCount: missingPayloadCount,
      corruptPayloadCount: corruptPayloadCount,
      garbageCollectedFileCount: garbageCollectedFileCount,
      garbageCollectedByteCount: garbageCollectedByteCount
    )
  }

  nonisolated func addingNewFile() -> Self {
    Self(
      writeCount: writeCount,
      newFileCount: newFileCount + 1,
      deduplicatedWriteCount: deduplicatedWriteCount,
      writtenByteCount: writtenByteCount,
      deduplicatedByteCount: deduplicatedByteCount,
      modelReadByteCount: modelReadByteCount,
      pasteReadByteCount: pasteReadByteCount,
      rollbackReadByteCount: rollbackReadByteCount,
      missingPayloadCount: missingPayloadCount,
      corruptPayloadCount: corruptPayloadCount,
      garbageCollectedFileCount: garbageCollectedFileCount,
      garbageCollectedByteCount: garbageCollectedByteCount
    )
  }

  nonisolated func replacingLastWriteWithDeduplication(byteCount: Int) -> Self {
    Self(
      writeCount: writeCount,
      newFileCount: newFileCount,
      deduplicatedWriteCount: deduplicatedWriteCount + 1,
      writtenByteCount: writtenByteCount,
      deduplicatedByteCount: deduplicatedByteCount + Int64(byteCount),
      modelReadByteCount: modelReadByteCount,
      pasteReadByteCount: pasteReadByteCount,
      rollbackReadByteCount: rollbackReadByteCount,
      missingPayloadCount: missingPayloadCount,
      corruptPayloadCount: corruptPayloadCount,
      garbageCollectedFileCount: garbageCollectedFileCount,
      garbageCollectedByteCount: garbageCollectedByteCount
    )
  }

  nonisolated func addingRead(byteCount: Int, operation: PayloadReadOperation) -> Self {
    Self(
      writeCount: writeCount,
      newFileCount: newFileCount,
      deduplicatedWriteCount: deduplicatedWriteCount,
      writtenByteCount: writtenByteCount,
      deduplicatedByteCount: deduplicatedByteCount,
      modelReadByteCount: modelReadByteCount + (operation == .model ? Int64(byteCount) : 0),
      pasteReadByteCount: pasteReadByteCount + (operation == .paste ? Int64(byteCount) : 0),
      rollbackReadByteCount: rollbackReadByteCount + (operation == .rollback ? Int64(byteCount) : 0),
      missingPayloadCount: missingPayloadCount,
      corruptPayloadCount: corruptPayloadCount,
      garbageCollectedFileCount: garbageCollectedFileCount,
      garbageCollectedByteCount: garbageCollectedByteCount
    )
  }

  nonisolated func addingMissingPayload() -> Self {
    replacingErrorCounts(missing: missingPayloadCount + 1, corrupt: corruptPayloadCount)
  }

  nonisolated func addingCorruptPayload() -> Self {
    replacingErrorCounts(missing: missingPayloadCount, corrupt: corruptPayloadCount + 1)
  }

  nonisolated func addingGarbageCollection(fileCount: Int, byteCount: Int64) -> Self {
    Self(
      writeCount: writeCount,
      newFileCount: newFileCount,
      deduplicatedWriteCount: deduplicatedWriteCount,
      writtenByteCount: writtenByteCount,
      deduplicatedByteCount: deduplicatedByteCount,
      modelReadByteCount: modelReadByteCount,
      pasteReadByteCount: pasteReadByteCount,
      rollbackReadByteCount: rollbackReadByteCount,
      missingPayloadCount: missingPayloadCount,
      corruptPayloadCount: corruptPayloadCount,
      garbageCollectedFileCount: garbageCollectedFileCount + fileCount,
      garbageCollectedByteCount: garbageCollectedByteCount + byteCount
    )
  }

  nonisolated private func replacingErrorCounts(missing: Int, corrupt: Int) -> Self {
    Self(
      writeCount: writeCount,
      newFileCount: newFileCount,
      deduplicatedWriteCount: deduplicatedWriteCount,
      writtenByteCount: writtenByteCount,
      deduplicatedByteCount: deduplicatedByteCount,
      modelReadByteCount: modelReadByteCount,
      pasteReadByteCount: pasteReadByteCount,
      rollbackReadByteCount: rollbackReadByteCount,
      missingPayloadCount: missing,
      corruptPayloadCount: corrupt,
      garbageCollectedFileCount: garbageCollectedFileCount,
      garbageCollectedByteCount: garbageCollectedByteCount
    )
  }
}
