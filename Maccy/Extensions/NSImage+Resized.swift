import AppKit

// Based on https://stackoverflow.com/questions/73062803/resizing-nsimage-keeping-aspect-ratio-reducing-the-image-size-while-trying-to-sc.
extension NSImage {
  /// Returns the pixel dimensions of the image.
  /// On Retina displays, this differs from `size` which returns logical points.
  var pixelSize: NSSize {
    if let representation = representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) {
      return NSSize(width: CGFloat(representation.pixelsWide), height: CGFloat(representation.pixelsHigh))
    }
    // Fallback to logical size if no bitmap representation is available
    return size
  }

  func resized(to newSize: NSSize) -> NSImage {
    guard size.width > 0, size.height > 0, newSize.width > 0, newSize.height > 0 else {
      return self
    }

    let ratioX = newSize.width / size.width
    let ratioY = newSize.height / size.height
    let ratio = min(ratioX, ratioY)

    // Don't attempt to size up.
    guard ratio < 1 else {
      return self
    }

    let newHeight = size.height * ratio
    let newWidth = size.width * ratio
    let newSize = NSSize(width: newWidth, height: newHeight)
    let sourceScale = max(pixelSize.width / size.width, pixelSize.height / size.height, 1)
    let displayScale = NSScreen.forPopup?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let scale = max(sourceScale, displayScale)
    let pixelsWide = max(1, Int(ceil(newWidth * scale)))
    let pixelsHigh = max(1, Int(ceil(newHeight * scale)))

    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelsWide,
      pixelsHigh: pixelsHigh,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return self
    }
    bitmap.size = newSize

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      return self
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(
      in: NSRect(origin: .zero, size: newSize),
      from: NSRect(origin: .zero, size: size),
      operation: .copy,
      fraction: 1
    )
    context.flushGraphics()

    let image = NSImage(size: newSize)
    image.addRepresentation(bitmap)
    return image
  }
}
