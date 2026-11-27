import AppKit
import ScreenCaptureKit

/// Finds what the real caret looks like by watching it blink. When an app comes to the front,
/// a few still images of a small strip around the caret are taken a third of a second apart:
/// the text stays put and the caret blinks, so the pixels that change are exactly the caret's.
/// That gives its shape (bar, underline or block), its exact place, its colour and the colour
/// under it. Never a continuous stream; Caret Trail's own windows are left out of the images.
/// Needs the Screen Recording permission.
final class ScreenSampler {
    struct Shape {
        /// The real caret's rect relative to the Accessibility caret rect's origin: an offset in
        /// `origin`, the caret's own size in `size`.
        let offset: CGRect
        let caret: NSColor
        let background: NSColor
    }

    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    private(set) var busy = false

    private static let frames = 5
    private static let interval: UInt64 = 330_000_000 // ns: the frames span more than one blink cycle

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    /// Calls back on the main thread with the shape, or nil and the reason it wasn't found.
    func probe(caret: CGRect, completion: @escaping (Shape?, String) -> Void) {
        guard !busy else { return }
        busy = true
        let region = CGRect(x: caret.minX - 12, y: caret.minY - 4, width: caret.width + 30, height: caret.height + 8)
        Task {
            var shape: Shape?
            var note: String
            do {
                var images: [CGImage] = []
                var scale: CGFloat = 1
                for i in 0..<Self.frames {
                    if i > 0 { try await Task.sleep(nanoseconds: Self.interval) }
                    guard let (image, s) = try await self.capture(region) else { break }
                    images.append(image)
                    scale = s
                }
                (shape, note) = Self.findCaret(in: images, region: region, scale: scale, caret: caret)
            } catch {
                note = "capture failed: \(error.localizedDescription)"
            }
            let (found, reason) = (shape, note)
            await MainActor.run {
                self.busy = false
                completion(found, reason)
            }
        }
    }

    private func shareable() async throws -> SCShareableContent {
        if let content, Date().timeIntervalSince(contentDate) < 30 { return content }
        // All windows, so our own app is listed even while the overlay is hidden.
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        content = fresh
        contentDate = Date()
        return fresh
    }

    private func capture(_ region: CGRect) async throws -> (CGImage, CGFloat)? {
        let center = CGPoint(x: region.midX, y: region.midY)
        let found: (frame: CGRect, scale: CGFloat, number: CGDirectDisplayID)? = await MainActor.run {
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return (screen.frame, screen.backingScaleFactor, number)
        }
        guard let (frame, scale, number) = found else { return nil }
        let content = try await shareable()
        guard let display = content.displays.first(where: { $0.displayID == number }) else { return nil }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: region.minX - frame.minX, y: frame.maxY - region.maxY,
                                   width: region.width, height: region.height)
        config.width = max(1, Int(region.width * scale))
        config.height = max(1, Int(region.height * scale))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    private static func pixels(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    /// The pixels that change between images are the caret. Image rows count from the top.
    static func findCaret(in images: [CGImage], region: CGRect, scale: CGFloat, caret: CGRect) -> (Shape?, String) {
        guard images.count >= 2, let first = images.first else { return (nil, "not enough images") }
        let width = first.width, height = first.height
        guard images.allSatisfy({ $0.width == width && $0.height == height }) else { return (nil, "image sizes differ") }
        let frames = images.compactMap(pixels(of:))
        guard frames.count == images.count else { return (nil, "unreadable image") }
        let total = width * height

        var changed = [Bool](repeating: false, count: total)
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        for p in 0..<total {
            var lo = (255, 255, 255), hi = (0, 0, 0)
            for f in frames {
                let r = Int(f[p * 4]), g = Int(f[p * 4 + 1]), b = Int(f[p * 4 + 2])
                lo = (min(lo.0, r), min(lo.1, g), min(lo.2, b))
                hi = (max(hi.0, r), max(hi.1, g), max(hi.2, b))
            }
            if (hi.0 - lo.0) + (hi.1 - lo.1) + (hi.2 - lo.2) > 90 {
                changed[p] = true
                count += 1
                let x = p % width, y = p / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard count >= 4 else { return (nil, "nothing blinked (\(count) px changed)") }
        let box = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                         width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        guard box.width <= 24, box.height <= caret.height * 1.5 else {
            return (nil, "changed area too large for a caret: \(box.size)")
        }

        // Background: the most common colour among pixels that never changed.
        func bucket(_ p: Int) -> Int {
            Int(frames[0][p * 4] >> 4) << 8 | Int(frames[0][p * 4 + 1] >> 4) << 4 | Int(frames[0][p * 4 + 2] >> 4)
        }
        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for p in 0..<total where !changed[p] {
            var e = buckets[bucket(p), default: (0, 0, 0, 0)]
            e.n += 1; e.r += Int(frames[0][p * 4]); e.g += Int(frames[0][p * 4 + 1]); e.b += Int(frames[0][p * 4 + 2])
            buckets[bucket(p)] = e
        }
        guard let top = buckets.values.max(by: { $0.n < $1.n }) else { return (nil, "no background") }
        let bg = (top.r / top.n, top.g / top.n, top.b / top.n)

        // Caret colour: from the image where the changed pixels stand furthest from the background.
        let changedPixels = (0..<total).filter { changed[$0] }
        func distance(_ f: [UInt8]) -> Int {
            changedPixels.reduce(0) { sum, p in
                sum + abs(Int(f[p * 4]) - bg.0) + abs(Int(f[p * 4 + 1]) - bg.1) + abs(Int(f[p * 4 + 2]) - bg.2)
            }
        }
        let lit = frames.max { distance($0) < distance($1) }!
        var sum = (0, 0, 0)
        for p in changedPixels {
            sum.0 += Int(lit[p * 4]); sum.1 += Int(lit[p * 4 + 1]); sum.2 += Int(lit[p * 4 + 2])
        }
        func color(_ c: (Int, Int, Int)) -> NSColor {
            NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        // Image rows run from the top; screen y runs from the bottom.
        let onScreen = CGRect(x: region.minX + box.minX, y: region.maxY - box.maxY, width: box.width, height: box.height)
        let offset = CGRect(x: onScreen.minX - caret.minX, y: onScreen.minY - caret.minY,
                            width: onScreen.width, height: onScreen.height)
        let shape = Shape(offset: offset, caret: color((sum.0 / count, sum.1 / count, sum.2 / count)), background: color(bg))
        return (shape, "found \(count) px, offset \(offset), caret \(shape.caret), background \(shape.background)")
    }
}
