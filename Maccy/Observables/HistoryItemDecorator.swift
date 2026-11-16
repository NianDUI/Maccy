import AppKit.NSWorkspace
import Defaults
import Foundation
import ImageIO
import Observation
import Sauce
import UniformTypeIdentifiers

nonisolated struct HistoryImageCacheDiagnostics: Equatable, Sendable {
  let thumbnailInsertionCount: Int
  let previewInsertionCount: Int
  let thumbnailInsertedPixelCost: Int64
  let previewInsertedPixelCost: Int64
  let thumbnailEvictionCount: Int
  let previewEvictionCount: Int
  let memoryPressureClearCount: Int
}

private nonisolated final class CacheEvictionCounter: NSObject, NSCacheDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  nonisolated func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
    lock.withLock { value += 1 }
  }

  nonisolated var count: Int {
    lock.withLock { value }
  }
}

nonisolated final class ThumbnailStore: @unchecked Sendable {
  static let shared = ThumbnailStore(
    baseURL: defaultBaseURL
  )

  private static var defaultBaseURL: URL {
    #if DEBUG
    if AppDelegate.isTesting {
      return FileManager.default.temporaryDirectory.appending(
        path: "Maccy-Test-Thumbnails-\(ProcessInfo.processInfo.processIdentifier)",
        directoryHint: .isDirectory
      )
    }
    #endif
    return URL.applicationSupportDirectory.appending(path: "Maccy/Thumbnails", directoryHint: .isDirectory)
  }

  private let baseURL: URL
  private let fileManager = FileManager.default
  private let lock = NSLock()

  init(baseURL: URL) {
    self.baseURL = baseURL
  }

  func image(for key: String) -> CGImage? {
    lock.withLock {
      let url = fileURL(for: key)
      guard fileManager.fileExists(atPath: url.path) else {
        return nil
      }
      guard let source = CGImageSourceCreateWithURL(url as CFURL, [
        kCGImageSourceShouldCache: false
      ] as CFDictionary),
      let image = CGImageSourceCreateImageAtIndex(source, 0, [
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary) else {
        try? fileManager.removeItem(at: url)
        return nil
      }
      return image
    }
  }

  func write(_ image: CGImage, for key: String) throws {
    try lock.withLock {
      try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
      let destination = fileURL(for: key)
      let temporary = baseURL.appending(path: ".\(UUID().uuidString).tmp")
      defer { try? fileManager.removeItem(at: temporary) }
      guard let destinationWriter = CGImageDestinationCreateWithURL(
        temporary as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
        return
      }
      CGImageDestinationAddImage(destinationWriter, image, nil)
      guard CGImageDestinationFinalize(destinationWriter) else {
        return
      }
      if fileManager.fileExists(atPath: destination.path) {
        return
      } else {
        try fileManager.moveItem(at: temporary, to: destination)
      }
    }
  }

  func removeAll() {
    lock.withLock {
      try? fileManager.removeItem(at: baseURL)
    }
  }

  func trim(maximumByteCount: Int64 = 128 * 1_024 * 1_024) throws {
    try lock.withLock {
      guard let enumerator = fileManager.enumerator(
        at: baseURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      ) else { return }

      var files: [(url: URL, byteCount: Int64, modifiedAt: Date)] = []
      var totalByteCount: Int64 = 0
      for case let url as URL in enumerator where url.pathExtension == "png" {
        let values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
        ])
        guard values.isRegularFile == true else { continue }
        let byteCount = Int64(values.fileSize ?? 0)
        files.append((url, byteCount, values.contentModificationDate ?? .distantPast))
        totalByteCount += byteCount
      }

      for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) where totalByteCount > maximumByteCount {
        try fileManager.removeItem(at: file.url)
        totalByteCount -= file.byteCount
      }
    }
  }

  private func fileURL(for key: String) -> URL {
    let safeKey = key.filter { $0.isHexDigit || $0 == "-" }
    return baseURL.appending(path: "\(safeKey).png", directoryHint: .notDirectory)
  }
}

private final class HistoryImageCache: @unchecked Sendable {
  static let shared = HistoryImageCache()

  private let thumbnails = NSCache<NSString, NSImage>()
  private let previews = NSCache<NSString, NSImage>()
  private let thumbnailEvictions = CacheEvictionCounter()
  private let previewEvictions = CacheEvictionCounter()
  private let memoryPressureSource: DispatchSourceMemoryPressure
  private var thumbnailInsertionCount = 0
  private var previewInsertionCount = 0
  private var thumbnailInsertedPixelCost: Int64 = 0
  private var previewInsertedPixelCost: Int64 = 0
  private var memoryPressureClearCount = 0

  private init() {
    thumbnails.countLimit = 50
    thumbnails.totalCostLimit = 32 * 1_024 * 1_024
    // Only one preview is visible at a time. Keep the original-resolution image
    // so Retina displays never enlarge an already-downsampled intermediate.
    previews.countLimit = 1
    previews.totalCostLimit = 96 * 1_024 * 1_024
    thumbnails.delegate = thumbnailEvictions
    previews.delegate = previewEvictions

    memoryPressureSource = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: .main
    )
    memoryPressureSource.setEventHandler { [weak self] in
      self?.memoryPressureClearCount += 1
      self?.removeAllPreviews()
      self?.removeAllThumbnails()
    }
    memoryPressureSource.resume()
  }

  func thumbnail(for id: UUID) -> NSImage? {
    thumbnails.object(forKey: id.uuidString as NSString)
  }

  func setThumbnail(_ image: NSImage?, for id: UUID) {
    let cost = set(image, in: thumbnails, for: id)
    if cost > 0 {
      thumbnailInsertionCount += 1
      thumbnailInsertedPixelCost += Int64(cost)
    }
  }

  func preview(for id: UUID) -> NSImage? {
    previews.object(forKey: id.uuidString as NSString)
  }

  func setPreview(_ image: NSImage?, for id: UUID) {
    let cost = set(image, in: previews, for: id)
    if cost > 0 {
      previewInsertionCount += 1
      previewInsertedPixelCost += Int64(cost)
    }
  }

  func removeAllThumbnails() {
    thumbnails.removeAllObjects()
  }

  func removeAllPreviews() {
    previews.removeAllObjects()
  }

  func diagnosticsSnapshot() -> HistoryImageCacheDiagnostics {
    HistoryImageCacheDiagnostics(
      thumbnailInsertionCount: thumbnailInsertionCount,
      previewInsertionCount: previewInsertionCount,
      thumbnailInsertedPixelCost: thumbnailInsertedPixelCost,
      previewInsertedPixelCost: previewInsertedPixelCost,
      thumbnailEvictionCount: thumbnailEvictions.count,
      previewEvictionCount: previewEvictions.count,
      memoryPressureClearCount: memoryPressureClearCount
    )
  }

  @discardableResult
  private func set(_ image: NSImage?, in cache: NSCache<NSString, NSImage>, for id: UUID) -> Int {
    let key = id.uuidString as NSString
    guard let image else {
      cache.removeObject(forKey: key)
      return 0
    }

    let pixels = image.pixelSize
    let cost = max(1, Int(pixels.width * pixels.height * 4))
    cache.setObject(image, forKey: key, cost: cost)
    return cost
  }
}

struct GeneratedThumbnail: @unchecked Sendable {
  let image: CGImage
  let originalPixelSize: NSSize
  let displaySize: NSSize
}

/// Serializes ImageIO work so opening a list of large images cannot create
/// multiple full-decoding memory spikes at the same time.
actor ThumbnailDecodeScheduler {
  static let shared = ThumbnailDecodeScheduler()

  private func originalPixelSize(data: Data) -> NSSize? {
    guard !Task.isCancelled,
          let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
          ] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          width > 0,
          height > 0 else {
      return nil
    }
    return NSSize(width: width, height: height)
  }

  func generate(data: Data, targetSize: NSSize, scale: CGFloat) -> GeneratedThumbnail? {
    guard !Task.isCancelled,
          let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
          ] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          width > 0,
          height > 0 else {
      return nil
    }

    let targetWidth = max(1, targetSize.width * scale)
    let targetHeight = max(1, targetSize.height * scale)
    let ratio = min(targetWidth / width, targetHeight / height, 1)
    let maxPixelSize = max(1, Int(ceil(max(width * ratio, height * ratio))))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true
    ]

    guard !Task.isCancelled,
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          !Task.isCancelled else {
      return nil
    }

    return GeneratedThumbnail(
      image: thumbnail,
      originalPixelSize: NSSize(width: width, height: height),
      displaySize: NSSize(
        width: CGFloat(thumbnail.width) / scale,
        height: CGFloat(thumbnail.height) / scale
      )
    )
  }

  func cachedOrGenerate(
    cacheKey: String,
    reference: PayloadReference?,
    inlineData: Data?,
    knownOriginalSize: NSSize?,
    targetSize: NSSize,
    scale: CGFloat,
    payloadStore: PayloadStore = .shared,
    thumbnailStore: ThumbnailStore = .shared
  ) -> GeneratedThumbnail? {
    if let cached = thumbnailStore.image(for: cacheKey) {
      // A derived thumbnail does not carry the original dimensions. When old
      // metadata is missing, inspect only the source properties (without
      // decoding its bitmap) rather than recording the thumbnail dimensions
      // as the source dimensions. Misclassifying an extreme image here would
      // route its popup back through the expensive full-source preview path.
      let originalSize: NSSize?
      if let knownOriginalSize {
        originalSize = knownOriginalSize
      } else if let data = reference.flatMap({ try? payloadStore.read($0, operation: .model) }) ?? inlineData {
        originalSize = originalPixelSize(data: data)
      } else {
        originalSize = nil
      }
      guard let originalSize else { return nil }
      return GeneratedThumbnail(
        image: cached,
        originalPixelSize: originalSize,
        displaySize: NSSize(width: CGFloat(cached.width) / scale, height: CGFloat(cached.height) / scale)
      )
    }

    guard let data = reference.flatMap({ try? payloadStore.read($0, operation: .model) }) ?? inlineData,
          let generated = generate(data: data, targetSize: targetSize, scale: scale) else {
      return nil
    }
    try? thumbnailStore.write(generated.image, for: cacheKey)
    return generated
  }
}

/// Serializes full-resolution preview decoding away from the main actor. A
/// preview intentionally keeps source resolution for sharp Retina rendering,
/// but only one decode and one cached preview are allowed at a time.
actor PreviewDecodeScheduler {
  static let shared = PreviewDecodeScheduler()

  struct Result: @unchecked Sendable {
    let image: CGImage
    let originalPixelSize: NSSize
  }

  func decode(
    reference: PayloadReference?,
    inlineData: Data?,
    maximumPixelDimension: Int,
    payloadStore: PayloadStore = .shared
  ) -> Result? {
    guard !Task.isCancelled,
          let data = reference.flatMap({ try? payloadStore.read($0, operation: .model) }) ?? inlineData,
          !Task.isCancelled,
          let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
          ] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
      return nil
    }

    let image: CGImage?
    if max(width, height) > maximumPixelDimension {
      // Downsample during decoding. Decoding a 4936×154948 long screenshot at
      // full resolution would require several GiB before SwiftUI scales it.
      image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary)
    } else {
      image = CGImageSourceCreateImageAtIndex(source, 0, [
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary)
    }
    guard !Task.isCancelled, let image else { return nil }
    return Result(
      image: image,
      originalPixelSize: NSSize(width: width, height: height)
    )
  }
}

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  private static let previewMaxParagraphSize = 10_000
  private static let maximumFullPreviewPixelCount = 24 * 1_024 * 1_024

  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }
  static var imageCacheDiagnostics: HistoryImageCacheDiagnostics {
    HistoryImageCache.shared.diagnosticsSnapshot()
  }

  static func shouldUseThumbnailPreview(width: Int, height: Int) -> Bool {
    guard width > 0, height > 0 else { return false }
    return Double(width) * Double(height) > Double(maximumFullPreviewPixelCount)
  }

  let id: UUID

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  /// Whether the item should be presented as an image. A record may retain an
  /// image representation for lossless pasteboard replay while using text as
  /// its primary presentation (for example, a copied spreadsheet range).
  var hasImage: Bool { item.presentsAsImage }
  var hasFileURLs: Bool { item.hasFileURLRepresentation }
  var hasPlainText: Bool { item.hasPlainTextRepresentation }
  var hasRichText: Bool { item.hasRichTextRepresentation }

  var thumbnailImageGenerationTask: Task<Void, Never>?
  private var thumbnailGenerationID: UUID?
  private var imageCacheRevision = 0
  var previewImage: NSImage? {
    get {
      _ = imageCacheRevision
      return HistoryImageCache.shared.preview(for: id)
    }
    set {
      HistoryImageCache.shared.setPreview(newValue, for: id)
      imageCacheRevision &+= 1
    }
  }
  private(set) var previewText = SizedString("")
  private(set) var imagePixelSize: NSSize?
  var thumbnailImage: NSImage? {
    get {
      _ = imageCacheRevision
      return HistoryImageCache.shared.thumbnail(for: id)
    }
    set {
      HistoryImageCache.shared.setThumbnail(newValue, for: id)
      imageCacheRevision &+= 1
    }
  }
  var applicationImage: ApplicationImage

  @ObservationIgnored
  private(set) lazy var imageSize: String? = {
    if item.metadataVersion > 0, item.imagePayloadByteCount > 0 {
      return ByteCountFormatter.string(fromByteCount: Int64(item.imagePayloadByteCount), countStyle: .file)
    }
    // Legacy rows may not have byte-count metadata until external migration.
    // Preserve the old preview behavior, but fault bytes only when the preview
    // actually asks for the size—not while constructing the history list.
    return item.imageData.map {
      ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file)
    }
  }()

  // 10k characters seems to be more than enough on large displays
  var text: String {
    if hasImage {
      return item.title.shortened(to: 10_000)
    }
    // This property is used by the menu-bar title and explicit consumers, not
    // while constructing every list row. Preserve its full-content semantics
    // while keeping decorator initialization metadata-only.
    loadPreviewText()
    return previewText.string.shortened(to: 10_000)
  }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem

  var multiSelectionIndex: Int? {
    guard selectionIndex >= 0, AppState.shared.navigator.isMultiSelectInProgress else {
      return nil
    }
    return selectionIndex
  }

  // Describe the complete item independently of its potentially truncated visual content.
  var accessibilityLabel: String {
    var parts: [String] = []
    if hasImage {
      if let imagePixelSize {
        parts.append(
          String(
            format: NSLocalizedString("history_item_image_accessibility_label_no_app", comment: ""),
            Int(imagePixelSize.width),
            Int(imagePixelSize.height)
          )
        )
      } else {
        parts.append(NSLocalizedString("history_item_image_accessibility_generic", comment: ""))
      }
    } else {
      parts.append(title)
    }
    if let application = application {
      parts.append(application)
    }
    if isPinned {
      parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
    }
    if let index = multiSelectionIndex {
      parts.append(
        String(
          format: NSLocalizedString("history_item_selected_accessibility_value", comment: ""),
          index + 1,
          AppState.shared.navigator.selection.count
        )
      )
    }
    return parts.joined(separator: ", ")
  }

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.id = item.identityVersion > 0 ? item.stableID : UUID()
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  func loadPreviewText() {
    synchronizeItemText()
  }

  @MainActor
  func ensureThumbnailImage() {
    guard hasImage else {
      return
    }
    guard thumbnailImage == nil else {
      return
    }
    guard thumbnailImageGenerationTask == nil else {
      return
    }
    let generationID = UUID()
    let targetSize = HistoryItemDecorator.thumbnailImageSize
    let scale = NSScreen.forPopup?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let cacheKey = item.thumbnailCacheKey + "-\(Int(targetSize.width * scale))x\(Int(targetSize.height * scale))"
    let reference = item.preferredImageContent.flatMap { content in
      content.payloadVerifiedAt == nil ? nil : content.payloadReference
    }
    // Legacy entries keep their inline bytes until migration. External entries
    // do not fault the BLOB merely to draw a row.
    let inlineData = reference == nil ? item.imageData : nil
    let knownOriginalSize = item.imagePixelWidth.flatMap { width in
      item.imagePixelHeight.map { height in NSSize(width: width, height: height) }
    }
    thumbnailGenerationID = generationID
    thumbnailImageGenerationTask = Task { [weak self] in
      let generated = await ThumbnailDecodeScheduler.shared.cachedOrGenerate(
        cacheKey: cacheKey,
        reference: reference,
        inlineData: inlineData,
        knownOriginalSize: knownOriginalSize,
        targetSize: targetSize,
        scale: scale
      )

      guard let self, self.thumbnailGenerationID == generationID else {
        return
      }
      defer {
        if self.thumbnailGenerationID == generationID {
          self.thumbnailGenerationID = nil
          self.thumbnailImageGenerationTask = nil
        }
      }
      guard !Task.isCancelled, let generated else {
        return
      }

      self.imagePixelSize = generated.originalPixelSize
      self.item.recordImagePixelSize(generated.originalPixelSize)
      self.thumbnailImage = NSImage(cgImage: generated.image, size: generated.displaySize)
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    guard hasImage, !Task.isCancelled else {
      return nil
    }

    // The list and popup can appear in the same event cycle. Resolve the
    // shared thumbnail task first so image dimensions are known and an extreme
    // source cannot be decoded concurrently by both schedulers.
    if item.imagePixelWidth == nil || item.imagePixelHeight == nil {
      ensureThumbnailImage()
      await thumbnailImageGenerationTask?.value
      guard !Task.isCancelled else { return nil }
    }

    if let width = item.imagePixelWidth,
       let height = item.imagePixelHeight,
       Self.shouldUseThumbnailPreview(width: width, height: height) {
      // ImageIO may fully inflate PNGs even when asked for a small thumbnail.
      // Reuse the derived disk thumbnail for images whose decoded bitmap would
      // exceed the preview cache budget, avoiding repeated multi-hundred-MiB
      // spikes for extreme long screenshots.
      if let thumbnailImage {
        previewImage = thumbnailImage
        return thumbnailImage
      }
      let targetSize = HistoryItemDecorator.thumbnailImageSize
      let scale = NSScreen.forPopup?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
      let cacheKey = item.thumbnailCacheKey + "-\(Int(targetSize.width * scale))x\(Int(targetSize.height * scale))"
      if let cached = ThumbnailStore.shared.image(for: cacheKey) {
        let image = NSImage(
          cgImage: cached,
          size: NSSize(width: CGFloat(cached.width) / scale, height: CGFloat(cached.height) / scale)
        )
        thumbnailImage = image
        previewImage = image
        return image
      }
      ensureThumbnailImage()
      await thumbnailImageGenerationTask?.value
      if let thumbnailImage {
        previewImage = thumbnailImage
        return thumbnailImage
      }
      return nil
    }

    // Universal Clipboard images may be represented by a JPEG file URL rather
    // than a direct image pasteboard type. Their thumbnail path reads that URL;
    // there is no direct content provider for a second full-preview decode.
    guard let content = item.preferredImageContent else {
      if let thumbnailImage {
        previewImage = thumbnailImage
        return thumbnailImage
      }
      ensureThumbnailImage()
      await thumbnailImageGenerationTask?.value
      guard let thumbnailImage else { return nil }
      previewImage = thumbnailImage
      return thumbnailImage
    }

    let reference = content.payloadVerifiedAt == nil ? nil : content.payloadReference
    // External-only rows must not fault a SwiftData BLOB. Legacy rows retain
    // the inline fallback until their bounded migration completes.
    let inlineData = reference == nil ? content.value : nil
    let scale = NSScreen.forPopup?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let previewSize = HistoryItemDecorator.previewImageSize
    let maximumPixelDimension = max(
      1,
      min(2_048, Int(ceil(max(previewSize.width, previewSize.height) * scale)))
    )
    guard let decoded = await PreviewDecodeScheduler.shared.decode(
      reference: reference,
      inlineData: inlineData,
      maximumPixelDimension: maximumPixelDimension
    ), !Task.isCancelled else {
      return nil
    }
    let image = NSImage(
      cgImage: decoded.image,
      size: NSSize(width: decoded.image.width, height: decoded.image.height)
    )

    imagePixelSize = decoded.originalPixelSize
    item.recordImagePixelSize(decoded.originalPixelSize)
    previewImage = image
    // Return the strong local reference. NSCache is only an optimization and
    // may evict its entry at any time, including immediately after insertion.
    return image
  }

  @MainActor
  func cleanupImages() {
    cancelThumbnailImageGeneration()
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
  }

  @MainActor
  func cancelThumbnailImageGeneration() {
    thumbnailGenerationID = nil
    thumbnailImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
  }

  @MainActor
  func sizeImages() {
    guard let image = item.image else {
      return
    }
    imagePixelSize = image.pixelSize
    item.recordImagePixelSize(image.pixelSize)
    previewImage = image
    thumbnailImage = image.resized(to: HistoryItemDecorator.thumbnailImageSize)
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        // History assigns numeric shortcuts when unpinning. Preserve them when
        // this observation callback runs after the history has been updated.
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }

  private func synchronizeItemText() {
    guard !hasImage else {
      previewText = SizedString("")
      return
    }
    previewText = withObservationTracking {
      SizedString(item.previewableText, maxParagraphBytes: Self.previewMaxParagraphSize)
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        self?.synchronizeItemText()
      }
    }
  }
}
