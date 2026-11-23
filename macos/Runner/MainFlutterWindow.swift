import Cocoa
import FlutterMacOS
import Photos
import PhotosUI
import UniformTypeIdentifiers
import window_manager

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Apple Photos as a source and a destination (spec §10.50): the same
    // channel as the phones' library.
    LibraryPicker.shared.sweep()
    let library = FlutterMethodChannel(
      name: "uwmedia/media_library",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    LibraryPicker.shared.channel = library
    library.setMethodCallHandler { [weak flutterViewController] call, result in
      MediaLibrary.handle(call, presenter: flutterViewController, result: result)
    }

    // The picks of a sandboxed app (the Mac App Store build), kept as
    // security-scoped bookmarks and opened again at the next start
    // (lib/engine/file_picks.dart).
    let access = FlutterMethodChannel(
      name: "uwmedia/file_access",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    access.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "bookmark":
        guard let path = args["path"] as? String else {
          result(FlutterError(code: "access", message: "No path", details: nil))
          return
        }
        do {
          let data = try URL(fileURLWithPath: path).bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
          result(FlutterStandardTypedData(bytes: data))
        } catch {
          result(FlutterError(code: "access", message: "\(error)", details: nil))
        }
      case "resolve":
        guard let bookmark = args["bookmark"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "access", message: "No bookmark", details: nil))
          return
        }
        do {
          var stale = false
          let url = try URL(
            resolvingBookmarkData: bookmark.data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale)
          // Held for as long as the app runs.
          guard url.startAccessingSecurityScopedResource() else {
            result(FlutterError(code: "access", message: "No access", details: nil))
            return
          }
          var answer: [String: Any] = ["path": url.path]
          if stale,
            let fresh = try? url.bookmarkData(
              options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
          {
            answer["fresh"] = FlutterStandardTypedData(bytes: fresh)
          }
          result(answer)
        } catch {
          result(FlutterError(code: "access", message: "\(error)", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // The media engine the phones have, beside ffmpeg
    // (docs/design/macos-remove-ffmpeg.md): the same channel as theirs.
    let engine = FlutterMethodChannel(
      name: "uwmedia/media_engine",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    engine.setMethodCallHandler { call, result in
      MediaEngine.shared.handle(call, result: result)
    }

    // A run of the app (lib/engine/keep_awake.dart, the channel the
    // phones keep their screen on by): see RunActivity.
    let screen = FlutterMethodChannel(
      name: "uwmedia/screen",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    screen.setMethodCallHandler { call, result in
      guard call.method == "keepAwake" else {
        result(FlutterMethodNotImplemented)
        return
      }
      RunActivity.hold(call.arguments as? Bool ?? false)
      result(nil)
    }

    super.awakeFromNib()
  }

  // Hidden until the app has placed it where the last run left it
  // (window_manager; lib/engine/desktop/desktop_window.dart shows it).
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}

/// A run going on in the app (spec §10.98). A Mac slows an app that is
/// behind other windows (App Nap): the app's own share of a run, the
/// overlay pictures it draws and the files it writes, then took up to
/// five times as long. While a run is held the app is not slowed and the
/// Mac does not go to sleep of itself. Counted, so that a run that ends
/// does not let go of another's.
enum RunActivity {
  private static var held: NSObjectProtocol?
  private static var runs = 0

  static func hold(_ on: Bool) {
    runs = max(0, runs + (on ? 1 : -1))
    if runs > 0, held == nil {
      held = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled], reason: "A run in UWMedia")
    } else if runs == 0, let activity = held {
      ProcessInfo.processInfo.endActivity(activity)
      held = nil
    }
  }
}

/// Apple Photos on macOS: a file added to an album of its own (made when
/// there is none of that name), as on iOS.
enum MediaLibrary {
  static func handle(
    _ call: FlutterMethodCall, presenter: NSViewController?, result: @escaping FlutterResult
  ) {
    if call.method == "pick" {
      let args = call.arguments as? [String: Any] ?? [:]
      LibraryPicker.shared.pick(
        photos: args["photos"] as? Bool ?? true,
        videos: args["videos"] as? Bool ?? true,
        multiple: args["multiple"] as? Bool ?? true,
        presenter: presenter,
        result: result)
      return
    }
    if call.method == "cancelPick" {
      if #available(macOS 13.0, *) {
        LibraryPicker.shared.cancel()
      }
      result(nil)
      return
    }
    if call.method == "albums" {
      // The user's own albums by name, to choose one to save into; none
      // without full access.
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
        var titles: [String] = []
        if status == .authorized {
          PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
          ).enumerateObjects { album, _, _ in
            if let title = album.localizedTitle, !title.isEmpty {
              titles.append(title)
            }
          }
        }
        titles.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        DispatchQueue.main.async { result(titles) }
      }
      return
    }
    guard call.method == "saveToAlbum",
      let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      let album = args["album"] as? String
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    saveToAlbum(path, album: album) { error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "library", message: "\(error)", details: nil))
        } else {
          result(nil)
        }
      }
    }
  }

  struct LibraryError: Error, CustomStringConvertible {
    let description: String
  }

  static func saveToAlbum(_ path: String, album: String, done: @escaping (Error?) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      guard status == .authorized || status == .limited else {
        done(
          LibraryError(
            description: "No access to Photos (System Settings, Privacy & Security, Photos)"))
        return
      }
      let options = PHFetchOptions()
      options.predicate = NSPredicate(format: "title = %@", album)
      let existing = PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: .any, options: options
      ).firstObject
      // Set when the library would not take the file: the change then
      // "succeeds" with nothing added, which is no success.
      var refused = false
      PHPhotoLibrary.shared().performChanges({
        let url = URL(fileURLWithPath: path)
        let photo = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"].contains(
          url.pathExtension.lowercased())
        guard
          let created = photo
            ? PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            : PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url),
          let placeholder = created.placeholderForCreatedAsset
        else {
          refused = true
          return
        }
        if let existing {
          PHAssetCollectionChangeRequest(for: existing)?.addAssets([placeholder] as NSArray)
        } else {
          PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
            .addAssets([placeholder] as NSArray)
        }
      }) { _, error in
        done(error ?? (refused ? LibraryError(description: "Photos refused the file") : nil))
      }
    }
  }
}

/// Photos and videos picked in the system's picker as the files they are
/// (the library's own bytes under the file's own name), each pick copied
/// into a folder of its own in the app's temporary folder. The picker
/// asks for no access to the library. It needs macOS 13.
///
/// The picker's window closes when "Add" is pressed, and the page says
/// that the files are being fetched ("fetching", with how many, over the
/// channel). The picker and its window are kept until the files are
/// copied: the files are handed over by the picker's own process, which
/// ends with the picker.
final class LibraryPicker: NSObject {
  static let shared = LibraryPicker()

  private var result: FlutterResult?
  /// Tells the page that picked files are being fetched.
  var channel: FlutterMethodChannel?

  // The window the picker is shown in, and the picker while its files
  // are being copied.
  private var sheet: NSWindow?
  private var loading: NSViewController?
  // The copying under way, to end it when the fetch is cancelled.
  private var copying: [Progress] = []
  private let folder = FileManager.default.temporaryDirectory
    .appendingPathComponent("uwmedia_photos_picked", isDirectory: true)

  /// The copies of earlier sessions removed (at the app's start: the
  /// pages have none of them open then).
  func sweep() {
    try? FileManager.default.removeItem(at: folder)
  }

  func pick(
    photos: Bool, videos: Bool, multiple: Bool, presenter: NSViewController?,
    result: @escaping FlutterResult
  ) {
    guard #available(macOS 13.0, *) else {
      result(
        FlutterError(
          code: "library", message: "Picking from Photos needs macOS 13 or later", details: nil))
      return
    }
    guard self.result == nil, let presenter else {
      result(FlutterError(code: "library", message: "The picker cannot be shown", details: nil))
      return
    }
    var configuration = PHPickerConfiguration()
    configuration.selectionLimit = multiple ? 0 : 1
    // The file as the library has it, not a compatible copy of it.
    configuration.preferredAssetRepresentationMode = .current
    if photos && !videos {
      configuration.filter = .images
    } else if videos && !photos {
      configuration.filter = .videos
    }
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    // In a window of the app's own, shown as a sheet: presented as a
    // sheet itself the picker asks for no size and opens as a strip with
    // no pictures in it, whatever size it is told to prefer (owner,
    // 2026-11-17).
    guard let parent = presenter.view.window else {
      result(FlutterError(code: "library", message: "The picker cannot be shown", details: nil))
      return
    }
    let room = parent.frame.size
    let size = NSSize(
      width: max(640, min(1000, room.width - 80)),
      height: max(480, min(720, room.height - 80)))
    let sheet = NSWindow(contentViewController: picker)
    sheet.styleMask = [.titled, .resizable]
    sheet.contentMinSize = NSSize(width: 640, height: 480)
    sheet.setContentSize(size)
    self.sheet = sheet
    self.result = result
    parent.beginSheet(sheet)
  }
}

@available(macOS 13.0, *)
extension LibraryPicker: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard let result = self.result else { return }
    guard !results.isEmpty, loading == nil else {
      close()
      result([String]())
      return
    }
    // Out of the way, and kept (see above).
    hide()
    loading = picker
    channel?.invokeMethod("fetching", arguments: results.count)
    let target = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    var paths = [String?](repeating: nil, count: results.count)
    let lock = NSLock()
    let group = DispatchGroup()
    for (index, picked) in results.enumerated() {
      let provider = picked.itemProvider
      // The picture first, so that a Live Photo is given as its photo
      // (never as the bundle of photo and film), else the film.
      let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
      let type =
        types.first(where: { $0.conforms(to: .image) && !$0.conforms(to: .livePhoto) })
        ?? types.first(where: { $0.conforms(to: .movie) })
      guard let type else { continue }
      group.enter()
      let progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) {
        url, _ in
        defer { group.leave() }
        // The file is gone when this returns: copied now.
        guard let url else { return }
        // The library's name for it, with the file's own extension.
        var name = url.lastPathComponent
        if let suggested = provider.suggestedName.map({
          URL(fileURLWithPath: $0).lastPathComponent
        }), !suggested.isEmpty, suggested != ".", suggested != ".." {
          let ext = url.pathExtension
          name =
            ext.isEmpty || suggested.lowercased().hasSuffix(".\(ext.lowercased())")
            ? suggested : "\(suggested).\(ext)"
        }
        var copy = target.appendingPathComponent(name)
        lock.lock()
        if FileManager.default.fileExists(atPath: copy.path) {
          copy = target.appendingPathComponent(
            "\(copy.deletingPathExtension().lastPathComponent)_\(index).\(copy.pathExtension)")
        }
        let copied = (try? FileManager.default.copyItem(at: url, to: copy)) != nil
        if copied {
          paths[index] = copy.path
        }
        lock.unlock()
      }
      copying.append(progress)
    }
    group.notify(queue: .main) {
      // Given up meanwhile: the copies are of no use.
      guard self.loading === picker else {
        try? FileManager.default.removeItem(at: target)
        return
      }
      self.close()
      let loaded = paths.compactMap { $0 }
      if loaded.count < results.count {
        // Nothing is handed over half: the user picks again.
        try? FileManager.default.removeItem(at: target)
        result(
          FlutterError(
            code: "library",
            message: "\(results.count - loaded.count) of \(results.count) could not be read "
              + "from Photos (not yet downloaded from iCloud?)",
            details: nil))
        return
      }
      result(loaded)
    }
  }

  /// The files of a pick are no longer wanted (Cancel on the page): the
  /// copying ends and the pick gives nothing.
  func cancel() {
    guard loading != nil, let result = self.result else { return }
    copying.forEach { $0.cancel() }
    // What was copied already is removed when the copying has ended, or
    // with the folder at the next start.
    close()
    result([String]())
  }

  private func hide() {
    if let sheet, let parent = sheet.sheetParent {
      parent.endSheet(sheet)
    }
  }

  private func close() {
    hide()
    sheet = nil
    loading = nil
    copying = []
    result = nil
  }
}
