import AppKit
import Darwin.Mach
import Testing
import Defaults
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class HistoryItemDecoratorTests {
    let savedHighlightMatch = Defaults[.highlightMatch]
    let savedImageMaxHeight = Defaults[.imageMaxHeight]

    var firstCopiedAt: Date! {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
      return formatter.date(from: "2020/07/10 12:31:34")
    }

    var lastCopiedAt: Date! {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
      return formatter.date(from: "2020/07/10 12:41:34")
    }

    init() {
      Defaults[.highlightMatch] = .bold
      Defaults[.imageMaxHeight] = 40
    }

    deinit {
      Defaults[.imageMaxHeight] = savedImageMaxHeight
      Defaults[.highlightMatch] = savedHighlightMatch
    }

    @Test("String")
    func string() {
      let title = "foo"
      let itemDecorator = historyItemDecorator(title)
      #expect(itemDecorator.title == title)
      #expect(itemDecorator.previewText.string.isEmpty)
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Text payload is loaded only when preview is requested")
    func textPayloadLoadsOnDemand() {
      let itemDecorator = historyItemDecorator("full preview payload")

      #expect(itemDecorator.previewText.string.isEmpty)

      itemDecorator.loadPreviewText()

      #expect(itemDecorator.previewText.string == "full preview payload")
      #expect(itemDecorator.text == "full preview payload")
    }

    @Test("RTF")
    func rtf() {
      let rtf = NSAttributedString(string: "foo").rtf(
        from: NSRange(0...2),
        documentAttributes: [:]
      )
      let itemDecorator = historyItemDecorator(rtf, .rtf)
      #expect(itemDecorator.title == "foo")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("HTML")
    func html() {
      let html = "<a href='#'>foo</a>".data(using: .utf8)
      let itemDecorator = historyItemDecorator(html, .html)
      #expect(itemDecorator.title == "foo")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Image")
    func image() throws {
      let image = try #require(NSImage(named: "StatusBarMenuImage"))
      let itemDecorator = historyItemDecorator(image)
      itemDecorator.sizeImages()
      let previewImage = try #require(itemDecorator.previewImage)
      #expect(itemDecorator.title == "")
      #expect(previewImage.size == image.size)
      #expect(previewImage.pixelSize == itemDecorator.item.image?.pixelSize)
      #expect(try #require(itemDecorator.thumbnailImage).size == image.size)
    }

    // We also need to add test for image with width bigger than max width.
    @Test("Image with height bigger than max height")
    func imageWithHeightBiggerThanMaxHeight() async throws {
      let image = try #require(NSImage(named: "NSApplicationIcon"))
      let itemDecorator = historyItemDecorator(image)
      itemDecorator.ensureThumbnailImage()
      await itemDecorator.thumbnailImageGenerationTask?.value
      let thumbnailImage = try #require(itemDecorator.thumbnailImage)
      #expect(thumbnailImage.size == NSSize(width: 40, height: 40))
      #expect(thumbnailImage.pixelSize.width >= thumbnailImage.size.width)
      #expect(thumbnailImage.pixelSize.height >= thumbnailImage.size.height)
    }

    @Test("Image detection uses the pasteboard type without decoding")
    func imageDetectionUsesPasteboardType() {
      let itemDecorator = historyItemDecorator(Data("not an image".utf8), .png)
      #expect(itemDecorator.hasImage)
      #expect(itemDecorator.item.image == nil)
      #expect(itemDecorator.previewText.string.isEmpty)
    }

    @Test("Spreadsheet image representation uses text preview without decoding")
    func spreadsheetImageRepresentationUsesTextPreview() {
      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("A\tB".utf8)),
        HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: Data("large png".utf8)),
        HistoryItemContent(type: "com.trolltech.anymime.XML Spreadsheet", value: Data())
      ])
      item.title = item.generateTitle()
      let itemDecorator = HistoryItemDecorator(item)

      #expect(!itemDecorator.hasImage)
      #expect(item.hasImageRepresentation)
      itemDecorator.loadPreviewText()
      #expect(itemDecorator.previewText.string == "A\tB")
      #expect(itemDecorator.thumbnailImage == nil)
      #expect(itemDecorator.previewImage == nil)
    }

    @Test("Image menu bar text uses the OCR title")
    func imageMenuBarTextUsesTitle() throws {
      let image = try #require(NSImage(named: "StatusBarMenuImage"))
      let itemDecorator = historyItemDecorator(image)
      itemDecorator.item.title = "recognized text"

      #expect(itemDecorator.text == "recognized text")
      #expect(itemDecorator.previewText.string.isEmpty)
    }

    @Test("Image caches are cleared with the decorator")
    func imageCachesAreCleared() throws {
      let image = try #require(NSImage(named: "StatusBarMenuImage"))
      let itemDecorator = historyItemDecorator(image)
      itemDecorator.sizeImages()
      #expect(itemDecorator.previewImage != nil)
      #expect(itemDecorator.thumbnailImage != nil)

      itemDecorator.cleanupImages()

      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Preview generation returns the image independently of cache retention")
    func previewGenerationReturnsImage() async throws {
      let image = try #require(NSImage(named: "StatusBarMenuImage"))
      let itemDecorator = historyItemDecorator(image)

      let previewImage = try #require(await itemDecorator.asyncGetPreviewImage())

      let legacyPixelSize = try #require(itemDecorator.item.image?.pixelSize)
      #expect(previewImage.pixelSize.width >= legacyPixelSize.width)
      #expect(previewImage.pixelSize.height >= legacyPixelSize.height)
    }

    @Test("Universal Clipboard JPEG file URL produces a preview")
    func universalClipboardJPEGProducesPreview() async throws {
      let image = try #require(NSImage(named: "NSInfo"))
      let tiff = try #require(image.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: tiff))
      let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
      let url = FileManager.default.temporaryDirectory
        .appending(path: "MaccyUniversalPreview-\(UUID().uuidString).jpeg")
      try jpeg.write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }

      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: url.dataRepresentation),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
          value: Data()
        )
      ])
      let decorator = HistoryItemDecorator(item)

      let preview = try #require(await decorator.asyncGetPreviewImage())
      #expect(preview.pixelSize.width > 0)
      #expect(preview.pixelSize.height > 0)
      #expect(item.imagePixelWidth != nil)
      #expect(item.imagePixelHeight != nil)
    }

    @Test("File", arguments: ["/tmp/foo.bar", "/tmp/产品培训/产品培训.txt"])
    func file(path: String) {
      let url = URL(fileURLWithPath: path)
      let itemDecorator = historyItemDecorator(url)
      #expect(itemDecorator.title == "file://\(path)")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Item without data")
    func itemWithoutData() {
      let itemDecorator = historyItemDecorator(nil)
      #expect(itemDecorator.title == "")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Unpinned by default")
    func unpinnedByDefault() {
      let itemDecorator = historyItemDecorator("foo")
      #expect(itemDecorator.item.pin == nil)
      #expect(!itemDecorator.isPinned)
    }

    @Test("Deallocates when no longer referenced")
    func deallocatesWhenNoLongerReferenced() {
      weak var weakDecorator: HistoryItemDecorator?

      autoreleasepool {
        let itemDecorator = historyItemDecorator("foo")
        weakDecorator = itemDecorator
        #expect(weakDecorator != nil)
      }

      #expect(weakDecorator == nil)
    }

    @Test("Highlight")
    func highlight() throws {
      let itemDecorator = historyItemDecorator("foo bar baz")
      itemDecorator.highlight("random", [
        range(from: 1, to: 2, in: itemDecorator),
        range(from: 8, to: 10, in: itemDecorator)
      ])
      var expectedTitle = AttributedString("foo bar baz")
      expectedTitle[try #require(expectedTitle.range(of: "oo"))].font = .bold(.body)()
      expectedTitle[try #require(expectedTitle.range(of: "baz"))].font = .bold(.body)()
      #expect(itemDecorator.attributedTitle == expectedTitle)
      itemDecorator.highlight("", [])
      #expect(itemDecorator.attributedTitle == nil)
    }

    private func historyItemDecorator(
      _ value: String?,
      application: String? = "com.apple.finder"
    ) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value?.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = application
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(
      _ value: Data?,
      _ type: NSPasteboard.PasteboardType
    ) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: type.rawValue,
          value: value
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(_ value: NSImage) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.tiff.rawValue,
          value: value.tiffRepresentation
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(_ value: URL) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fileURL.rawValue,
          value: value.dataRepresentation
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.lastPathComponent.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    // swiftlint:disable:next identifier_name
    private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
      let startIndex = item.title.startIndex
      let lowerBound = item.title.index(startIndex, offsetBy: from)
      let upperBound = item.title.index(startIndex, offsetBy: to + 1)

      return lowerBound..<upperBound
    }
  }
}

@MainActor
@Suite(.serialized)
struct ImageMemoryStressTests {
  @Test("Derived thumbnail is reused without rereading original bytes")
  func derivedThumbnailDiskCache() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "MaccyThumbnailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = ThumbnailStore(baseURL: root)
    defer {
      store.removeAll()
    }
    let data = try makeImageData(width: 1_024, height: 1_024)
    let scheduler = ThumbnailDecodeScheduler()
    let first = try #require(await scheduler.cachedOrGenerate(
      cacheKey: "abc-100x100",
      reference: nil,
      inlineData: data,
      knownOriginalSize: nil,
      targetSize: NSSize(width: 100, height: 100),
      scale: 1,
      thumbnailStore: store
    ))
    let second = try #require(await scheduler.cachedOrGenerate(
      cacheKey: "abc-100x100",
      reference: nil,
      inlineData: nil,
      knownOriginalSize: first.originalPixelSize,
      targetSize: NSSize(width: 100, height: 100),
      scale: 1,
      thumbnailStore: store
    ))

    #expect(first.image.width == second.image.width)
    #expect(first.image.height == second.image.height)
    #expect(first.originalPixelSize == NSSize(width: 1_024, height: 1_024))
  }

  @Test("Disk thumbnail cache never replaces missing original dimensions with thumbnail dimensions")
  func diskThumbnailCacheRecoversOriginalDimensions() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "MaccyThumbnailDimensionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = ThumbnailStore(baseURL: root)
    defer {
      store.removeAll()
    }
    let data = try makeImageData(width: 100, height: 10_000)
    let scheduler = ThumbnailDecodeScheduler()
    let first = try #require(await scheduler.cachedOrGenerate(
      cacheKey: "long-100x100",
      reference: nil,
      inlineData: data,
      knownOriginalSize: nil,
      targetSize: NSSize(width: 100, height: 100),
      scale: 1,
      thumbnailStore: store
    ))
    let cached = try #require(await scheduler.cachedOrGenerate(
      cacheKey: "long-100x100",
      reference: nil,
      inlineData: data,
      knownOriginalSize: nil,
      targetSize: NSSize(width: 100, height: 100),
      scale: 1,
      thumbnailStore: store
    ))

    #expect(first.originalPixelSize == NSSize(width: 100, height: 10_000))
    #expect(cached.originalPixelSize == first.originalPixelSize)
    #expect(cached.originalPixelSize != NSSize(width: cached.image.width, height: cached.image.height))
  }

  @Test("200 image entries keep thumbnail and preview memory bounded")
  func twoHundredImages() async throws {
    let imageData = try makeImageData(width: 1_024, height: 1_024)
    let baseline = physicalFootprint()
    var peak = baseline
    var decorators = (0..<200).map { index in
      let item = HistoryItem(contents: [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.png.rawValue,
          value: imageData,
          itemIndex: 0,
          representationIndex: index
        )
      ])
      return HistoryItemDecorator(item)
    }

    // Simulate scrolling through every row. The production scheduler performs
    // one ImageIO decode at a time and NSCache retains at most 50 thumbnails.
    for decorator in decorators {
      decorator.ensureThumbnailImage()
      await decorator.thumbnailImageGenerationTask?.value
      peak = max(peak, physicalFootprint())
    }

    // Exercise repeated source-resolution previews while releasing each active
    // image before moving to the next item.
    for decorator in decorators.prefix(20) {
      let preview = try #require(await decorator.asyncGetPreviewImage())
      _ = preview.tiffRepresentation
      decorator.previewImage = nil
      peak = max(peak, physicalFootprint())
    }

    for decorator in decorators {
      decorator.cleanupImages()
    }
    decorators.removeAll()
    try await Task.sleep(for: .milliseconds(500))
    let final = physicalFootprint()

    let mebibyte = UInt64(1_024 * 1_024)
    print(
      "MACCY_IMAGE_STRESS baseline=\(baseline / mebibyte)MiB " +
      "peak=\(peak / mebibyte)MiB final=\(final / mebibyte)MiB"
    )
    #expect(peak <= baseline + 384 * mebibyte)
    #expect(final <= baseline + 192 * mebibyte)
  }

  @Test("Oversized long preview is downsampled during decoding")
  func oversizedLongPreviewIsDownsampled() async throws {
    let data = try makeImageData(width: 100, height: 10_000)
    let decoded = try #require(await PreviewDecodeScheduler().decode(
      reference: nil,
      inlineData: data,
      maximumPixelDimension: 512
    ))

    #expect(max(decoded.image.width, decoded.image.height) <= 512)
    #expect(decoded.image.height > decoded.image.width)
    #expect(decoded.originalPixelSize == NSSize(width: 100, height: 10_000))
  }

  @Test("Decoded bitmap budget routes extreme images to their derived thumbnail")
  func oversizedPreviewUsesDerivedThumbnail() {
    #expect(HistoryItemDecorator.shouldUseThumbnailPreview(width: 2_468, height: 77_474))
    #expect(!HistoryItemDecorator.shouldUseThumbnailPreview(width: 1_990, height: 1_710))
  }

  @Test("1050 image replacements reach a memory plateau with a 200 item history limit")
  func imageReplacementPlateau() async throws {
    let imageData = try makeImageData(width: 1_024, height: 1_024)
    let baseline = physicalFootprint()
    var decorators: [HistoryItemDecorator] = []
    var midpoint = baseline

    for index in 0..<1_050 {
      let item = HistoryItem(contents: [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.png.rawValue,
          value: imageData,
          itemIndex: 0,
          representationIndex: 0
        )
      ])
      let decorator = HistoryItemDecorator(item)
      decorators.append(decorator)
      decorator.ensureThumbnailImage()
      await decorator.thumbnailImageGenerationTask?.value

      // Exercise the expensive source-resolution path throughout the run,
      // while matching the UI contract that only the active preview is held.
      if index.isMultiple(of: 50) {
        _ = try #require(await decorator.asyncGetPreviewImage())
        decorator.previewImage = nil
      }

      if decorators.count > 200 {
        decorators.removeFirst().cleanupImages()
      }
      if index == 524 {
        midpoint = physicalFootprint()
      }
    }

    let endpoint = physicalFootprint()
    decorators.forEach { $0.cleanupImages() }
    decorators.removeAll()
    try await Task.sleep(for: .milliseconds(500))
    let final = physicalFootprint()

    let mebibyte = UInt64(1_024 * 1_024)
    print(
      "MACCY_IMAGE_REPLACEMENT baseline=\(baseline / mebibyte)MiB " +
      "midpoint=\(midpoint / mebibyte)MiB endpoint=\(endpoint / mebibyte)MiB " +
      "final=\(final / mebibyte)MiB"
    )
    // The second 525 replacements must not add another history-sized memory
    // tranche. Allow allocator/cache noise while rejecting linear growth.
    #expect(endpoint <= midpoint + 128 * mebibyte)
    #expect(final <= baseline + 192 * mebibyte)
  }

  private func makeImageData(width: Int, height: Int) throws -> Data {
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
      NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.75, alpha: 1).setFill()
      rect.fill()
      return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
