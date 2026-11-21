import Accelerate
import AVFoundation
import CoreImage
import Flutter
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    LibraryPicker.shared.sweep()
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UWMediaLibrary") {
      let channel = FlutterMethodChannel(
        name: "uwmedia/media_library", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in MediaLibrary.handle(call, result: result) }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UWMediaEngine") {
      let channel = FlutterMethodChannel(
        name: "uwmedia/media_engine", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        MediaEngine.shared.handle(call, result: result)
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UWMediaScreen") {
      let channel = FlutterMethodChannel(
        name: "uwmedia/screen", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "keepAwake" else {
          result(FlutterMethodNotImplemented)
          return
        }
        // The screen stays on during a run: a lock ends an export.
        UIApplication.shared.isIdleTimerDisabled = call.arguments as? Bool ?? false
        result(nil)
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UWMediaOpenedFiles") {
      OpenedFiles.shared.attach(registrar)
    }
  }
}

/// Dive logs opened with UWMedia or shared to it (spec §12.3 step 1): each
/// file copied into a folder of its own in the app's temporary folder (and
/// the copy iOS left in Documents/Inbox removed), the copies waiting until
/// the app takes them ("take"), and their folder removed once the app has
/// kept them ("done").
final class OpenedFiles: NSObject, FlutterSceneLifeCycleDelegate {
  static let shared = OpenedFiles()

  private var pending: [String] = []
  private var channel: FlutterMethodChannel?
  private let folder = FileManager.default.temporaryDirectory
    .appendingPathComponent("opened", isDirectory: true)

  func attach(_ registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "uwmedia/opened_files", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "take":
        result(self.pending)
        self.pending = []
      case "done":
        for path in call.arguments as? [String] ?? [] {
          self.release(path)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    registrar.addSceneDelegate(self)
  }

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts, !contexts.isEmpty else {
      return false
    }
    receive(contexts.map(\.url))
    return true
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    receive(URLContexts.map(\.url))
    return true
  }

  private func receive(_ urls: [URL]) {
    let target = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let files = FileManager.default
    try? files.createDirectory(at: target, withIntermediateDirectories: true)
    for url in urls where url.isFileURL {
      let scoped = url.startAccessingSecurityScopedResource()
      defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
      }
      let copy = target.appendingPathComponent(url.lastPathComponent)
      do {
        try files.copyItem(at: url, to: copy)
        pending.append(copy.path)
      } catch {
        NSLog("UWMedia: could not copy the opened file \(url): \(error)")
      }
      if url.path.contains("/Documents/Inbox/") {
        try? files.removeItem(at: url)
      }
    }
    channel?.invokeMethod("available", arguments: nil)
  }

  // A copy and, once it is empty, its folder; nothing outside them.
  private func release(_ path: String) {
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let parent = file.deletingLastPathComponent()
    guard parent.deletingLastPathComponent().path == folder.resolvingSymlinksInPath().path
    else {
      return
    }
    let files = FileManager.default
    try? files.removeItem(at: file)
    if (try? files.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
      try? files.removeItem(at: parent)
    }
  }
}

/// The photo library on iOS: a corrected copy added to an album of its
/// own (made when there is none of that name).
enum MediaLibrary {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "pick" {
      let args = call.arguments as? [String: Any] ?? [:]
      LibraryPicker.shared.pick(
        photos: args["photos"] as? Bool ?? true,
        videos: args["videos"] as? Bool ?? true,
        multiple: args["multiple"] as? Bool ?? true,
        result: result)
      return
    }
    if call.method == "pickFolder" {
      FolderPicker.shared.pick(result: result)
      return
    }
    if call.method == "albums" {
      // The user's own albums by name, to choose one to save into; none
      // without full access (Photos then shows an app no album).
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
    if call.method == "saveToFolder" {
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        let bookmark = Data(base64Encoded: args["bookmark"] as? String ?? "")
      else {
        result(FlutterError(code: "folder", message: "No folder to save into", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let failure = ResultFolder.save(path, bookmark: bookmark)
        DispatchQueue.main.async {
          if let failure {
            result(FlutterError(code: "folder", message: failure, details: nil))
          } else {
            result(nil)
          }
        }
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
    saveToAlbum(path, album: album) { inAlbum, error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "library", message: "\(error)", details: nil))
        } else {
          result(inAlbum)
        }
      }
    }
  }

  struct LibraryError: Error, CustomStringConvertible {
    let description: String
  }

  /// The file at [path] saved into the library, in the album [album] when
  /// Photos lets the app have albums: `done` is told whether it went into
  /// the album. With access to chosen photos only, or to add only, Photos
  /// lets an app neither see nor make an album, and the file is then saved
  /// into the library alone (owner, 2026-11-17: saving into Photos gave
  /// nothing where saving into a folder worked).
  static func saveToAlbum(
    _ path: String, album: String, done: @escaping (Bool, Error?) -> Void
  ) {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      guard status == .authorized || status == .limited else {
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized {
          add(path, album: nil) { done(false, $0) }
        } else {
          done(
            false,
            LibraryError(
              description: "No access to Photos. Allow it under Settings, Apps, UWMedia, Photos"))
        }
        return
      }
      add(path, album: album) { error in
        guard error != nil else {
          done(true, nil)
          return
        }
        // The album was the trouble when the file alone is taken; else
        // the file was, and this says why.
        add(path, album: nil) { done(false, $0) }
      }
    }
  }

  /// The file added to the library, and to [album] (made when there is
  /// none of that name) when one is given.
  private static func add(_ path: String, album: String?, done: @escaping (Error?) -> Void) {
    var existing: PHAssetCollection?
    if let album {
      let options = PHFetchOptions()
      options.predicate = NSPredicate(format: "title = %@", album)
      existing =
        PHAssetCollection.fetchAssetCollections(
          with: .album, subtype: .any, options: options
        ).firstObject
    }
    // Set when the library would not take the file: the change then
    // "succeeds" with nothing added, which is no success.
    var refused = false
    PHPhotoLibrary.shared().performChanges({
      let url = URL(fileURLWithPath: path)
      let photo = ["jpg", "jpeg", "heic", "heif", "png"].contains(
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
      guard let album else { return }
      if let existing {
        PHAssetCollectionChangeRequest(for: existing)?.addAssets([placeholder] as NSArray)
      } else {
        PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
          .addAssets([placeholder] as NSArray)
      }
    }) { _, error in
      done(error ?? (refused ? LibraryError(description: "The library refused the file") : nil))
    }
  }
}

/// A folder of the phone's files that results are saved into (owner,
/// 2026-11-16): the app reaches it only through the leave the document
/// picker gave, kept as a bookmark.
enum ResultFolder {
  /// The file at [path] copied into the bookmarked folder under its own
  /// name, numbered when the folder has one of that name; what went wrong,
  /// or nil.
  static func save(_ path: String, bookmark: Data) -> String? {
    var stale = false
    guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    else {
      return "The folder is no longer there. Choose it again."
    }
    guard folder.startAccessingSecurityScopedResource() else {
      return "The folder can no longer be written to. Choose it again."
    }
    defer { folder.stopAccessingSecurityScopedResource() }
    let source = URL(fileURLWithPath: path)
    var failure: String?
    var coordination: NSError?
    // Coordinated, so that iCloud Drive and other providers see the file.
    NSFileCoordinator().coordinate(
      writingItemAt: folder, options: .forMerging, error: &coordination
    ) { folder in
      let name = source.deletingPathExtension().lastPathComponent
      let kind = source.pathExtension
      var target = folder.appendingPathComponent(source.lastPathComponent)
      var number = 1
      while FileManager.default.fileExists(atPath: target.path) {
        target = folder.appendingPathComponent("\(name)_\(number).\(kind)")
        number += 1
      }
      do {
        try FileManager.default.copyItem(at: source, to: target)
      } catch {
        failure = error.localizedDescription
      }
    }
    return failure ?? coordination?.localizedDescription
  }
}

/// The system's picker for a folder; answers its name and a bookmark of
/// it (base64), or nil when none was picked.
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
  static let shared = FolderPicker()

  private var result: FlutterResult?

  func pick(result: @escaping FlutterResult) {
    guard self.result == nil, let presenter = LibraryPicker.presenter() else {
      result(FlutterError(code: "folder", message: "The picker cannot be shown", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    self.result = result
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    let result = self.result
    self.result = nil
    guard let folder = urls.first else {
      result?(nil)
      return
    }
    guard folder.startAccessingSecurityScopedResource() else {
      result?(FlutterError(code: "folder", message: "No access to the folder", details: nil))
      return
    }
    defer { folder.stopAccessingSecurityScopedResource() }
    do {
      let bookmark = try folder.bookmarkData()
      result?(["name": folder.lastPathComponent, "bookmark": bookmark.base64EncodedString()])
    } catch {
      result?(FlutterError(code: "folder", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    result?(nil)
    result = nil
  }
}

/// Photos and videos picked from the library as the files they are: the
/// library's own bytes under the file's own name (an HEIC stays an HEIC,
/// nothing is encoded again), each copied into a folder of its own in the
/// app's temporary folder.
final class LibraryPicker: NSObject, PHPickerViewControllerDelegate {
  static let shared = LibraryPicker()

  private var result: FlutterResult?
  private let folder = FileManager.default.temporaryDirectory
    .appendingPathComponent("picked", isDirectory: true)

  /// The copies of earlier sessions removed (at the app's start: the
  /// pages have none of them open then).
  func sweep() {
    try? FileManager.default.removeItem(at: folder)
  }

  func pick(photos: Bool, videos: Bool, multiple: Bool, result: @escaping FlutterResult) {
    guard self.result == nil, let presenter = LibraryPicker.presenter() else {
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
    self.result = result
    presenter.present(picker, animated: true)
  }

  static func presenter() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = self.result else { return }
    self.result = nil
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
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
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
    }
    group.notify(queue: .main) {
      let loaded = paths.compactMap { $0 }
      if loaded.count < results.count {
        // Nothing is handed over half: the user picks again.
        try? FileManager.default.removeItem(at: target)
        result(
          FlutterError(
            code: "library",
            message: "\(results.count - loaded.count) of \(results.count) could not be read "
              + "from the library (not yet downloaded from iCloud?)",
            details: nil))
        return
      }
      result(loaded)
    }
  }
}
