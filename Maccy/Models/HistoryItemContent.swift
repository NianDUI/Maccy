import Foundation
import SwiftData

@Model
class HistoryItemContent {
  var id: UUID = UUID()
  var identityVersion: Int = 0
  var type: String = ""
  var value: Data?
  var itemIndex: Int = 0
  var representationIndex: Int = 0
  var payloadHash: String?
  var payloadByteCount: Int?
  var payloadVerifiedAt: Date?

  @Relationship
  var item: HistoryItem?

  init(
    type: String,
    value: Data? = nil,
    itemIndex: Int = 0,
    representationIndex: Int = 0
  ) {
    self.id = UUID()
    self.identityVersion = 1
    self.type = type
    self.value = value
    self.payloadByteCount = value?.count
    self.itemIndex = itemIndex
    self.representationIndex = representationIndex
  }

  var byteCount: Int { payloadByteCount ?? value?.count ?? 0 }
  var isExternallyStored: Bool { payloadReference != nil && payloadVerifiedAt != nil }

  var resolvedValue: Data? {
    resolvedValue(from: .shared)
  }

  var payloadReference: PayloadReference? {
    guard let payloadHash, let payloadByteCount else {
      return nil
    }
    return PayloadReference(hash: payloadHash, byteCount: payloadByteCount)
  }

  /// Reads verified external bytes first and preserves the legacy inline BLOB
  /// as a compatibility fallback during migration and rollback windows.
  func resolvedValue(from store: PayloadStore) -> Data? {
    if payloadVerifiedAt != nil,
       let payloadReference,
       let externalValue = try? store.read(payloadReference) {
      return externalValue
    }
    return value
  }

  @discardableResult
  func externalize(
    retainingInlineValue: Bool,
    store: PayloadStore = .shared
  ) throws -> PayloadReference? {
    guard let sourceValue = resolvedValue(from: store) else {
      return nil
    }

    let reference = try store.write(sourceValue)
    payloadHash = reference.hash
    payloadByteCount = reference.byteCount
    payloadVerifiedAt = .now
    if !retainingInlineValue {
      value = nil
    }
    return reference
  }

  func removeInlineValueIfVerified(store: PayloadStore = .shared) throws {
    guard let payloadReference, payloadVerifiedAt != nil else {
      return
    }
    try store.verify(payloadReference)
    value = nil
  }

  func recordVerifiedPayload(_ reference: PayloadReference, verifiedAt: Date = .now) {
    payloadHash = reference.hash
    payloadByteCount = reference.byteCount
    payloadVerifiedAt = verifiedAt
  }

  func restoreInlineValue(store: PayloadStore = .shared) throws {
    guard value == nil, let payloadReference else {
      return
    }
    value = try store.read(payloadReference)
  }

  func replaceInlineValue(_ data: Data?) {
    value = data
    payloadHash = nil
    payloadByteCount = data?.count
    payloadVerifiedAt = nil
  }
}
