import AppKit
import Testing
import Defaults
@testable import Maccy

extension SharedStateTests {
  // swiftlint:disable type_body_length
  @MainActor
  final class ClipboardTests {
    let clipboard = Clipboard.shared
    let pasteboard = NSPasteboard.general
    let image: NSImage
    let coloredString = NSAttributedString(string: "foo",
                                           attributes: [.foregroundColor: NSColor.red])

    let dynamicType = NSPasteboard.PasteboardType(rawValue: "dyn.ah62d4qmxhk4d425try1g44pdsm11g55gsu1e82xnqzv")
    let customType = NSPasteboard.PasteboardType(rawValue: "org.maccy.ConfidentialType")
    let fileURLType = NSPasteboard.PasteboardType.fileURL
    let htmlType = NSPasteboard.PasteboardType.html
    let rtfType = NSPasteboard.PasteboardType.rtf
    let stringType = NSPasteboard.PasteboardType.string
    let tiffType = NSPasteboard.PasteboardType.tiff
    let transientType = NSPasteboard.PasteboardType.transient
    let unknownType = NSPasteboard.PasteboardType(rawValue: "com.apple.AnnotationKit.AnnotationItem")

    let savedEnabledTypes = Defaults[.enabledPasteboardTypes]
    let savedIgnoreEvents = Defaults[.ignoreEvents]
    let savedIgnoreAllAppsExceptListed = Defaults[.ignoreAllAppsExceptListed]
    let savedIgnoredApps = Defaults[.ignoredApps]
    let savedIgnoredPasteboardTypes = Defaults[.ignoredPasteboardTypes]
    let savedExternalPayloadStorageEnabled = Defaults[.externalPayloadStorageEnabled]
    let savedManifestReplayEnabled = Defaults[.manifestReplayEnabled]
    let savedVerifiedInlinePayloadCleanupEnabled = Defaults[.verifiedInlinePayloadCleanupEnabled]

    init() throws {
      image = try #require(NSImage(named: "NSInfo"))
      Defaults[.ignoreAllAppsExceptListed] = false
      Defaults[.ignoreEvents] = false
      Defaults[.externalPayloadStorageEnabled] = false
      Defaults[.manifestReplayEnabled] = false
      Defaults[.verifiedInlinePayloadCleanupEnabled] = false
      clipboard.clearHooks()
    }

    deinit {
      Defaults[.enabledPasteboardTypes] = savedEnabledTypes
      Defaults[.ignoreEvents] = savedIgnoreEvents
      Defaults[.ignoreOnlyNextEvent] = false
      Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllAppsExceptListed
      Defaults[.ignoredApps] = savedIgnoredApps
      Defaults[.ignoredPasteboardTypes] = savedIgnoredPasteboardTypes
      Defaults[.externalPayloadStorageEnabled] = savedExternalPayloadStorageEnabled
      Defaults[.manifestReplayEnabled] = savedManifestReplayEnabled
      Defaults[.verifiedInlinePayloadCleanupEnabled] = savedVerifiedInlinePayloadCleanupEnabled
    }

    @Test("Changes listener and add hooks")
    func changesListenerAndAddHooks() async throws {
      let copies = try await waitForCopies(after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.count == 1)
    }

    @Test("Ignore string with only spaces")
    func ignoreStringWithOnlySpaces() async throws {
      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(" ", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore string with only newlines")
    func ignoreStringWithOnlyNewlines() async throws {
      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("\n", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Does not ignore RTF")
    func doesNotIgnoreRTF() async throws {
      let copies = try await waitForCopies(after: {
        let rtf = NSAttributedString(string: "foo").rtf(
          from: NSRange(0...2),
          documentAttributes: [:]
        )
        pasteboard.declareTypes([.rtf], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
      })
      #expect(copies.count == 1)
    }

    @Test("Does not ignore HTML")
    func doesNotIgnoreHTML() async throws {
      let copies = try await waitForCopies(after: {
        pasteboard.declareTypes([.html], owner: nil)
        pasteboard.setString("foo", forType: .html)
      })
      #expect(copies.count == 1)
    }

    @Test("Ignore events is enabled")
    func ignoreEventsIsEnabled() async throws {
      Defaults[.ignoreEvents] = true

      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("foo", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore only next event is enabled")
    func ignoreOnlyNextEventIsEnabled() async throws {
      Defaults[.ignoreEvents] = true
      Defaults[.ignoreOnlyNextEvent] = true

      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("foo", forType: .string)
      })
      #expect(copies.isEmpty)

      #expect(!Defaults[.ignoreEvents])
      #expect(!Defaults[.ignoreOnlyNextEvent])
    }

    @Test("Ignore application")
    func ignoreApplication() async throws {
      Defaults[.ignoredApps] = [try frontmostAppBundleIdentifier()]

      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore all applications except")
    func ignoreAllApplicationsExcept() async throws {
      Defaults[.ignoreAllAppsExceptListed] = true
      Defaults[.ignoredApps] = [try frontmostAppBundleIdentifier()]

      let copies = try await waitForCopies(after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.count == 1)
    }

    @Test("Ignore transient types")
    func ignoreTransientTypes() async throws {
      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string, transientType], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore custom types")
    func ignoreCustomTypes() async throws {
      Defaults[.ignoredPasteboardTypes] = [customType.rawValue]

      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string, customType], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore copies with unknown types")
    func ignoreCopiesWithUnknownTypes() async throws {
      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([unknownType], owner: nil)
        pasteboard.setString(" ", forType: unknownType)
      })
      #expect(copies.isEmpty)
    }

    @Test("Copy")
    func copy() {
      let imageData = image.tiffRepresentation!
      let contents = [
        HistoryItemContent(type: stringType.rawValue, value: "foo".data(using: .utf8)!),
        HistoryItemContent(type: tiffType.rawValue, value: imageData),
        HistoryItemContent(type: fileURLType.rawValue, value: "file://foo.bar".data(using: .utf8)!)
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.application = "com.foo.bar"
      clipboard.copy(item)
      #expect(pasteboard.string(forType: .string) == "foo")
      #expect(pasteboard.data(forType: .tiff) == imageData)
      #expect(pasteboard.string(forType: .fileURL) == "file://foo.bar")
      #expect(pasteboard.string(forType: .fromMaccy) == "")
      #expect(pasteboard.string(forType: .source) == "com.foo.bar")
    }

    @Test("Copy string")
    func copyString() {
      clipboard.copyInMaccy("foo")
      #expect(pasteboard.string(forType: .string) == "foo")
      #expect(pasteboard.string(forType: .source) == NSPasteboard.PasteboardType.fromMaccy.rawValue)
    }

    @Test("Copy without formatting")
    func copyWithoutFormatting() {
      let contents = [
        HistoryItemContent(type: stringType.rawValue, value: "foo".data(using: .utf8)!),
        HistoryItemContent(type: fileURLType.rawValue, value: "file://foo.bar".data(using: .utf8)!),
        HistoryItemContent(type: rtfType.rawValue,
                           value: coloredString.rtf(from: NSRange(location: 0, length: coloredString.length),
                                                    documentAttributes: [:]))
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.application = "com.foo.bar"
      clipboard.copy(item, removeFormatting: true)
      #expect(pasteboard.string(forType: .string) == "foo")
      #expect(pasteboard.string(forType: .fromMaccy) == "")
      #expect(pasteboard.string(forType: .source) == "com.foo.bar")
      #expect(pasteboard.string(forType: .fileURL) == "file://foo.bar")
      #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test("Manifest replay preserves item boundaries, type order, and bytes")
    func manifestReplayPreservesStructure() throws {
      Defaults[.manifestReplayEnabled] = true
      let stringData = Data("first item".utf8)
      let htmlData = Data("<b>first item</b>".utf8)
      let imageData = try #require(image.tiffRepresentation)
      let contents = [
        HistoryItemContent(type: stringType.rawValue, value: stringData, itemIndex: 0, representationIndex: 0),
        HistoryItemContent(type: htmlType.rawValue, value: htmlData, itemIndex: 0, representationIndex: 1),
        HistoryItemContent(type: tiffType.rawValue, value: imageData, itemIndex: 1, representationIndex: 0)
      ]
      let item = HistoryItem(contents: contents)
      Storage.shared.context.insert(item)
      item.application = "com.foo.bar"

      clipboard.copy(item)

      let replayedItems = try #require(pasteboard.pasteboardItems)
      #expect(replayedItems.count == 2)
      #expect(replayedItems[0].types.starts(with: [stringType, htmlType]))
      #expect(replayedItems[0].data(forType: stringType) == stringData)
      #expect(replayedItems[0].data(forType: htmlType) == htmlData)
      #expect(replayedItems[1].types == [tiffType])
      #expect(replayedItems[1].data(forType: tiffType) == imageData)
    }

    @Test("Manifest replay preserves standard and private representations byte-for-byte")
    func manifestReplayPreservesVerbatimRepresentations() throws {
      Defaults[.manifestReplayEnabled] = true
      let tiff = try #require(image.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: tiff))
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
      let utf16 = try #require("剪贴板 UTF-16".data(using: .utf16))
      let html = Data("<p><b>formatted</b></p>".utf8)
      let rtf = try #require(coloredString.rtf(
        from: NSRange(location: 0, length: coloredString.length),
        documentAttributes: [:]
      ))
      let privateType = NSPasteboard.PasteboardType("com.example.private-verbatim")
      let privateBytes = Data([0x00, 0xff, 0x10, 0x80, 0x42])
      let representations: [(NSPasteboard.PasteboardType, Data)] = [
        (NSPasteboard.PasteboardType("public.utf16-plain-text"), utf16),
        (.html, html),
        (.rtf, rtf),
        (.png, png),
        (.jpeg, jpeg),
        (privateType, privateBytes)
      ]
      let item = HistoryItem(contents: representations.enumerated().map { index, representation in
        HistoryItemContent(
          type: representation.0.rawValue,
          value: representation.1,
          itemIndex: 0,
          representationIndex: index
        )
      })

      clipboard.copy(item)

      let replayed = try #require(pasteboard.pasteboardItems?.first)
      let replayedOriginalTypes = replayed.types.filter { representations.map(\.0).contains($0) }
      #expect(replayedOriginalTypes == representations.map(\.0))
      for (type, bytes) in representations {
        #expect(replayed.data(forType: type) == bytes)
      }
    }

    @Test("Manifest replay lazily reads external payloads without inline bytes")
    func manifestReplayReadsExternalPayload() throws {
      let root = FileManager.default.temporaryDirectory
        .appending(path: "MaccyClipboardPayloadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      Defaults[.manifestReplayEnabled] = true
      let store = PayloadStore(baseURL: root)
      let bytes = Data("external exact bytes \(UUID().uuidString)".utf8)
      let content = HistoryItemContent(
        type: customType.rawValue,
        value: bytes,
        itemIndex: 0,
        representationIndex: 0
      )
      _ = try content.externalize(retainingInlineValue: false, store: store)
      #expect(content.value == nil)

      let isolatedClipboard = Clipboard(payloadStore: store)
      isolatedClipboard.copy(HistoryItem(contents: [content]))

      let replayed = try #require(pasteboard.pasteboardItems?.first)
      #expect(replayed.data(forType: customType) == bytes)
    }

    @Test("Manifest replay falls back to retained inline bytes when the external payload is missing")
    func manifestReplayFallsBackToInlinePayload() throws {
      let root = FileManager.default.temporaryDirectory
        .appending(path: "MaccyClipboardFallbackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      Defaults[.manifestReplayEnabled] = true
      let store = PayloadStore(baseURL: root)
      let bytes = Data("retained compatibility fallback".utf8)
      let content = HistoryItemContent(type: customType.rawValue, value: bytes)
      let optionalReference = try content.externalize(retainingInlineValue: true, store: store)
      let reference = try #require(optionalReference)
      let isolatedClipboard = Clipboard(payloadStore: store)
      isolatedClipboard.copy(HistoryItem(contents: [content]))

      try FileManager.default.removeItem(at: store.payloadURL(for: reference.hash))
      let replayed = try #require(pasteboard.pasteboardItems?.first)
      #expect(replayed.data(forType: customType) == bytes)
    }

    @Test("Asynchronous externalization keeps each representation paired with its bytes")
    func asynchronousExternalizationKeepsRepresentationIdentity() async throws {
      let root = FileManager.default.temporaryDirectory
        .appending(path: "MaccyClipboardExternalizationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      Defaults[.externalPayloadStorageEnabled] = true
      let store = PayloadStore(baseURL: root)
      let isolatedClipboard = Clipboard(payloadStore: store)
      let firstType = NSPasteboard.PasteboardType("com.example.external.first")
      let secondType = NSPasteboard.PasteboardType("com.example.external.second")
      let firstBytes = Data("first representation".utf8)
      let secondBytes = Data("second representation with different bytes".utf8)
      let item = HistoryItem(contents: [
        HistoryItemContent(type: firstType.rawValue, value: firstBytes),
        HistoryItemContent(type: secondType.rawValue, value: secondBytes)
      ])
      isolatedClipboard.scheduleExternalization(for: item)

      let deadline = ContinuousClock.now + .seconds(3)
      while item.contents.contains(where: { !$0.isExternallyStored }) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }

      let first = try #require(item.contents.first(where: { $0.type == firstType.rawValue }))
      let second = try #require(item.contents.first(where: { $0.type == secondType.rawValue }))
      #expect(first.resolvedValue(from: store) == firstBytes)
      #expect(second.resolvedValue(from: store) == secondBytes)
      #expect(first.payloadHash == PayloadStore.hash(firstBytes))
      #expect(second.payloadHash == PayloadStore.hash(secondBytes))
    }

    @Test("Handles items without data")
    func handlesItemsWithoutData() async throws {
      pasteboard.clearContents()

      let copies = try await waitForCopies(after: {
        pasteboard.declareTypes([.fileURL, .string], owner: nil)
        // fileURL is left without data
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.count == 1)
    }

    @Test("Merges multiple items")
    func mergesMultipleItems() async throws {
      let item1 = NSPasteboardItem()
      item1.setString("foo", forType: .string)
      let item2 = NSPasteboardItem()
      item2.setData(image.tiffRepresentation!, forType: .tiff)

      let copies = try await waitForCopies(after: {
        pasteboard.clearContents()
        pasteboard.writeObjects([item1, item2])
      })
      let copied = try #require(copies.first)
      #expect(copies.count == 1)
      #expect(
        Set(copied.contents.map({ $0.type })) ==
        Set([tiffType.rawValue, stringType.rawValue])
      )
      #expect(Set(copied.contents.map(\.itemIndex)) == [0, 1])
    }

    @Test("Removes disabled types")
    func removesDisabledTypes() async throws {
      Defaults[.enabledPasteboardTypes] = [.fileURL]

      let item = NSPasteboardItem()
      item.setString("foo", forType: .string)
      item.setData(image.tiffRepresentation!, forType: .tiff)
      item.setData("file://foo.bar".data(using: .utf8)!, forType: .fileURL)

      let copies = try await waitForCopies(after: {
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
      })
      let copied = try #require(copies.first)
      #expect(copies.count == 1)
      #expect(copied.contents.map({ $0.type }) == [fileURLType.rawValue])
    }

    @Test("Removes dynamic types")
    func removesDynamicTypes() async throws {
      let item = NSPasteboardItem()
      item.setString("foo", forType: .string)
      item.setData("".data(using: .utf8)!, forType: dynamicType)

      let copies = try await waitForCopies(after: {
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
      })
      let copied = try #require(copies.first)
      #expect(copies.count == 1)
      #expect(copied.contents.map({ $0.type }) == [stringType.rawValue])
    }

    @Test("Does not store Safari web archive")
    func doesNotStoreSafariWebArchive() async throws {
      let webArchive = NSPasteboard.PasteboardType.safariWebArchve

      let item = NSPasteboardItem()
      item.setString("hello from safari", forType: .string)
      item.setData(Data(repeating: 0x61, count: 1024 * 1024), forType: webArchive)

      let copies = try await waitForCopies(after: {
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
      })
      let copied = try #require(copies.first)
      #expect(copies.count == 1)
      #expect(Set(copied.contents.map(\.type)) == [stringType.rawValue])
    }

    private func waitForCopies(expectingCopy: Bool = true, after trigger: () -> Void) async throws -> [HistoryItem] {
      var copies: [HistoryItem] = []
      clipboard.onNewCopy { copies.append($0) }
      clipboard.start()
      trigger()
      let deadline = ContinuousClock.now + .seconds(2)
      while (!expectingCopy || copies.isEmpty) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      return copies
    }

    private func frontmostAppBundleIdentifier() throws -> String {
      guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
        try Test.cancel("No frontmost application to attribute a copy to")
      }

      return bundleIdentifier
    }
  }
  // swiftlint:enable type_body_length
}
