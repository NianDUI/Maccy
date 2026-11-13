import AppKit.NSWorkspace
import Defaults
import Foundation
import ImageIO
import Observation
import Sauce

private final class HistoryImageCache: @unchecked Sendable {
  static let shared = HistoryImageCache()

  private let thumbnails = NSCache<NSString, NSImage>()
  private let previews = NSCache<NSString, NSImage>()
  private let memoryPressureSource: DispatchSourceMemoryPressure

  private init() {
    thumbnails.countLimit = 50
    thumbnails.totalCostLimit = 32 * 1_024 * 1_024
    // Only one preview is visible at a time. Keep the original-resolution image
    // so Retina displays never enlarge an already-downsampled intermediate.
    previews.countLimit = 1
    previews.totalCostLimit = 96 * 1_024 * 1_024

    memoryPressureSource = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: .main
    )
    memoryPressureSource.setEventHandler { [weak self] in
      self?.removeAllPreviews()
      self?.removeAllThumbnails()
    }
    memoryPressureSource.resume()
  }

  func thumbnail(for id: UUID) -> NSImage? {
    thumbnails.object(forKey: id.uuidString as NSString)
  }

  func setThumbnail(_ image: NSImage?, for id: UUID) {
    set(image, in: thumbnails, for: id)
  }

  func preview(for id: UUID) -> NSImage? {
    previews.object(forKey: id.uuidString as NSString)
  }

  func setPreview(_ image: NSImage?, for id: UUID) {
    set(image, in: previews, for: id)
  }

  func removeAllThumbnails() {
    thumbnails.removeAllObjects()
  }

  func removeAllPreviews() {
    previews.removeAllObjects()
  }

  private func set(_ image: NSImage?, in cache: NSCache<NSString, NSImage>, for id: UUID) {
    let key = id.uuidString as NSString
    guard let image else {
      cache.removeObject(forKey: key)
      return
    }

    let pixels = image.pixelSize
    let cost = max(1, Int(pixels.width * pixels.height * 4))
    cache.setObject(image, forKey: key, cost: cost)
  }
}

private struct GeneratedThumbnail: @unchecked Sendable {
  let image: CGImage
  let originalPixelSize: NSSize
  let displaySize: NSSize
}

/// Serializes ImageIO work so opening a list of large images cannot create
/// multiple full-decoding memory spikes at the same time.
private actor ThumbnailDecodeScheduler {
  static let shared = ThumbnailDecodeScheduler()

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
}

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  private static let previewMaxParagraphSize = 10_000

  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

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

  var hasImage: Bool { item.hasImageRepresentation }
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
  private(set) lazy var imageSize: String? = item.imageData.map {
    ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file)
  }

  // 10k characters seems to be more than enough on large displays
  var text: String {
    (hasImage ? item.title : previewText.string).shortened(to: 10_000)
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
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
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
    guard let data = item.imageData else {
      return
    }

    let generationID = UUID()
    let targetSize = HistoryItemDecorator.thumbnailImageSize
    let scale = NSScreen.forPopup?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    thumbnailGenerationID = generationID
    thumbnailImageGenerationTask = Task { [weak self] in
      let generated = await ThumbnailDecodeScheduler.shared.generate(
        data: data,
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
      self.thumbnailImage = NSImage(cgImage: generated.image, size: generated.displaySize)
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    guard hasImage, !Task.isCancelled, let image = item.image, !Task.isCancelled else {
      return nil
    }

    imagePixelSize = image.pixelSize
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
