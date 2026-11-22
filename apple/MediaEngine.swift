// The media engine of the Apple runners: the iPhone's and iPad's
// (ios/Runner) and the Mac's (macos/Runner) compile this one file. On the
// phones it is the only engine; on a Mac it stands beside ffmpeg
// (docs/design/macos-remove-ffmpeg.md).
import Accelerate
import AVFoundation
import CoreImage
import VideoToolbox

#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif
#if os(iOS)
  import UIKit
#endif

struct EngineError: Error, CustomStringConvertible {
  let description: String
}

/// The phone's media engine on iOS (spec §2, §9; owner, 2026-11-13: native
/// engines): a video probed and its frames taken by AVFoundation, and
/// written by an asset reader and writer with the app's colour LUTs
/// (changing at their times) and its overlay pictures applied by Core
/// Image, as HEVC at the bit rate asked for. One encode at a time; the
/// Dart side asks for its progress and may cancel it. An export that iOS
/// interrupts (the screen locked, the app left the foreground) is started
/// again once the app is back.
// One line of the engine's progress in the app's output (flutter run's
// log in a debug or profile build), for following an export the phone
// interrupted.
func engineTrace(_ line: @autoclosure () -> String) {
  print("uwmedia engine: \(line())")
  // The output is a pipe there, which holds lines back until it is full.
  fflush(stdout)
}

func describe(_ error: Error?) -> String {
  guard let error = error as NSError? else { return "none" }
  var text = "\(error.domain) \(error.code) \(error.localizedDescription)"
  if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError {
    text += " <- \(under.domain) \(under.code)"
  }
  return text
}

final class MediaEngine {
  static let shared = MediaEngine()

  private let lock = NSLock()
  private var running = false
  private var cancelled = false
  private var percent: Int?
  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    let fail: (Error) -> Void = { error in
      DispatchQueue.main.async {
        let code = (error as? EngineError)?.description == "Stopped" ? "cancelled" : "engine"
        result(FlutterError(code: code, message: "\(error)", details: nil))
      }
    }
    switch call.method {
    case "probe":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "engine", message: "No path", details: nil))
        return
      }
      Task.detached {
        do { reply(try await self.probe(path)) } catch { fail(error) }
      }
    case "frameAt":
      guard let path = args["path"] as? String, let maxWidth = args["maxWidth"] as? Int,
        let maxHeight = args["maxHeight"] as? Int
      else {
        result(FlutterError(code: "engine", message: "No path or size", details: nil))
        return
      }
      Task.detached {
        do {
          reply(
            try await self.frameAt(
              path,
              seconds: args["seconds"] as? Double ?? 0,
              maxWidth: maxWidth,
              maxHeight: maxHeight,
              exact: args["exact"] as? Bool ?? false))
        } catch { fail(error) }
      }
    case "encode":
      guard args["input"] is String, args["output"] is String else {
        result(FlutterError(code: "engine", message: "No input or output", details: nil))
        return
      }
      lock.lock()
      let busy = running
      if !busy {
        running = true
        cancelled = false
        percent = nil
      }
      lock.unlock()
      if busy {
        result(FlutterError(code: "busy", message: "Another video is being written", details: nil))
        return
      }
      Task.detached {
        // Free for the next encode before the answer is given: a batch
        // starts its next file at once.
        func free() {
          self.lock.lock()
          self.running = false
          self.reader = nil
          self.writer = nil
          self.lock.unlock()
        }
        do {
          let done = try await self.encodeAgainWhenInterrupted(args)
          free()
          reply(done)
        } catch {
          try? FileManager.default.removeItem(atPath: args["output"] as? String ?? "")
          free()
          fail(error)
        }
      }
    case "copy":
      guard let input = args["input"] as? String, let output = args["output"] as? String else {
        result(FlutterError(code: "engine", message: "No input or output", details: nil))
        return
      }
      Task.detached {
        do {
          try await self.copy(input, to: output)
          reply(nil)
        } catch {
          try? FileManager.default.removeItem(atPath: output)
          fail(error)
        }
      }
    case "framesOpen":
      do {
        try frames.open(args)
        result(nil)
      } catch {
        result(FlutterError(code: "engine", message: "\(error)", details: nil))
      }
    case "framesAdd":
      guard let picture = args["rgba"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "engine", message: "No picture", details: nil))
        return
      }
      let count = args["count"] as? Int ?? 1
      Task.detached {
        do {
          try await self.frames.add(picture.data, count: count)
          reply(nil)
        } catch { fail(error) }
      }
    case "framesClose":
      Task.detached {
        do {
          try await self.frames.close()
          reply(nil)
        } catch { fail(error) }
      }
    case "framesCancel":
      frames.cancel()
      result(nil)
    case "progress":
      lock.lock()
      let value = running ? percent : nil
      lock.unlock()
      result(value)
    case "cancel":
      lock.lock()
      // Only the flag: the pumps stop at their next sample, and the encode
      // cancels the reader once none of them reads from it. Cancelling it
      // here, under a pump's copyNextSampleBuffer, crashes on a phone.
      cancelled = true
      lock.unlock()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private let frames = FrameWriter()

  // An HDR (HLG or PQ) video.
  private static func isHdr(_ format: CMFormatDescription) -> Bool {
    let transfer =
      CMFormatDescriptionGetExtension(
        format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    return transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
      || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
  }

  // The bits of each colour value of a video's pictures: 10 for what the
  // cameras call 10-bit, 8 where the file does not say.
  private static func bits(_ format: CMFormatDescription) -> Int {
    if let said = (CMFormatDescriptionGetExtension(
      format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?
      .intValue, said > 0
    {
      return said
    }
    // Not said (a camera's H.264, for one): from the decoder's own
    // record in the file.
    let atoms =
      CMFormatDescriptionGetExtension(
        format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
      as? [String: Any]
    if let hvcC = atoms?["hvcC"] as? Data, hvcC.count > 17 {
      return Int(hvcC[hvcC.startIndex + 17] & 7) + 8
    }
    if let avcC = atoms?["avcC"] as? Data {
      let b = [UInt8](avcC)
      // Only the profiles above Main say their depth, after the
      // parameter sets.
      guard b.count > 6, [100, 110, 122, 144, 244].contains(b[1]) else { return 8 }
      var at = 6
      for _ in 0..<Int(b[5] & 0x1f) {
        guard at + 2 <= b.count else { return 8 }
        at += 2 + Int(b[at]) << 8 + Int(b[at + 1])
      }
      guard at < b.count else { return 8 }
      let pictureSets = Int(b[at])
      at += 1
      for _ in 0..<pictureSets {
        guard at + 2 <= b.count else { return 8 }
        at += 2 + Int(b[at]) << 8 + Int(b[at + 1])
      }
      if at + 1 < b.count { return Int(b[at + 1] & 7) + 8 }
    }
    return 8
  }

  private func probe(_ path: String) async throws -> [String: Any?] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw EngineError(description: "No video in the file")
    }
    let (size, transform, fps, rate, formats) = try await track.load(
      .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate,
      .formatDescriptions)
    let shown = size.applying(transform)
    let duration = try await asset.load(.duration)
    var mime: String?
    var hdr = false
    var bits = 8
    if let format = formats.first {
      bits = Self.bits(format)
      mime =
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: "video/hevc"
        case kCMVideoCodecType_H264: "video/avc"
        default: "video/mp4"
        }
      hdr = Self.isHdr(format)
    }
    return [
      "width": Int(abs(shown.width).rounded()),
      "height": Int(abs(shown.height).rounded()),
      "durationMs": Int(duration.seconds * 1000),
      "fps": fps > 0 ? Double(fps) : nil,
      "bitrate": rate > 0 ? Int(rate) : nil,
      "mime": mime,
      "hdr": hdr,
      "bits": bits,
    ]
  }

  // A frame as RGBA bytes, upright, fitted inside the size asked for.
  // [exact] takes the frame at that time; otherwise one near it that is
  // quick to get (an SDR clip's frame is always the one at that time).
  // Its colours are those the Python app's OpenCV and the desktop's
  // ffmpeg read: YUV turned into RGB by the BT.601 matrix whatever the
  // clip is tagged with, without colour management (spec §10.30). An HDR
  // clip's frame is turned to sRGB by AVFoundation.
  private func frameAt(
    _ path: String, seconds: Double, maxWidth: Int, maxHeight: Int, exact: Bool
  ) async throws -> [String: Any]? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      return nil
    }
    let (formats, transform, fps) = try await track.load(
      .formatDescriptions, .preferredTransform, .nominalFrameRate)
    let frame =
      formats.contains(where: Self.isHdr)
      ? generatedFrame(asset, seconds: seconds, exact: exact)
      : try yuvFrame(
        asset, track, seconds: seconds, transform: transform, fps: Double(fps))
    guard let frame else { return nil }
    let (width, height, rgba) = frame
    let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
    if scale < 1 {
      // Made smaller by averaging, as ffmpeg's area scale does on the
      // desktop (AVFoundation's own scaling moved the colour analysis on
      // real footage).
      let outWidth = max(1, Int((Double(width) * scale).rounded()))
      let outHeight = max(1, Int((Double(height) * scale).rounded()))
      return [
        "width": outWidth,
        "height": outHeight,
        "rgba": FlutterStandardTypedData(
          bytes: Data(
            Self.areaScaled(rgba, width, height, to: outWidth, outHeight))),
      ]
    }
    return [
      "width": width,
      "height": height,
      "rgba": FlutterStandardTypedData(bytes: Data(rgba)),
    ]
  }

  // Core Image without colour management: the YUV of a frame turned into
  // RGB by its buffer's matrix and nothing else.
  private let rawContext = CIContext(options: [
    .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
  ])

  // The decoded frame shown at [seconds] (the first whose time is not
  // before it, half a frame allowed), read as BT.601 YUV and turned
  // upright; `nil` past the end.
  private func yuvFrame(
    _ asset: AVAsset, _ track: AVAssetTrack, seconds: Double, transform: CGAffineTransform,
    fps: Double
  ) throws -> (Int, Int, [UInt8])? {
    let frameTime = fps > 0 ? 1 / fps : 1.0 / 30
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: max(0, seconds - frameTime), preferredTimescale: 600000),
      duration: .positiveInfinity)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? EngineError(description: "Unreadable") }
    defer { reader.cancelReading() }
    while let sample = output.copyNextSampleBuffer() {
      let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      guard time >= seconds - frameTime / 2, let buffer = CMSampleBufferGetImageBuffer(sample)
      else { continue }
      CVBufferSetAttachment(
        buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
        .shouldPropagate)
      var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
      // The track's turn (a phone held upright): a quarter, half or
      // three quarters.
      let turns = Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded())
      switch (turns + 4) % 4 {
      case 1: image = image.oriented(.right)
      case 2: image = image.oriented(.down)
      case 3: image = image.oriented(.left)
      default: break
      }
      image = image.transformed(
        by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
      let width = Int(image.extent.width.rounded())
      let height = Int(image.extent.height.rounded())
      var rgba = [UInt8](repeating: 255, count: width * height * 4)
      rawContext.render(
        image, toBitmap: &rgba, rowBytes: width * 4,
        bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
        colorSpace: nil)
      return (width, height, rgba)
    }
    return nil
  }

  // A frame from AVFoundation's own image generator, in sRGB.
  private func generatedFrame(
    _ asset: AVAsset, seconds: Double, exact: Bool
  ) -> (Int, Int, [UInt8])? {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    if exact {
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
    }
    guard
      let image = try? generator.copyCGImage(
        at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    else {
      return nil
    }
    let width = image.width
    let height = image.height
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? (width, height, rgba) : nil
  }

  // [rgba] (width x height) made [outWidth] x [outHeight] by averaging
  // the source pixels each output pixel covers, parts of a pixel by the
  // part covered (ffmpeg's `flags=area`, OpenCV's INTER_AREA).
  private static func areaScaled(
    _ rgba: [UInt8], _ width: Int, _ height: Int, to outWidth: Int, _ outHeight: Int
  ) -> [UInt8] {
    // The source pixels and their weights for each output column or row.
    func spans(_ from: Int, _ to: Int) -> [[(index: Int, weight: Float)]] {
      let step = Double(from) / Double(to)
      return (0..<to).map { o in
        let start = Double(o) * step
        let end = min(Double(from), start + step)
        var parts: [(index: Int, weight: Float)] = []
        var i = Int(start)
        while Double(i) < end {
          let covered = min(end, Double(i + 1)) - max(start, Double(i))
          if covered > 0 { parts.append((i, Float(covered / step))) }
          i += 1
        }
        return parts
      }
    }
    let columns = spans(width, outWidth)
    let rows = spans(height, outHeight)
    // Across first (every source row), then down.
    var across = [Float](repeating: 0, count: height * outWidth * 3)
    rgba.withUnsafeBufferPointer { source in
      for y in 0..<height {
        let row = y * width * 4
        for (ox, parts) in columns.enumerated() {
          var r: Float = 0
          var g: Float = 0
          var b: Float = 0
          for (x, weight) in parts {
            let i = row + x * 4
            r += Float(source[i]) * weight
            g += Float(source[i + 1]) * weight
            b += Float(source[i + 2]) * weight
          }
          let o = (y * outWidth + ox) * 3
          across[o] = r
          across[o + 1] = g
          across[o + 2] = b
        }
      }
    }
    var out = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
    for (oy, parts) in rows.enumerated() {
      for ox in 0..<outWidth {
        var sums: [Float] = [0, 0, 0]
        for (y, weight) in parts {
          let i = (y * outWidth + ox) * 3
          sums[0] += across[i] * weight
          sums[1] += across[i + 1] * weight
          sums[2] += across[i + 2] * weight
        }
        let o = (oy * outWidth + ox) * 4
        for c in 0..<3 {
          out[o + c] = UInt8(min(255, max(0, sums[c].rounded())))
        }
      }
    }
    return out
  }

  // What Core Image is asked to do to each frame. The LUT filter and the
  // layers' pictures are made when their time comes and one of each kept
  // (a clip may have a hundred LUTs of four megabytes as a cube).
  private final class Effects {
    let lutSize: Int
    let luts: [(seconds: Double, bytes: Data)]
    // How long before a LUT's time the one before starts turning into it.
    let lutFade: Double
    let layers: [(x: Double, y: Double, pictures: [(seconds: Double, path: String)])]
    let fit: CGSize?
    let crop: CGRect?
    // The colour space whose values the LUT and the layers' pictures
    // meet: an SDR video's own (its frames' as AVFoundation hands them
    // over), so that they are the values ffmpeg gives them on the
    // desktop; sRGB for an HDR source, which Core Image turns to SDR.
    let hdr: Bool
    private var space: CGColorSpace?
    private let lock = NSLock()
    private var lutShown = -1
    private var mixShown: Float = 0
    private var lutFilter: CIFilter?
    private var cubes: [Int: [Float]] = [:]
    private var pictureShown: [Int]
    private var pictures: [CIImage?]
    // A comparison: the pictures of its mask (white where the corrected
    // picture shows) and of its divider line, of the frame's size.
    let compareMaskPath: String?
    let compareLinePath: String?
    private var compareMask: CIImage?
    private var compareLine: CIImage?

    init(_ args: [String: Any], hdr: Bool) {
      self.hdr = hdr
      compareMaskPath = args["compareMask"] as? String
      compareLinePath = args["compareLine"] as? String
      lutSize = args["lutSize"] as? Int ?? 0
      luts = (args["luts"] as? [[String: Any]] ?? []).compactMap {
        guard let lut = $0["lut"] as? FlutterStandardTypedData else { return nil }
        return (seconds: $0["seconds"] as? Double ?? 0, bytes: lut.data)
      }
      lutFade = (args["lutFade"] as? NSNumber)?.doubleValue ?? 0
      layers = (args["layers"] as? [[String: Any]] ?? []).map { layer in
        (
          x: (layer["x"] as? NSNumber)?.doubleValue ?? 0,
          y: (layer["y"] as? NSNumber)?.doubleValue ?? 0,
          pictures: (layer["pictures"] as? [[String: Any]] ?? []).map {
            (seconds: $0["seconds"] as? Double ?? 0, path: $0["path"] as? String ?? "")
          }
        )
      }
      if let width = args["width"] as? Int, let height = args["height"] as? Int {
        fit = CGSize(width: width, height: height)
      } else {
        fit = nil
      }
      if let part = args["crop"] as? [String: Any],
        let x = (part["x"] as? NSNumber)?.doubleValue,
        let y = (part["y"] as? NSNumber)?.doubleValue,
        let width = (part["width"] as? NSNumber)?.doubleValue,
        let height = (part["height"] as? NSNumber)?.doubleValue
      {
        crop = CGRect(x: x, y: y, width: width, height: height)
      } else {
        crop = nil
      }
      pictureShown = [Int](repeating: -1, count: layers.count)
      pictures = [CIImage?](repeating: nil, count: layers.count)
    }

    /// Throws for a LUT that is not [lutSize]³ colours.
    func check() throws {
      let count = lutSize * lutSize * lutSize * 3
      if !luts.isEmpty && (lutSize < 2 || luts.contains(where: { $0.bytes.count != count })) {
        throw EngineError(description: "A colour LUT of the wrong size")
      }
    }

    private static func index(_ starts: [Double], at seconds: Double) -> Int {
      var index = 0
      while index + 1 < starts.count && starts[index + 1] <= seconds {
        index += 1
      }
      return index
    }

    // The app's LUT (bytes, red changing fastest) as Core Image's cube:
    // RGBA floats in the same order.
    private func cube(_ index: Int) -> [Float] {
      if let kept = cubes[index] { return kept }
      let count = lutSize * lutSize * lutSize
      let bytes = [UInt8](luts[index].bytes)
      var cube = [Float](repeating: 1, count: count * 4)
      for i in 0..<count {
        cube[i * 4] = Float(bytes[i * 3]) / 255
        cube[i * 4 + 1] = Float(bytes[i * 3 + 1]) / 255
        cube[i * 4 + 2] = Float(bytes[i * 3 + 2]) / 255
      }
      // The one shown and the one it fades to; the others go.
      cubes = cubes.filter { $0.key == index - 1 || $0.key == index + 1 }
      cubes[index] = cube
      return cube
    }

    // The LUT of the frame at [seconds], applied in [space]: the one
    // whose time has come, and over the last [lutFade] seconds before the
    // next one's time a mix of the two, so that the colour moves from one
    // to the other instead of jumping.
    private func filter(at seconds: Double, _ space: CGColorSpace) -> CIFilter? {
      let index = Effects.index(luts.map(\.seconds), at: seconds)
      var mix: Float = 0
      if lutFade > 0, index + 1 < luts.count {
        let end = luts[index + 1].seconds
        let start = max(end - lutFade, luts[index].seconds)
        if seconds > start, end > start {
          // In 1/64ths: a filter is kept for the frames that share one.
          mix = Float(((seconds - start) / (end - start) * 64).rounded(.down)) / 64
        }
      }
      if index == lutShown && mix == mixShown { return lutFilter }
      var data = cube(index)
      if mix > 0 {
        let next = cube(index + 1)
        var weight = mix
        let from = data
        vDSP_vintb(from, 1, next, 1, &weight, &data, 1, vDSP_Length(data.count))
      }
      let filter = CIFilter(name: "CIColorCubeWithColorSpace")
      filter?.setValue(lutSize, forKey: "inputCubeDimension")
      filter?.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
      filter?.setValue(space, forKey: "inputColorSpace")
      lutShown = index
      mixShown = mix
      lutFilter = filter
      return filter
    }

    func apply(to source: CIImage, at seconds: Double, renderSize: CGSize) -> CIImage {
      lock.lock()
      defer { lock.unlock() }
      let space =
        self.space
        ?? (hdr ? nil : source.colorSpace) ?? CGColorSpace(name: CGColorSpace.sRGB)!
      self.space = space
      var image = source
      if let crop {
        // A part of the picture (a portrait copy for sharing); the rows
        // are counted from the top, Core Image's from the bottom.
        let whole = source.extent
        image = source.cropped(
          to: CGRect(
            x: whole.minX + crop.minX, y: whole.maxY - crop.maxY,
            width: crop.width, height: crop.height))
      }
      // The frame the LUT and the layers work on: the picture, or what
      // the crop left of it, with its corner at the origin.
      image = image.transformed(
        by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
      let work = image.extent.size
      let original = image
      if !luts.isEmpty, let filter = filter(at: seconds, space) {
        filter.setValue(image, forKey: kCIInputImageKey)
        image = filter.outputImage ?? image
      }
      if !luts.isEmpty, let maskPath = compareMaskPath {
        // The original where the mask is black, the corrected picture
        // where it is white; the mask's greys taken as they are.
        if compareMask == nil {
          compareMask = CIImage(
            contentsOf: URL(fileURLWithPath: maskPath), options: [.colorSpace: NSNull()])
        }
        if let mask = compareMask, let blend = CIFilter(name: "CIBlendWithMask") {
          blend.setValue(image, forKey: kCIInputImageKey)
          blend.setValue(original, forKey: kCIInputBackgroundImageKey)
          blend.setValue(mask, forKey: kCIInputMaskImageKey)
          image = blend.outputImage ?? image
        }
        if compareLine == nil, let linePath = compareLinePath {
          compareLine = CIImage(
            contentsOf: URL(fileURLWithPath: linePath), options: [.colorSpace: space])
        }
        if let line = compareLine {
          image = line.composited(over: image)
        }
      }
      for (number, layer) in layers.enumerated() where !layer.pictures.isEmpty {
        let index = Effects.index(layer.pictures.map(\.seconds), at: seconds)
        if pictureShown[number] != index {
          // Its values taken as [space]'s, as ffmpeg lays them on.
          pictures[number] = CIImage(
            contentsOf: URL(fileURLWithPath: layer.pictures[index].path),
            options: [.colorSpace: space])
          pictureShown[number] = index
        }
        guard let picture = pictures[number] else { continue }
        // The picture's top-left corner at (x, y) of the frame; Core
        // Image's origin is the bottom left.
        let placed = picture.transformed(
          by: CGAffineTransform(
            translationX: layer.x.rounded(),
            y: (work.height - layer.y - picture.extent.height).rounded()))
        image = placed.composited(over: image)
      }
      image = image.cropped(to: CGRect(origin: .zero, size: work))
      if fit != nil {
        // Scaled to fit and padded with black, as ffmpeg's scale and
        // pad; after the layers, so that they lie on the picture.
        let scale = min(renderSize.width / work.width, renderSize.height / work.height)
        let lanczos = CIFilter(name: "CILanczosScaleTransform")
        lanczos?.setValue(image, forKey: kCIInputImageKey)
        lanczos?.setValue(scale, forKey: kCIInputScaleKey)
        lanczos?.setValue(1.0, forKey: kCIInputAspectRatioKey)
        let scaled =
          lanczos?.outputImage
          ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = scaled.transformed(
          by: CGAffineTransform(
            translationX: ((renderSize.width - scaled.extent.width) / 2 - scaled.extent.minX)
              .rounded(),
            y: ((renderSize.height - scaled.extent.height) / 2 - scaled.extent.minY).rounded()))
        image = placed.composited(
          over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize)))
      }
      return image.cropped(to: CGRect(origin: .zero, size: renderSize))
    }
  }

  // The video and its sound as they are, in a file of [output]'s type
  // (an MP4, or a MOV for that ending), its index at the front: what a
  // run writes of a video it changes nothing in.
  private func copy(_ input: String, to output: String) async throws {
    let out = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: out)
    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    guard
      let export = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetPassthrough)
    else {
      throw EngineError(description: "The video cannot be copied")
    }
    let type: AVFileType = out.pathExtension.lowercased() == "mov" ? .mov : .mp4
    guard export.supportedFileTypes.contains(type) else {
      throw EngineError(description: "The video cannot be copied into this kind of file")
    }
    export.outputURL = out
    export.outputFileType = type
    export.shouldOptimizeForNetworkUse = true
    await export.export()
    guard export.status == .completed else {
      throw export.error ?? EngineError(description: "The video could not be copied")
    }
  }

  private func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  // Whether [error] is iOS taking the export away (the screen locked,
  // the app left the foreground): AVFoundation's "operation interrupted",
  // itself or underneath, or any failure while the app is not active.
  private func isInterruption(_ error: Error) async -> Bool {
    #if os(iOS)
    var next: NSError? = error as NSError
    while let current = next {
      if current.domain == AVFoundationErrorDomain
        && (current.code == AVError.Code.operationInterrupted.rawValue
          || current.code == AVError.Code.sessionWasInterrupted.rawValue)
      {
        return true
      }
      next = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    if error is EngineError { return false }
    return await !Self.appActive()
    #else
    // A Mac takes no export away.
    return false
    #endif
  }

  // Whether the app is in the foreground; a Mac's app always counts.
  private static func appActive() async -> Bool {
    #if os(iOS)
    return await UIApplication.shared.applicationState == .active
    #else
    return true
    #endif
  }

  // The encode, started again (up to three times) when iOS interrupted
  // it, once the app is in the foreground again.
  private func encodeAgainWhenInterrupted(_ args: [String: Any]) async throws -> [String: Any] {
    #if os(macOS)
      // A Mac slows an app that is behind other windows (App Nap) and may
      // sleep: neither while a video is written.
      let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled], reason: "Writing a video")
      defer { ProcessInfo.processInfo.endActivity(activity) }
    #endif
    var tries = 0
    while true {
      do {
        return try await encode(args)
      } catch {
        if isCancelled() { throw EngineError(description: "Stopped") }
        let interrupted = await isInterruption(error)
        let active = await Self.appActive()
        engineTrace(
          "encode failed: \(describe(error)); interruption \(interrupted), app active \(active)")
        guard interrupted else { throw error }
        tries += 1
        if tries > 3 {
          throw EngineError(
            description: "iOS stopped the export because the screen locked or UWMedia was "
              + "left. Keep UWMedia open and run it again.")
        }
        while await !Self.appActive() {
          if isCancelled() { throw EngineError(description: "Stopped") }
          try await Task.sleep(nanoseconds: 500_000_000)
        }
        engineTrace("app active again: encode try \(tries + 1)")
      }
    }
  }

  private func encode(_ args: [String: Any]) async throws -> [String: Any] {
    let source = URL(fileURLWithPath: args["input"] as! String)
    let out = URL(fileURLWithPath: args["output"] as! String)
    try? FileManager.default.removeItem(at: out)
    let asset = AVURLAsset(url: source)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw EngineError(description: "No video in the file")
    }
    let whole = try await asset.load(.duration).seconds
    // A part of the video only ("start" and "end", seconds): the LUTs'
    // and pictures' times count from its start.
    let from = min(max((args["start"] as? NSNumber)?.doubleValue ?? 0, 0), max(whole, 0))
    let to = min((args["end"] as? NSNumber)?.doubleValue ?? whole, whole)
    let part = to > from && (from > 0 || to < whole)
    let first = part ? CMTime(seconds: from, preferredTimescale: 600) : CMTime.zero
    let duration = part ? to - from : whole
    let formats = try await videoTrack.load(.formatDescriptions)
    let hdr = formats.contains(where: Self.isHdr)
    // HEVC, but H.264 for a copy made for sharing.
    let h264 = args["codec"] as? String == "h264"
    // A 10-bit source stays 10-bit (HEVC Main 10), as the desktop's
    // ffmpeg keeps it: the frames are read, worked on and written with
    // more than 8 bits. A copy for sharing is 8-bit H.264 whatever the
    // source.
    let tenBit = !h264 && (formats.map(Self.bits).max() ?? 8) >= 10
    let deep = tenBit ? CIContext(options: [.workingFormat: CIFormat.RGBAh]) : nil
    let effects = Effects(args, hdr: hdr)
    try effects.check()
    // withLock, not lock()/unlock(): this is an async function.
    lock.withLock { percent = nil }

    // Every frame goes through Core Image, which also turns the picture
    // upright; the output is SDR (BT.709).
    let composition = AVMutableVideoComposition(
      asset: asset,
      applyingCIFiltersWithHandler: { request in
        request.finish(
          with: effects.apply(
            to: request.sourceImage, at: request.compositionTime.seconds - first.seconds,
            renderSize: request.renderSize),
          context: deep)
      })
    if let fit = effects.fit {
      composition.renderSize = fit
    }
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    let size = composition.renderSize

    let reader = try AVAssetReader(asset: asset)
    if part {
      reader.timeRange = CMTimeRange(
        start: first, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }
    let videoOut = AVAssetReaderVideoCompositionOutput(
      videoTracks: [videoTrack],
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          tenBit
          ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
          : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ])
    videoOut.videoComposition = composition
    videoOut.alwaysCopiesSampleData = false
    reader.add(videoOut)

    let mov = out.pathExtension.lowercased() == "mov"
    let writer = try AVAssetWriter(outputURL: out, fileType: mov ? .mov : .mp4)
    var compression: [String: Any] = [:]
    if tenBit {
      compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
    }
    if let bitrate = (args["bitrate"] as? NSNumber)?.intValue, bitrate > 0 {
      compression[AVVideoAverageBitRateKey] = bitrate
    }
    var videoSettings: [String: Any] = [
      AVVideoCodecKey: h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    if !compression.isEmpty {
      videoSettings[AVVideoCompressionPropertiesKey] = compression
    }
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoIn.expectsMediaDataInRealTime = false
    writer.add(videoIn)

    // The sound as it is; a kind the file type cannot hold (PCM or
    // spatial sound in an MP4) as AAC.
    var audio: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
    for track in try await asset.loadTracks(withMediaType: .audio) {
      let format = try await track.load(.formatDescriptions).first
      let kind = format.map { CMFormatDescriptionGetMediaSubType($0) }
      let aac = kind == kAudioFormatMPEG4AAC
      var output: AVAssetReaderOutput = AVAssetReaderTrackOutput(
        track: track, outputSettings: nil)
      var input = AVAssetWriterInput(
        mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
      if !(aac || mov) || !writer.canAdd(input) {
        let source = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }?
          .pointee
        let channels = min(max(Int(source?.mChannelsPerFrame ?? 2), 1), 2)
        let rate = source.map { $0.mSampleRate }.flatMap { $0 > 0 ? $0 : nil } ?? 48000
        output = AVAssetReaderTrackOutput(
          track: track,
          outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: channels,
          ])
        input = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: min(rate, 48000),
            AVEncoderBitRateKey: 96000 * channels,
          ])
      }
      input.expectsMediaDataInRealTime = false
      guard reader.canAdd(output), writer.canAdd(input) else {
        throw EngineError(description: "The sound of this video cannot be written")
      }
      reader.add(output)
      writer.add(input)
      audio.append((output, input))
    }

    let stop = lock.withLock {
      self.reader = reader
      self.writer = writer
      return cancelled
    }
    if stop { throw EngineError(description: "Stopped") }

    let started = Date()
    guard reader.startReading() else {
      throw reader.error ?? EngineError(description: "The video could not be read")
    }
    guard writer.startWriting() else {
      throw writer.error ?? EngineError(description: "The video could not be written")
    }
    writer.startSession(atSourceTime: first)

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await MediaEngine.pump(
          videoOut, into: videoIn, writer: writer, queue: "uwmedia.engine.video",
          stop: self.isCancelled
        ) { time in
          guard duration > 0 else { return }
          self.lock.lock()
          self.percent = max(0, min(100, Int((time - first.seconds) / duration * 100)))
          self.lock.unlock()
        }
      }
      for (number, (output, input)) in audio.enumerated() {
        group.addTask {
          await MediaEngine.pump(
            output, into: input, writer: writer, queue: "uwmedia.engine.audio\(number)",
            stop: self.isCancelled)
        }
      }
    }

    engineTrace(
      "pumps ended: reader \(reader.status.rawValue) \(describe(reader.error)), "
        + "writer \(writer.status.rawValue) \(describe(writer.error))")
    if isCancelled() {
      reader.cancelReading()
      writer.cancelWriting()
      throw EngineError(description: "Stopped")
    }
    if reader.status == .failed {
      writer.cancelWriting()
      throw reader.error ?? EngineError(description: "The video could not be read")
    }
    if writer.status == .failed {
      reader.cancelReading()
      throw writer.error ?? EngineError(description: "The video could not be written")
    }
    await writer.finishWriting()
    if isCancelled() {
      // Stopped after the last sample: no result is left either.
      try? FileManager.default.removeItem(at: out)
      throw EngineError(description: "Stopped")
    }
    if writer.status != .completed {
      reader.cancelReading()
      throw writer.error ?? EngineError(description: "The video could not be written")
    }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    return [
      "ms": Int(Date().timeIntervalSince(started) * 1000),
      "bytes": bytes,
      "mime": h264 ? "video/avc" : "video/hevc",
      "encoder": "AVAssetWriter",
    ]
  }

  // Resumes a continuation once, whoever asks first.
  private final class Once {
    private let lock = NSLock()
    private var done: CheckedContinuation<Void, Never>?

    init(_ done: CheckedContinuation<Void, Never>) { self.done = done }

    func resume() {
      lock.lock()
      let waiting = done
      done = nil
      lock.unlock()
      waiting?.resume()
    }
  }

  // Every sample of [output] into [input], as fast as the writer takes
  // them, until [stop] says Stop was pressed. A writer that failed, or one
  // waiting when Stop comes, may never ask for more: a watch on its state
  // and on [stop] ends the wait then. The reader is never cancelled here:
  // the caller does that once every pump has ended.
  private static func pump(
    _ output: AVAssetReaderOutput, into input: AVAssetWriterInput, writer: AVAssetWriter,
    queue: String, stop: @escaping () -> Bool, progress: ((Double) -> Void)? = nil
  ) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let done = Once(continuation)
      let serial = DispatchQueue(label: queue)
      var finished = false
      func watch() {
        serial.asyncAfter(deadline: .now() + 0.5) {
          if finished { return }
          if writer.status == .failed || writer.status == .cancelled || stop() {
            engineTrace("\(queue): watch ends it, writer \(writer.status.rawValue)")
            finished = true
            done.resume()
          } else {
            watch()
          }
        }
      }
      watch()
      input.requestMediaDataWhenReady(on: serial) {
        while input.isReadyForMoreMediaData {
          if finished { return }
          if stop() {
            finished = true
            done.resume()
            return
          }
          guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
            engineTrace("\(queue): no more samples, writer \(writer.status.rawValue)")
            finished = true
            input.markAsFinished()
            done.resume()
            return
          }
          progress?(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
      }
    }
  }
}

/// A video written from pictures the app draws (the Overlay Generator's
/// overlay alone, `docs/design/macos-remove-ffmpeg.md` step 4): each picture shown for
/// a number of frames, as ProRes 4444 with its transparency or as HEVC.
/// One at a time: opened, given its pictures in order, closed.
final class FrameWriter {
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var width = 0
  private var height = 0
  private var alpha = false
  private var timescale: Int32 = 30000
  private var frameTicks: Int64 = 1000
  private var written: Int64 = 0
  private var output: URL?
  private var cancelled = false

  func open(_ args: [String: Any]) throws {
    guard writer == nil else {
      throw EngineError(description: "Another video is being written")
    }
    guard let path = args["output"] as? String, let width = args["width"] as? Int,
      let height = args["height"] as? Int, width > 0, height > 0
    else {
      throw EngineError(description: "No output or size")
    }
    let fps = (args["fps"] as? NSNumber)?.doubleValue ?? 30
    let prores = args["codec"] as? String == "prores4444"
    let out = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: out)
    let writer = try AVAssetWriter(
      outputURL: out, fileType: out.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
    var settings: [String: Any] = [
      AVVideoCodecKey: prores ? AVVideoCodecType.proRes4444 : AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    if !prores, let quality = (args["quality"] as? NSNumber)?.doubleValue {
      settings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: quality]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw EngineError(description: "This kind of video cannot be written here")
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.startWriting() else {
      throw writer.error ?? EngineError(description: "The video could not be written")
    }
    writer.startSession(atSourceTime: .zero)
    // Whole ticks a frame at any rate: 29.97 is 30000 over 1001.
    timescale = Int32((fps * 1000).rounded())
    frameTicks = 1000
    written = 0
    cancelled = false
    alpha = prores
    self.width = width
    self.height = height
    self.writer = writer
    self.input = input
    self.adaptor = adaptor
    output = out
  }

  /// [rgba] (width by height, the alpha not multiplied in) for the next
  /// [count] frames.
  func add(_ rgba: Data, count: Int) async throws {
    guard let writer, let input, let adaptor, let pool = adaptor.pixelBufferPool else {
      throw EngineError(description: "No video is being written")
    }
    guard rgba.count == width * height * 4 else {
      throw EngineError(description: "A picture of the wrong size")
    }
    var made: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
    guard let buffer = made else {
      throw EngineError(description: "No room for a picture")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      rgba.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
        var from = vImage_Buffer(
          data: UnsafeMutableRawPointer(mutating: source.baseAddress!),
          height: vImagePixelCount(height), width: vImagePixelCount(width),
          rowBytes: width * 4)
        var to = vImage_Buffer(
          data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
          rowBytes: rowBytes)
        // RGBA to BGRA.
        let order: [UInt8] = [2, 1, 0, 3]
        vImagePermuteChannels_ARGB8888(&from, &to, order, vImage_Flags(kvImageNoFlags))
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    if alpha {
      CVBufferSetAttachment(
        buffer, kCVImageBufferAlphaChannelModeKey,
        kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
    }
    for _ in 0..<max(count, 0) {
      while !input.isReadyForMoreMediaData {
        if cancelled || writer.status != .writing {
          throw writer.error ?? EngineError(description: "Stopped")
        }
        try await Task.sleep(nanoseconds: 2_000_000)
      }
      if cancelled { throw EngineError(description: "Stopped") }
      let time = CMTime(value: written * frameTicks, timescale: timescale)
      guard adaptor.append(buffer, withPresentationTime: time) else {
        throw writer.error ?? EngineError(description: "The video could not be written")
      }
      written += 1
    }
  }

  func close() async throws {
    guard let writer, let input else {
      throw EngineError(description: "No video is being written")
    }
    defer { forget() }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: written * frameTicks, timescale: timescale))
    await writer.finishWriting()
    if writer.status != .completed {
      if let output { try? FileManager.default.removeItem(at: output) }
      throw writer.error ?? EngineError(description: "The video could not be written")
    }
  }

  /// Stops the video being written and removes what there is of it.
  func cancel() {
    cancelled = true
    writer?.cancelWriting()
    if let output { try? FileManager.default.removeItem(at: output) }
    forget()
  }

  private func forget() {
    writer = nil
    input = nil
    adaptor = nil
    output = nil
  }
}
