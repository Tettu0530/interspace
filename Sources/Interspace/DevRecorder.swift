import AppKit
import CoreMedia
import ScreenCaptureKit

/// Development only. Records the screen, the overlay included, at the full frame rate and at a small size,
/// then writes what it saw: one line per frame, and a sheet of the frames around every sudden change.
/// It is for faults that last one frame, which a person can see and a log cannot.
final class DevRecorder: NSObject, SCStreamOutput {
    private struct Frame {
        let time: Date
        let mean: Double
        let pixels: Data
    }

    private let width = 450
    private let height = 296
    private let queue = DispatchQueue(label: "com.cnrad.interspace.dev-recorder")
    private var stream: SCStream?
    private var frames: [Frame] = []

    func start(screen: NSScreen) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let self, let display = content?.displays.first(where: { $0.displayID == screen.displayID }) else { return }
            let configuration = SCStreamConfiguration()
            configuration.width = self.width
            configuration.height = self.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.queueDepth = 8
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
            try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            stream.startCapture { _ in }
            self.stream = stream
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer, frames.count < 600 else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let rows = min(CVPixelBufferGetHeight(buffer), height)
        let columns = min(CVPixelBufferGetWidth(buffer), width)

        var pixels = Data(count: width * height * 4)
        var total = 0
        pixels.withUnsafeMutableBytes { target in
            for row in 0..<rows {
                let source = base.advanced(by: row * rowBytes)
                memcpy(target.baseAddress!.advanced(by: row * width * 4), source, columns * 4)
                let line = source.assumingMemoryBound(to: UInt8.self)
                var column = 0
                while column < columns {
                    total += Int(line[column * 4]) + Int(line[column * 4 + 1]) + Int(line[column * 4 + 2])
                    column += 4
                }
            }
        }
        let samples = max(rows * ((columns + 3) / 4) * 3, 1)
        frames.append(Frame(time: Date(), mean: Double(total) / Double(samples), pixels: pixels))
    }

    /// Stops and writes `report.txt` and `sheet.png` to the folder.
    func stop(folder: URL, completion: @escaping () -> Void) {
        stream?.stopCapture { [weak self] _ in
            self?.queue.async {
                self?.write(to: folder)
                DispatchQueue.main.async(execute: completion)
            }
        }
        stream = nil
    }

    private func difference(_ a: Data, _ b: Data) -> Double {
        var total = 0
        var count = 0
        a.withUnsafeBytes { first in
            b.withUnsafeBytes { second in
                var index = 0
                while index < min(first.count, second.count) {
                    total += abs(Int(first[index]) - Int(second[index]))
                    count += 1
                    index += 16
                }
            }
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    private func write(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var report = "\(frames.count) frames\n"
        var changes: [Double] = [0]
        for index in frames.indices {
            let change = index > 0 ? difference(frames[index].pixels, frames[index - 1].pixels) : 0
            if index > 0 { changes.append(change) }
            let gap = index > 0 ? Int(frames[index].time.timeIntervalSince(frames[index - 1].time) * 1000) : 0
            report += String(format: "%3d  %@  +%4d ms  brightness %6.1f  change %6.1f\n",
                             index, formatter.string(from: frames[index].time), gap, frames[index].mean, change)
        }
        try? report.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)

        // The frames around every sudden change, at most 35.
        var chosen: [Int] = []
        for index in frames.indices where changes[index] > 6 {
            for neighbour in [index - 1, index, index + 1] where frames.indices.contains(neighbour) && !chosen.contains(neighbour) {
                chosen.append(neighbour)
            }
        }
        chosen = Array(chosen.sorted().prefix(35))
        guard !chosen.isEmpty else { return }

        let columns = 5
        let cellWidth = 360
        let cellHeight = cellWidth * height / width
        let rows = (chosen.count + columns - 1) / columns
        guard let sheet = CGContext(
            data: nil, width: columns * cellWidth, height: rows * (cellHeight + 22), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        sheet.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: columns * cellWidth, height: rows * (cellHeight + 22)))

        for (place, index) in chosen.enumerated() {
            let frame = frames[index]
            guard let provider = CGDataProvider(data: frame.pixels as CFData),
                  let image = CGImage(
                      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                  )
            else { continue }
            let column = place % columns
            let row = place / columns
            let y = (rows - 1 - row) * (cellHeight + 22)
            sheet.draw(image, in: CGRect(x: column * cellWidth + 2, y: y + 2, width: cellWidth - 4, height: cellHeight))

            // The frame number above each picture.
            let label = NSAttributedString(
                string: "\(index)  \(formatter.string(from: frame.time))",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black]
            )
            let line = CTLineCreateWithAttributedString(label)
            sheet.textPosition = CGPoint(x: column * cellWidth + 6, y: y + cellHeight + 6)
            CTLineDraw(line, sheet)
        }
        if let image = sheet.makeImage() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("sheet.png"))
        }
    }
}
