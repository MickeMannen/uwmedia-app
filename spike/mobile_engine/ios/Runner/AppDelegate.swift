import AVFoundation
import CoreImage
import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let engine = SpikeEngine()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpikeEngine") {
      let channel = FlutterMethodChannel(
        name: "uwmedia.spike/engine", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [engine] call, result in engine.handle(call, result: result) }
    }
  }
}

struct SpikeError: Error, CustomStringConvertible {
  let description: String
}

/// The spike's media engine on iOS: AVFoundation and Core Image.
final class SpikeEngine {
  private let context = CIContext()

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    let fail: (Error) -> Void = { error in
      DispatchQueue.main.async {
        result(FlutterError(code: "engine", message: "\(error)", details: nil))
      }
    }
    switch call.method {
    case "deviceInfo":
      result([
        "model": SpikeEngine.machine(),
        "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
      ])
    case "videoInfo":
      Task {
        do { reply(try await self.videoInfo(args["path"] as! String)) } catch { fail(error) }
      }
    case "frameAt":
      Task {
        do {
          let png = try await self.frameAt(
            args["path"] as! String, seconds: args["seconds"] as? Double ?? 0)
          reply(FlutterStandardTypedData(bytes: png))
        } catch { fail(error) }
      }
    case "transcode":
      Task {
        do { reply(try await self.transcode(args)) } catch { fail(error) }
      }
    case "saveToAlbum":
      saveToAlbum(args["path"] as! String, album: args["album"] as! String) { error in
        if let error { fail(error) } else { reply(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// "iPhone18,2": the model as the system names it.
  static func machine() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
  }

  private func videoInfo(_ path: String) async throws -> [String: Any?] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw SpikeError(description: "No video track")
    }
    let (size, transform, fps, formats) = try await track.load(
      .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
    let shown = size.applying(transform)
    let duration = try await asset.load(.duration)
    var codec = "?"
    if let format = formats.first {
      let type = CMFormatDescriptionGetMediaSubType(format)
      codec = String(
        [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((type >> $0) & 0xFF))) })
    }
    return [
      "width": Int(abs(shown.width)),
      "height": Int(abs(shown.height)),
      "durationMs": Int(duration.seconds * 1000),
      "fps": Double(fps),
      "mime": codec,
    ]
  }

  private func frameAt(_ path: String, seconds: Double) async throws -> Data {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1920, height: 1920)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let (image, _) = try await generator.image(
      at: CMTime(seconds: seconds, preferredTimescale: 600))
    guard let png = UIImage(cgImage: image).pngData() else {
      throw SpikeError(description: "Could not encode the frame")
    }
    return png
  }

  private func transcode(_ args: [String: Any]) async throws -> [String: Any] {
    let source = URL(fileURLWithPath: args["path"] as! String)
    let out = URL(fileURLWithPath: args["out"] as! String)
    try? FileManager.default.removeItem(at: out)
    let asset = AVURLAsset(url: source)

    var lutFilter: CIFilter?
    if let lut = args["lut"] as? FlutterStandardTypedData, let size = args["lutSize"] as? Int {
      // The app's LUT (bytes, red changing fastest) as Core Image's cube:
      // RGBA floats in the same order, applied in sRGB as ffmpeg does.
      var cube = [Float](repeating: 1, count: size * size * size * 4)
      let bytes = [UInt8](lut.data)
      for i in 0..<(size * size * size) {
        cube[i * 4] = Float(bytes[i * 3]) / 255
        cube[i * 4 + 1] = Float(bytes[i * 3 + 1]) / 255
        cube[i * 4 + 2] = Float(bytes[i * 3 + 2]) / 255
      }
      let filter = CIFilter(name: "CIColorCubeWithColorSpace")!
      filter.setValue(size, forKey: "inputCubeDimension")
      filter.setValue(cube.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
      filter.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
      lutFilter = filter
    }

    let overlayDir = args["overlayDir"] as? String
    let overlayCount = args["overlayCount"] as? Int ?? 0
    let overlayX = args["overlayX"] as? Double ?? 0.04
    let overlayY = args["overlayY"] as? Double ?? 0.04
    var overlays: [Int: CIImage] = [:]

    var composition: AVVideoComposition?
    if lutFilter != nil || overlayDir != nil {
      composition = try await AVMutableVideoComposition.videoComposition(
        with: asset,
        applyingCIFiltersWithHandler: { request in
          var image = request.sourceImage
          if let filter = lutFilter {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = filter.outputImage ?? image
          }
          if let dir = overlayDir, overlayCount > 0 {
            let index = min(max(Int(request.compositionTime.seconds), 0), overlayCount - 1)
            var picture = overlays[index]
            if picture == nil {
              let file = URL(fileURLWithPath: dir)
                .appendingPathComponent(String(format: "o_%05d.png", index))
              picture = CIImage(contentsOf: file)
              overlays = [index: picture!]
            }
            if let picture {
              // Core Image's origin is the bottom left: the overlay there,
              // moved in by a share of the frame.
              let frame = request.renderSize
              let placed = picture.transformed(
                by: CGAffineTransform(
                  translationX: frame.width * overlayX, y: frame.height * overlayY))
              image = placed.composited(over: image)
            }
          }
          request.finish(with: image, context: nil)
        })
    }

    let downscale = args["height"] as? Int != nil
    let preset = downscale ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHEVCHighestQuality
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw SpikeError(description: "No export session for \(preset)")
    }
    session.videoComposition = composition
    let started = Date()
    try await session.export(to: out, as: .mp4)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    return [
      "ms": Int(Date().timeIntervalSince(started) * 1000),
      "bytes": bytes,
      "mime": preset,
    ]
  }

  private func saveToAlbum(_ path: String, album: String, done: @escaping (Error?) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      guard status == .authorized || status == .limited else {
        done(SpikeError(description: "No access to the photo library (\(status.rawValue))"))
        return
      }
      let options = PHFetchOptions()
      options.predicate = NSPredicate(format: "title = %@", album)
      let existing = PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: .any, options: options
      ).firstObject
      PHPhotoLibrary.shared().performChanges({
        let url = URL(fileURLWithPath: path)
        let photo = ["jpg", "jpeg", "heic", "heif", "png"].contains(
          url.pathExtension.lowercased())
        guard
          let created = photo
            ? PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            : PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url),
          let placeholder = created.placeholderForCreatedAsset
        else { return }
        if let existing {
          PHAssetCollectionChangeRequest(for: existing)?.addAssets([placeholder] as NSArray)
        } else {
          PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
            .addAssets([placeholder] as NSArray)
        }
      }) { _, error in done(error) }
    }
  }
}
