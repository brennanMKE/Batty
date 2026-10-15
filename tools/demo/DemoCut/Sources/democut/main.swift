// main.swift

import AVFoundation
import AppKit
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// democut cut --raw in.mp4 --cues cues.json --overlay overlay.json --out out.mp4 --poster out.jpg [--align start|end] [--offset s]
// democut selftest out.mp4
// Host-side only: reads a recording that came back from the VM, never records.

let outWidth = 1920
let outHeight = 1080
let fps = 30.0
let tailHold = 0.35

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("democut: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}

func alpha(_ t: Double, from t0: Double, to t1: Double, fade: Double = 0.1) -> Double {
    max(0, min(1, (t - t0) / fade, (t1 - t) / fade))
}

// MARK: - Timeline

func buildTimeline(cues: CueSheet, overlay: Overlay, offset: Double, videoDuration: Double) -> (Timeline, start: Double, end: Double) {
    let start = (cues.cues.first { $0.kind == "start" }?.t ?? 0) + offset
    let end = min(videoDuration, (cues.cues.last { $0.kind == "end" }?.t ?? cues.duration) + offset)
    var ranges: [(Double, Double, String)] = []
    for cue in cues.cues where cue.kind == "speedStart" {
        guard let stop = cues.cues.first(where: { $0.kind == "speedEnd" && $0.id == cue.id && $0.t >= cue.t }) else { continue }
        let a = max(start, cue.t + offset), b = min(end, stop.t + offset)
        if b > a { ranges.append((a, b, cue.id)) }
    }
    ranges.sort { $0.0 < $1.0 }

    var segments: [Segment] = []
    var cursor = start
    var out = 0.0
    func add(_ a: Double, _ b: Double, _ speed: Double, ramp: Bool = false) {
        guard b > a else { return }
        let segment = Segment(src0: a, src1: b, speed: speed, out0: out, ramp: ramp)
        segments.append(segment)
        out = segment.out1
    }
    let maxSpeedSeconds = overlay.maxSpeedSeconds ?? 8
    var fast: [(Double, Double, Double)] = []
    for (a, b, id) in ranges {
        let configured = overlay.speed?[id] ?? 8
        fast.append((a, b, max(configured, (b - a) / maxSpeedSeconds, 1)))
    }
    // The rest plays at a base speed chosen so the whole clip fits the length cap: UI driving
    // has latency between actions that is dead air on screen.
    let fixed = fast.reduce(0) { $0 + ($1.1 - $1.0) / $1.2 }
    let normal = (end - start) - fast.reduce(0) { $0 + ($1.1 - $1.0) }
    let room = max(2.0, (overlay.maxSeconds ?? 13.0) - 0.95 - fixed)
    let base = min(4.0, max(overlay.baseSpeed ?? 1.0, normal / room))
    for (a, b, factor) in fast {
        add(cursor, a, base)
        add(a, b, factor, ramp: true)
        cursor = b
    }
    add(cursor, end, base)
    return (Timeline(segments: segments), start, end)
}

func unusedTimeline() {
}

struct Event {
    var out0: Double
    var out1: Double
    var sprite: Sprite
    var position: String
}

func buildEvents(cues: CueSheet, overlay: Overlay, offset: Double, timeline: Timeline, start: Double, end: Double, lead: Double, renderer: Renderer) -> [Event] {
    var events: [Event] = []
    let hold = 0.0
    let timed = cues.cues.filter { $0.kind == "callout" }.compactMap { cue -> (Double, Callout, String)? in
        guard let callout = overlay.callouts[cue.id] else { return nil }
        let t = cue.t + offset
        guard t >= start, t < end else { return nil }
        return (timeline.output(forSource: t) + lead, callout, cue.id)
    }.sorted { $0.0 < $1.0 }
    for (index, item) in timed.enumerated() {
        let nextStart = index + 1 < timed.count ? timed[index + 1].0 - 0.1 : timeline.duration + lead
        let stop = min(item.0 + (item.1.duration ?? 1.8), nextStart, timeline.duration + lead)
        guard stop > item.0 + 0.3 else { continue }
        events.append(Event(out0: item.0, out1: stop, sprite: renderer.callout(item.1), position: item.1.position ?? "bottom-left"))
    }
    for segment in timeline.segments where segment.ramp && segment.out1 - segment.out0 > 0.6 {
        let label = String(format: "%g\u{00D7}", segment.speed.rounded())
        events.append(Event(out0: segment.out0 + lead, out1: segment.out1 + lead, sprite: renderer.badge(label), position: "top-right"))
    }
    return events
}

func origin(for event: Event, in size: CGSize, scale: CGFloat) -> CGPoint {
    let margin = 64 * scale, bottom = 70 * scale
    let s = event.sprite
    switch event.position {
    case "top-left": return CGPoint(x: margin, y: size.height - margin - s.height)
    case "top-right": return CGPoint(x: size.width - margin - s.width, y: size.height - margin - s.height)
    case "top-center": return CGPoint(x: (size.width - s.width) / 2, y: size.height - margin - s.height)
    case "bottom-right": return CGPoint(x: size.width - margin - s.width, y: bottom)
    case "bottom-center": return CGPoint(x: (size.width - s.width) / 2, y: bottom)
    default: return CGPoint(x: margin, y: bottom)
    }
}

func buildZooms(cues: CueSheet, offset: Double, timeline: Timeline, start: Double, end: Double, lead: Double) -> [Zoom] {
    var zooms: [Zoom] = []
    for cue in cues.cues where cue.kind == "zoomStart" {
        guard let r = cue.rect, r.count == 4 else { continue }
        let t0 = cue.t + offset
        guard t0 >= start, t0 < end else { continue }
        let stop = cues.cues.first { $0.kind == "zoomEnd" && $0.id == cue.id && $0.t >= cue.t }.map { min($0.t + offset, end) } ?? min(t0 + 2.5, end)
        zooms.append(Zoom(out0: timeline.output(forSource: t0) + lead, out1: timeline.output(forSource: stop) + lead, rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3])))
    }
    return zooms
}

/// The visible part of the screen at output time `t`, in 1920x1080 coordinates: eased in and out over 0.25 s.
func cameraRect(at t: Double, zooms: [Zoom]) -> CGRect {
    let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    for z in zooms where t >= z.out0 - 0.001 && t <= z.out1 + 0.001 {
        let p = easeInOut(min((t - z.out0) / 0.25, (z.out1 - t) / 0.25, 1))
        return CGRect(
            x: full.minX + (z.rect.minX - full.minX) * p, y: full.minY + (z.rect.minY - full.minY) * p,
            width: full.width + (z.rect.width - full.width) * p, height: full.height + (z.rect.height - full.height) * p
        )
    }
    return full
}

// MARK: - Cut

func writeJPEG(_ image: CGImage, to url: URL) {
    let width = 1280, height = Int(Double(image.height) * 1280.0 / Double(image.width))
    let scaled = Canvas.makeContext(width: width, height: height)
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let small = scaled.makeImage()!
    var quality = 0.85
    while true {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        if data.length < 190_000 || quality < 0.35 {
            try? (data as Data).write(to: url)
            return
        }
        quality -= 0.07
    }
}

func cut(_ args: [String]) {
    guard let rawPath = option("--raw", in: args), let cuesPath = option("--cues", in: args),
          let overlayPath = option("--overlay", in: args), let outPath = option("--out", in: args)
    else { fail("usage: democut cut --raw in.mp4 --cues cues.json --overlay overlay.json --out out.mp4 [--poster out.jpg] [--align start|end] [--offset s]") }
    let posterPath = option("--poster", in: args)

    let decoder = JSONDecoder()
    guard let cues = try? decoder.decode(CueSheet.self, from: Data(contentsOf: URL(fileURLWithPath: cuesPath))) else { fail("bad cue sheet \(cuesPath)") }
    guard let overlay = try? decoder.decode(Overlay.self, from: Data(contentsOf: URL(fileURLWithPath: overlayPath))) else { fail("bad overlay file \(overlayPath)") }

    let asset = AVURLAsset(url: URL(fileURLWithPath: rawPath))
    guard let track = asset.tracks(withMediaType: .video).first else { fail("no video track in \(rawPath)") }
    let videoDuration = CMTimeGetSeconds(asset.duration)
    let natural = track.naturalSize.applying(track.preferredTransform)
    let sourceSize = CGSize(width: abs(natural.width), height: abs(natural.height))

    var offset = Double(option("--offset", in: args) ?? "") ?? 0
    if (option("--align", in: args) ?? "start") == "end" { offset = videoDuration - cues.duration }

    let (timeline, start, end) = buildTimeline(cues: cues, overlay: overlay, offset: offset, videoDuration: videoDuration)
    guard timeline.duration > 1 else { fail("empty timeline (start \(start), end \(end), video \(videoDuration))") }
    let lead = overlay.titleHold ?? 0.6
    let total = lead + timeline.duration + tailHold
    let frames = Int((total * fps).rounded(.down))
    let size = CGSize(width: outWidth, height: outHeight)
    let scale = CGFloat(outWidth) / 1920
    let renderer = Renderer(scale: scale)
    let events = buildEvents(cues: cues, overlay: overlay, offset: offset, timeline: timeline, start: start, end: end, lead: lead, renderer: renderer)

    let hold = lead
    let zooms = buildZooms(cues: cues, offset: offset, timeline: timeline, start: start, end: end, lead: lead)
    let titleCard = renderer.card(title: overlay.title, subtitle: overlay.subtitle, size: size)
    var posterTime = total * 0.4
    if let cue = cues.cues.first(where: { $0.kind == "poster" }) { posterTime = timeline.output(forSource: cue.t + offset) + lead + 0.3 }
    posterTime = min(posterTime, total - 0.1)

    // Reader
    guard let reader = try? AVAssetReader(asset: asset) else { fail("cannot read \(rawPath)") }
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    readerOutput.alwaysCopiesSampleData = false
    reader.add(readerOutput)
    let from = max(0, start - 1.0)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: min(videoDuration, end + 0.5), preferredTimescale: 600))
    guard reader.startReading() else { fail("reader failed: \(String(describing: reader.error))") }

    // Writer
    let outURL = URL(fileURLWithPath: outPath)
    try? FileManager.default.removeItem(at: outURL)
    guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else { fail("cannot write \(outPath)") }
    writer.shouldOptimizeForNetworkUse = true
    let bitrate = Int(min(2_600_000, 7.2 * 1024 * 1024 * 8 / total))
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: outWidth,
        AVVideoHeightKey: outHeight,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 90,
            AVVideoExpectedSourceFrameRateKey: Int(fps),
            AVVideoAllowFrameReorderingKey: true,
        ] as [String: Any],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: outWidth,
        kCVPixelBufferHeightKey as String: outHeight,
    ])
    writer.add(input)
    guard writer.startWriting() else { fail("writer failed: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    var current: CMSampleBuffer?
    var pending: CMSampleBuffer?
    func pts(_ sample: CMSampleBuffer) -> Double { CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) }

    var posterImage: CGImage?
    var lastFrame: CGImage?
    var debugTimes = (option("--debug-frames", in: args) ?? "").split(separator: ",").compactMap { Double($0) }.sorted()

    for k in 0..<frames {
        let t = Double(k) / fps
        let want = timeline.source(forOutput: min(max(0, t - lead), timeline.duration - 0.001))
        while true {
            if pending == nil { pending = readerOutput.copyNextSampleBuffer() }
            guard let next = pending else { break }
            if pts(next) <= want || current == nil { current = next; pending = nil } else { break }
        }

        while !input.isReadyForMoreMediaData { usleep(2000) }
        guard let pool = adaptor.pixelBufferPool else { fail("no pixel buffer pool") }
        var bufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
        guard let buffer = bufferOut else { fail("no output buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: outWidth, height: outHeight, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Canvas.bitmapInfo
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        ctx.interpolationQuality = .high

        if t < lead + timeline.duration, let sample = current, let image = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let source = CGContext(
                data: CVPixelBufferGetBaseAddress(image), width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(image),
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Canvas.bitmapInfo
            )!
            if let whole = source.makeImage() {
                let camera = cameraRect(at: t, zooms: zooms)
                let k = CGFloat(whole.width) / 1920
                let region = CGRect(x: camera.minX * k, y: camera.minY * k, width: camera.width * k, height: camera.height * k).integral
                let cg = camera.width < 1919 ? (whole.cropping(to: region) ?? whole) : whole
                let fit = min(size.width / CGFloat(cg.width), size.height / CGFloat(cg.height))
                let w = CGFloat(cg.width) * fit, h = CGFloat(cg.height) * fit
                ctx.draw(cg, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        } else if let lastFrame {
            ctx.draw(lastFrame, in: CGRect(origin: .zero, size: size))
        }

        for event in events {
            let a = alpha(t, from: event.out0, to: event.out1)
            guard a > 0 else { continue }
            let at = origin(for: event, in: size, scale: scale)
            ctx.setAlpha(a)
            ctx.draw(event.sprite.image, in: CGRect(x: at.x, y: at.y + (1 - a) * 12 * scale, width: event.sprite.width, height: event.sprite.height))
        }
        ctx.setAlpha(1)

        if t >= lead + timeline.duration - 0.05, t < lead + timeline.duration { lastFrame = ctx.makeImage() }

        let titleAlpha = t < hold ? alpha(t, from: -1, to: hold, fade: 0.12) : 0
        if titleAlpha > 0 {
            ctx.setAlpha(titleAlpha)
            ctx.draw(titleCard, in: CGRect(origin: .zero, size: size))
            ctx.setAlpha(1)
        }
        if posterImage == nil, t >= posterTime { posterImage = ctx.makeImage() }
        if let next = debugTimes.first, t >= next, let image = ctx.makeImage() {
            debugTimes.removeFirst()
            writeJPEG(image, to: URL(fileURLWithPath: outPath + String(format: ".f%.1f.jpg", next)))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(k), timescale: Int32(fps)))
    }

    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    reader.cancelReading()
    guard writer.status == .completed else { fail("write failed: \(String(describing: writer.error))") }

    if let posterPath, let posterImage { writeJPEG(posterImage, to: URL(fileURLWithPath: posterPath)) }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: outPath)[.size] as? Int) ?? 0
    print(String(format: "{\"out\": \"%@\", \"seconds\": %.1f, \"bytes\": %d, \"source\": \"%dx%d\", \"offset\": %.2f}", outPath, Double(frames) / fps, bytes, Int(sourceSize.width), Int(sourceSize.height), offset))
}

// MARK: - Selftest source

/// A synthetic 40 s recording with a frame counter, to exercise the cut without a VM run.
func selftest(_ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for k in 0..<(40 * 30) {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Canvas.bitmapInfo)!
        let t = Double(k) / 30
        ctx.setFillColor(CGColor(red: 0.12, green: 0.14 + 0.1 * sin(t), blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 80 + t * 40, y: 400, width: 200, height: 200))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attributed(String(format: "t = %.2f", t), font: NSFont.monospacedSystemFont(ofSize: 90, weight: .bold), color: .white).draw(at: CGPoint(x: 100, y: 700))
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(k), timescale: 30))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
}

/// democut info file.mp4: one JSON line with duration, bytes and size, for the checks in make-demos.sh.
func info(_ path: String) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let track = asset.tracks(withMediaType: .video).first
    let size = track?.naturalSize ?? .zero
    let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    print(String(format: "{\"seconds\": %.1f, \"bytes\": %d, \"width\": %d, \"height\": %d, \"audio\": %d}", CMTimeGetSeconds(asset.duration), bytes, Int(size.width), Int(size.height), asset.tracks(withMediaType: .audio).count))
}

/// democut frames in.mp4 outPrefix t1,t2,...: stills straight from a recording, for looking at what a scene did.
func frames(_ path: String, _ prefix: String, _ times: String) {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: 1280, height: 720)
    for t in times.split(separator: ",").compactMap({ Double($0) }) {
        guard let image = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { continue }
        writeJPEG(image, to: URL(fileURLWithPath: String(format: "%@.%05.1f.jpg", prefix, t)))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "cut": cut(args)
case "frames": frames(args[1], args[2], args[3])
case "info": info(args.count > 1 ? args[1] : "")
case "selftest": selftest(args.count > 1 ? args[1] : "selftest.mp4")
default: fail("commands: cut, selftest")
}
