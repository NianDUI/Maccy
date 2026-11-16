import AppKit
import Defaults
import Sauce
import SwiftData
import Vision

nonisolated struct OCRDiagnosticsSnapshot: Equatable, Sendable {
  let queueDepth: Int
  let completedCount: Int
  let failedCount: Int
  let totalDuration: TimeInterval
}

nonisolated final class OCRDiagnostics: @unchecked Sendable {
  static let shared = OCRDiagnostics()
  private let lock = NSLock()
  private var queueDepth = 0
  private var completedCount = 0
  private var failedCount = 0
  private var totalDuration: TimeInterval = 0

  func enqueued() {
    lock.withLock { queueDepth += 1 }
  }

  func finished(succeeded: Bool, duration: TimeInterval) {
    lock.withLock {
      queueDepth = max(0, queueDepth - 1)
      completedCount += succeeded ? 1 : 0
      failedCount += succeeded ? 0 : 1
      totalDuration += duration
    }
  }

  func snapshot() -> OCRDiagnosticsSnapshot {
    lock.withLock {
      OCRDiagnosticsSnapshot(
        queueDepth: queueDepth,
        completedCount: completedCount,
        failedCount: failedCount,
        totalDuration: totalDuration
      )
    }
  }
}

@Model
class HistoryItem {
  @MainActor
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    // "," reserved for preferences
    // "`" reserved for cycling through windows
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y",
      "[", "]", ";", "'", ".", "/", "-", "=", "\\"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    return keys
  }

  // Letters first, then symbols.
  static func sortedPins(_ pins: some Sequence<String>) -> [String] {
    pins.sorted { lhs, rhs in
      let lhsIsLetter = lhs.first?.isLetter ?? false
      let rhsIsLetter = rhs.first?.isLetter ?? false
      return lhsIsLetter == rhsIsLetter ? lhs < rhs : lhsIsLetter
    }
  }

  @MainActor
  static var availablePins: [String] {
    History.shared.availablePins
  }

  @MainActor
  static func availablePins(in items: [HistoryItem]) -> [String] {
    let assignedPins = Set(items.compactMap(\.pin))
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromMaccy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]
  private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types
  static let currentMetadataVersion = 2

  /// Spreadsheet applications commonly publish a rendered image alongside
  /// plain text, HTML/RTF, and their private cell formats. Treating any image
  /// representation as the primary presentation makes large cell selections
  /// look like screenshots and needlessly decodes enormous PNGs. The complete
  /// manifest is still retained and replayed; this only chooses the list and
  /// preview presentation.
  private static func isSpreadsheetSelection(types: Set<String>, hasPlainText: Bool) -> Bool {
    guard hasPlainText else { return false }

    return types.contains { type in
      let normalized = type.lowercased()
      return normalized.contains("spreadsheet") ||
        normalized.contains("com.microsoft.excel") ||
        normalized.contains("org.openxmlformats.spreadsheetml")
    }
  }

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var title = ""
  var manifestVersion: Int = 0
  var metadataVersion: Int = 0
  var stableID: UUID = UUID()
  var identityVersion: Int = 0
  var primaryContentKind: String = "unknown"
  var storedHasImage: Bool = false
  var storedHasPlainText: Bool = false
  var storedHasRichText: Bool = false
  var storedHasFileURLs: Bool = false
  var storedFromMaccy: Bool = false
  var storedUniversalClipboard: Bool = false
  var aggregatePayloadByteCount: Int = 0
  var imagePayloadByteCount: Int = 0
  var imagePixelWidth: Int?
  var imagePixelHeight: Int?
  var ocrStatus: String = "notRequested"
  var ocrVersion: Int = 0
  var thumbnailRevision: Int = 0

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  init(contents: [HistoryItemContent] = []) {
    self.stableID = UUID()
    self.identityVersion = 1
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
    if !contents.isEmpty {
      self.manifestVersion = 1
      refreshMetadata()
    }
  }

  func refreshMetadata() {
    let types = Set(contents.map(\.type))
    let imageTypeNames = Set(Self.imageTypes.map(\.rawValue))
    let hasDirectImage = !types.isDisjoint(with: imageTypeNames)
    let hasPlainText = types.contains(NSPasteboard.PasteboardType.string.rawValue)
    let hasRichText = types.contains(NSPasteboard.PasteboardType.rtf.rawValue) ||
      types.contains(NSPasteboard.PasteboardType.html.rawValue)
    let hasFileURL = types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
    let isUniversal = types.contains(NSPasteboard.PasteboardType.universalClipboard.rawValue)
    let universalCarriesContent = !types.isDisjoint(with: Set([
      NSPasteboard.PasteboardType.html.rawValue,
      NSPasteboard.PasteboardType.tiff.rawValue,
      NSPasteboard.PasteboardType.png.rawValue,
      NSPasteboard.PasteboardType.jpeg.rawValue,
      NSPasteboard.PasteboardType.rtf.rawValue,
      NSPasteboard.PasteboardType.string.rawValue,
      NSPasteboard.PasteboardType.heic.rawValue
    ]))
    let universalJPEGFile = isUniversal && contents.contains { content in
      guard content.type == NSPasteboard.PasteboardType.fileURL.rawValue,
            let data = content.resolvedValue,
            let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else {
        return false
      }
      return url.pathExtension.lowercased() == "jpeg"
    }

    storedHasImage = hasDirectImage || universalJPEGFile
    storedHasPlainText = hasPlainText
    storedHasRichText = hasRichText
    storedHasFileURLs = hasFileURL && !(isUniversal && universalCarriesContent)
    storedFromMaccy = types.contains(NSPasteboard.PasteboardType.fromMaccy.rawValue)
    storedUniversalClipboard = isUniversal
    // Do not fault legacy inline BLOBs merely to build list metadata. External
    // migration records exact byte counts without materializing Data again.
    aggregatePayloadByteCount = contents.reduce(0) { $0 + ($1.payloadByteCount ?? 0) }
    imagePayloadByteCount = contents.first(where: { imageTypeNames.contains($0.type) })?.payloadByteCount ?? 0
    let prefersTextPresentation = storedHasImage && Self.isSpreadsheetSelection(
      types: types,
      hasPlainText: hasPlainText
    )
    if prefersTextPresentation {
      primaryContentKind = "text"
    } else if storedHasImage {
      primaryContentKind = "image"
    } else if storedHasFileURLs {
      primaryContentKind = "file"
    } else if storedHasRichText {
      primaryContentKind = "richText"
    } else if storedHasPlainText {
      primaryContentKind = "text"
    } else {
      primaryContentKind = "other"
    }
    metadataVersion = Self.currentMetadataVersion
  }

  func recordImagePixelSize(_ size: NSSize) {
    imagePixelWidth = Int(size.width)
    imagePixelHeight = Int(size.height)
  }

  struct ContentIdentity {
    let type: String
    let byteCount: Int
    let hash: String?
  }

  func comparableContentIdentities() -> [ContentIdentity] {
    contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .map { content in
        let hash = content.payloadHash ?? content.value.map(PayloadStore.hash)
        return ContentIdentity(type: content.type, byteCount: content.byteCount, hash: hash)
      }
  }

  func supersedes(_ identities: [ContentIdentity]) -> Bool {
    identities.allSatisfy { identity in
      contents.contains { content in
        guard content.type == identity.type, content.byteCount == identity.byteCount else {
          return false
        }
        if let identityHash = identity.hash {
          if let payloadHash = content.payloadHash {
            return payloadHash == identityHash
          }
          return content.value.map(PayloadStore.hash) == identityHash
        }
        return content.payloadHash == nil && content.value == nil
      }
    }
  }

  @MainActor
  func generateTitle() -> String {
    let universalClipboardImageURL = universalClipboardImage ? fileURLs.first : nil
    if presentsAsImage && (hasContent(Self.imageTypes) || universalClipboardImageURL != nil) {
      guard ocrVersion != 1 || ocrStatus == "notRequested" else {
        return title
      }
      let pasteboardImageData = contentData(Self.imageTypes)
      ocrStatus = "processing"
      ocrVersion = 1
      OCRDiagnostics.shared.enqueued()
      Task {
        let startedAt = Date()
        if let recognizedText = await Self.recognizeText(
          imageData: pasteboardImageData,
          fileURL: universalClipboardImageURL
        ) {
          self.title = recognizedText
          self.ocrStatus = "completed"
          OCRDiagnostics.shared.finished(succeeded: true, duration: Date().timeIntervalSince(startedAt))
        } else {
          self.ocrStatus = "failed"
          OCRDiagnostics.shared.finished(succeeded: false, duration: Date().timeIntervalSince(startedAt))
        }
      }
      return ""
    }

    // 1k characters is trade-off for performance
    var title = previewableText
      .shortened(to: 1_000)
      .removingScalarsUnsafeForTitleLayout()

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  var previewableText: String {
    if !fileURLs.isEmpty {
      fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { contentData([.html]) }
  var html: NSAttributedString? {
    guard let data = htmlData else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

  var imageData: Data? {
    var data: Data?
    data = contentData(Self.imageTypes)
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      data = try? Data(contentsOf: url)
    }

    return data
  }

  var preferredImageContent: HistoryItemContent? {
    contents.first { content in
      Self.imageTypes.contains(NSPasteboard.PasteboardType(content.type))
    }
  }

  var thumbnailCacheKey: String {
    preferredImageContent?.payloadHash ?? "\(stableID.uuidString.lowercased())-\(thumbnailRevision)"
  }

  var hasImageRepresentation: Bool {
    metadataVersion > 0 ? storedHasImage : hasContent(Self.imageTypes) || universalClipboardImage
  }
  var presentsAsImage: Bool {
    metadataVersion > 0 ? primaryContentKind == "image" : hasImageRepresentation
  }
  var hasPlainTextRepresentation: Bool {
    metadataVersion > 0 ? storedHasPlainText : hasContent([.string])
  }
  var hasRichTextRepresentation: Bool {
    metadataVersion > 0 ? storedHasRichText : hasContent([.rtf, .html])
  }
  var hasFileURLRepresentation: Bool {
    metadataVersion > 0 ? storedHasFileURLs : hasContent([.fileURL]) && !universalClipboardText
  }

  var image: NSImage? {
    guard let data = imageData else {
      return nil
    }

    return NSImage(data: data)
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromMaccy: Bool { metadataVersion > 0 ? storedFromMaccy : hasContent([.fromMaccy]) }
  var universalClipboard: Bool {
    metadataVersion > 0 ? storedUniversalClipboard : hasContent([.universalClipboard])
  }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && hasContent([.html, .tiff, .png, .jpeg, .rtf, .string, .heic])
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.resolvedValue
  }

  private func hasContent(_ types: [NSPasteboard.PasteboardType]) -> Bool {
    let rawTypes = Set(types.map(\.rawValue))
    return contents.contains { rawTypes.contains($0.type) }
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap(\.resolvedValue)
  }

  nonisolated private static let textRecognitionQueue = DispatchQueue(
    label: "org.p0deje.Maccy.textRecognition",
    qos: .utility
  )

  /// Runs OCR on a dedicated queue so the blocking Vision call never occupies
  /// a thread of Swift's cooperative pool or the main thread.
  nonisolated private static func recognizeText(imageData: Data?, fileURL: URL?) async -> String? {
    await withCheckedContinuation { continuation in
      textRecognitionQueue.async {
        continuation.resume(returning: performTextRecognition(imageData: imageData, fileURL: fileURL))
      }
    }
  }

  nonisolated private static func performTextRecognition(imageData: Data?, fileURL: URL?) -> String? {
    guard let data = imageData ?? fileURL.flatMap({ try? Data(contentsOf: $0) }) else {
      return nil
    }

    let requestHandler = VNImageRequestHandler(data: data)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true

    do {
      try requestHandler.perform([request])
    } catch {
      print("Unable to perform the request: \(error).")
      return nil
    }

    guard let observations = request.results else {
      return nil
    }

    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}
