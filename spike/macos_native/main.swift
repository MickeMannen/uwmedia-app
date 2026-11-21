// A command-line front to the iOS media engine built for macOS, for
// timing it against ffmpeg (docs/macos-remove-ffmpeg.md).
//
//   uwbench probe <in>
//   uwbench frame <in> <seconds> <maxWidth> <maxHeight>
//   uwbench passthrough <in> <out>
//   uwbench encode <in> <out> [--bitrate N] [--codec h264] [--fit WxH]
//       [--crop x,y,w,h] [--luts file --lutCount n --lutStep s --lutFade s]
//       [--layer x,y,folder,secondsPerPicture]
import AVFoundation
import Foundation

let argv = CommandLine.arguments
func fail(_ text: String) -> Never {
  FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
  exit(2)
}
guard argv.count >= 3 else { fail("usage: uwbench probe|frame|passthrough|encode ...") }
let mode = argv[1]
let started = Date()

func finish(_ value: Any?) {
  let ms = Int(Date().timeIntervalSince(started) * 1000)
  if let error = value as? FlutterError {
    fail("engine error (\(error.code)): \(error.message ?? "")")
  }
  var shown: [String: Any] = ["wallMs": ms]
  if let map = value as? [String: Any?] {
    for (key, item) in map {
      if let data = item as? FlutterStandardTypedData {
        shown[key] = "\(data.data.count) bytes"
      } else if let item {
        shown[key] = item
      }
    }
  }
  let json = try! JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys])
  print(String(data: json, encoding: .utf8)!)
  exit(0)
}

func option(_ name: String) -> String? {
  guard let at = argv.firstIndex(of: name), at + 1 < argv.count else { return nil }
  return argv[at + 1]
}

switch mode {
case "probe":
  MediaEngine.shared.handle(
    FlutterMethodCall(method: "probe", arguments: ["path": argv[2]]), result: finish)
case "frame":
  guard argv.count >= 6 else { fail("frame <in> <seconds> <maxWidth> <maxHeight>") }
  MediaEngine.shared.handle(
    FlutterMethodCall(
      method: "frameAt",
      arguments: [
        "path": argv[2], "seconds": Double(argv[3])!, "maxWidth": Int(argv[4])!,
        "maxHeight": Int(argv[5])!, "exact": true,
      ]), result: finish)
case "passthrough":
  // The streams copied as they are (the desktop's `-c copy`): what the
  // system's own export does without an encode.
  guard argv.count >= 4 else { fail("passthrough <in> <out>") }
  let out = URL(fileURLWithPath: argv[3])
  try? FileManager.default.removeItem(at: out)
  let asset = AVURLAsset(url: URL(fileURLWithPath: argv[2]))
  guard
    let export = AVAssetExportSession(
      asset: asset, presetName: AVAssetExportPresetPassthrough)
  else { fail("no passthrough export") }
  export.outputURL = out
  export.outputFileType = out.pathExtension.lowercased() == "mov" ? .mov : .mp4
  export.exportAsynchronously {
    if export.status == .completed {
      let bytes =
        (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
      DispatchQueue.main.async { finish(["bytes": bytes] as [String: Any?]) }
    } else {
      fail("passthrough failed: \(String(describing: export.error))")
    }
  }
case "encode":
  guard argv.count >= 4 else { fail("encode <in> <out> ...") }
  var args: [String: Any] = ["input": argv[2], "output": argv[3]]
  if let bitrate = option("--bitrate") { args["bitrate"] = Int(bitrate)! }
  if let codec = option("--codec") { args["codec"] = codec }
  if let fit = option("--fit") {
    let parts = fit.split(separator: "x").map { Int($0)! }
    args["width"] = parts[0]
    args["height"] = parts[1]
  }
  if let crop = option("--crop") {
    let parts = crop.split(separator: ",").map { Double($0)! }
    args["crop"] = ["x": parts[0], "y": parts[1], "width": parts[2], "height": parts[3]]
  }
  if let file = option("--luts") {
    // LUTs of 64³ colours of three bytes, one after the other.
    let all = try! Data(contentsOf: URL(fileURLWithPath: file))
    let count = Int(option("--lutCount") ?? "1")!
    let step = Double(option("--lutStep") ?? "2")!
    let size = all.count / count
    args["lutSize"] = 64
    args["lutFade"] = Double(option("--lutFade") ?? "0")!
    args["luts"] = (0..<count).map { index -> [String: Any] in
      [
        "seconds": Double(index) * step,
        "lut": FlutterStandardTypedData(
          bytes: all.subdata(in: (index * size)..<((index + 1) * size))),
      ]
    }
  }
  var layers: [[String: Any]] = []
  var at = 0
  while at < argv.count {
    if argv[at] == "--layer", at + 1 < argv.count {
      let parts = argv[at + 1].split(separator: ",", maxSplits: 3).map(String.init)
      let folder = parts[2]
      let every = Double(parts[3])!
      let names = (try! FileManager.default.contentsOfDirectory(atPath: folder))
        .filter { $0.hasSuffix(".png") }.sorted()
      layers.append([
        "x": Double(parts[0])!, "y": Double(parts[1])!,
        "pictures": names.enumerated().map { index, name -> [String: Any] in
          ["seconds": Double(index) * every, "path": folder + "/" + name]
        },
      ])
    }
    at += 1
  }
  if !layers.isEmpty { args["layers"] = layers }
  MediaEngine.shared.handle(FlutterMethodCall(method: "encode", arguments: args), result: finish)
default:
  fail("unknown mode \(mode)")
}
dispatchMain()
