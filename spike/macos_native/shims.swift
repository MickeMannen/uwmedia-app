// Stand-ins for the Flutter types the Apple runners' engine names, so
// that its source (apple/MediaEngine.swift) compiles as a command-line
// tool as it is.
import Foundation

typealias FlutterResult = (Any?) -> Void

final class FlutterMethodCall {
  let method: String
  let arguments: Any?
  init(method: String, arguments: Any?) {
    self.method = method
    self.arguments = arguments
  }
}

final class FlutterStandardTypedData {
  let data: Data
  init(bytes: Data) { data = bytes }
}

struct FlutterError {
  let code: String
  let message: String?
  let details: Any?
}

let FlutterMethodNotImplemented: Any = "notImplemented"
