import AppKit
import Testing
import Defaults
@testable import Maccy

private final class BundleToken {}

private func textImage(_ text: String) -> NSImage {
  let string = NSAttributedString(string: text, attributes: [
    .font: NSFont.boldSystemFont(ofSize: 48),
    .foregroundColor: NSColor.black
  ])
  let size = NSSize(width: string.size().width + 40, height: string.size().height + 40)
  return NSImage(size: size, flipped: false) { rect in
    NSColor.white.setFill()
    rect.fill()
    string.draw(at: NSPoint(x: 20, y: 20))
    return true
  }
}

private let stringTitleCases: [(input: String, title: String)] = [
  ("foo", "foo"),
  ("   foo bar   ", "···foo bar···"),
  ("\nfoo\nbar\n", "⏎foo⏎bar⏎"),
  ("\tfoo\tbar\t", "⇥foo⇥bar⇥")
]

private let objectReplacementTitleCases: [(input: String, title: String)] = [
  ("\u{FFFC}foo\u{FFFC}bar\u{FFFC}", "foobar"),
  ("\u{FFFC}\u{FFFC}", "")
]

extension SharedStateTests {
  @MainActor
  struct HistoryItemTests {
    @Test("Sorted pins place letters before symbols")
    func sortedPinsPlacesLettersBeforeSymbols() {
      #expect(
        HistoryItem.sortedPins(["/", "c", "[", "b", "-", "\\", "y"]) ==
        ["b", "c", "y", "-", "/", "[", "\\"]
      )
    }

    @Test("Title for string", arguments: stringTitleCases)
    func titleForString(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    // U+FFFC arrives from rich text with inline attachments and hangs CoreText
    // on macOS 26. See https://github.com/p0deje/Maccy/issues/1520.
    @Test("Title without object replacement characters", arguments: objectReplacementTitleCases)
    func titleWithObjectReplacementCharacters(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    @Test("Title for RTF")
    func titleWithRTF() {
      let rtf = NSAttributedString(string: "foo").rtf(
        from: NSRange(0...2),
        documentAttributes: [:]
      )
      #expect(historyItem(rtf, .rtf).title == "foo")
    }

    @Test("Title for HTML")
    func titleWithHTML() {
      let html = "<a href='#'>foo</a>".data(using: .utf8)
      #expect(historyItem(html, .html).title == "foo")
    }

    @Test("Image has an empty title")
    func image() throws {
      let image = try #require(NSImage(named: "NSBluetoothTemplate"))
      #expect(historyItem(image).title == "")
    }

    @Test(
      "Spreadsheet bundles prefer text presentation while retaining their image",
      arguments: [
        "com.trolltech.anymime.WPS Spreadsheets 6.0 Format",
        "com.microsoft.excel.cells",
        "org.openxmlformats.spreadsheetml.sheet"
      ]
    )
    func spreadsheetBundlePrefersTextPresentation(privateType: String) {
      let text = "Room\tRate\nSingle\t100"
      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8)),
        HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: Data("png".utf8)),
        HistoryItemContent(type: privateType, value: Data())
      ])
      item.title = item.generateTitle()

      #expect(item.primaryContentKind == "text")
      #expect(item.hasImageRepresentation)
      #expect(item.hasPlainTextRepresentation)
      #expect(item.title == "Room⇥Rate⏎Single⇥100")
    }

    @Test("Generic text and image bundles remain image presentations")
    func genericTextAndImageBundleRemainsImagePresentation() {
      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("caption".utf8)),
        HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: Data("png".utf8))
      ])

      #expect(item.primaryContentKind == "image")
      #expect(item.generateTitle().isEmpty)
    }

    @Test("Duplicate comparison uses payload identity without reading an external file")
    func duplicateComparisonUsesPayloadIdentity() {
      let bytes = Data("external identity".utf8)
      let hash = PayloadStore.hash(bytes)
      let external = HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue)
      external.payloadHash = hash
      external.payloadByteCount = bytes.count
      external.payloadVerifiedAt = .now
      external.value = nil
      let existing = HistoryItem(contents: [external])
      let incoming = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: bytes)
      ])

      #expect(existing.supersedes(incoming.comparableContentIdentities()))
    }

    @Test("Image title becomes the recognized text")
    func imageTitleBecomesRecognizedText() async throws {
      let item = historyItem(textImage("Hello Maccy"))
      let deadline = ContinuousClock.now + .seconds(10)
      while item.title.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(item.title == "Hello Maccy")
    }

    @Test("Title for file", arguments: ["/tmp/foo.bar", "/tmp/产品培训/产品培训.txt"])
    func file(path: String) {
      let url = URL(fileURLWithPath: path)
      #expect(historyItem(url).title == "file://\(path)")
    }

    @Test("Text from Universal Clipboard")
    func textFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let textContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: url.lastPathComponent.data(using: .utf8)
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, textContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "foo.bar")
    }

    @Test("Image from Universal Clipboard")
    func imageFromUniversalClipboard() throws {
      let url = try #require(Bundle(for: BundleToken.self).url(forResource: "guy", withExtension: "jpeg"))
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      let image = try #require(item.image)
      let expected = try #require(NSImage(data: try Data(contentsOf: url)))
      #expect(image.tiffRepresentation == expected.tiffRepresentation)
    }

    @Test("File from Universal Clipboard")
    func fileFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "file:///tmp/foo.bar")
    }

    @Test("Item without data has an empty title")
    func itemWithoutData() {
      #expect(historyItem(nil).title == "")
    }

    @Test("Several items can have an empty pin")
    func severalItemsCanHaveEmptyPin() {
      let item1 = historyItem("foo")
      item1.pin = ""
      let item2 = historyItem("bar")
      item2.pin = ""
      #expect(throws: Never.self) {
        try Storage.shared.context.save()
      }
      #expect(item1.pin == "")
      #expect(item2.pin == "")
    }

    @Test("External payload dual-read and rollback")
    func externalPayloadDualReadAndRollback() throws {
      try withPayloadStore { store in
        let original = Data("external clipboard representation".utf8)
        let content = HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: original)

        let optionalReference = try content.externalize(retainingInlineValue: false, store: store)
        let reference = try #require(optionalReference)
        #expect(content.value == nil)
        #expect(content.isExternallyStored)
        #expect(content.resolvedValue(from: store) == original)
        #expect(content.byteCount == original.count)

        try content.restoreInlineValue(store: store)
        #expect(content.value == original)

        try Data("corrupt".utf8).write(to: store.payloadURL(for: reference.hash))
        #expect(content.resolvedValue(from: store) == original)
      }
    }

    @Test("Inline payload byte metadata survives default-off storage and editing")
    func inlinePayloadByteMetadata() {
      let original = Data("original".utf8)
      let replacement = Data("replacement value".utf8)
      let content = HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: original)

      #expect(content.payloadHash == nil)
      #expect(content.payloadByteCount == original.count)
      #expect(content.byteCount == original.count)

      content.replaceInlineValue(replacement)

      #expect(content.payloadHash == nil)
      #expect(content.payloadByteCount == replacement.count)
      #expect(content.byteCount == replacement.count)
      #expect(content.resolvedValue == replacement)
    }

    @Test("Verified external payload permits inline cleanup")
    func verifiedExternalPayloadPermitsInlineCleanup() throws {
      try withPayloadStore { store in
        let original = Data("migration fallback".utf8)
        let content = HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: original)

        _ = try content.externalize(retainingInlineValue: true, store: store)
        #expect(content.value == original)
        try content.removeInlineValueIfVerified(store: store)

        #expect(content.value == nil)
        #expect(content.resolvedValue(from: store) == original)
      }
    }

    private func historyItem(_ value: String?) -> HistoryItem {
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

      return item
    }

    private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: type.rawValue,
          value: data
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: NSImage) -> HistoryItem {
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

      return item
    }

    private func historyItem(_ value: URL) -> HistoryItem {
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

      return item
    }

    private func withPayloadStore(_ body: (PayloadStore) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory
        .appending(path: "MaccyHistoryItemPayloadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try body(PayloadStore(baseURL: root))
    }
  }
}
