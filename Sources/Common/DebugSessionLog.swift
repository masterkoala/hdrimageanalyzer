import Foundation

/// Writes one NDJSON line to the debug session log (agent instrumentation). Session ID 5e6f05.
public func debugSessionLog(location: String, message: String, data: [String: Any] = [:], hypothesisId: String = "") {
    // #region agent log
    let path = "/Users/dogusozel/HDRImageAnalyzerPro/.cursor/debug-5e6f05.log"
    var payload: [String: Any] = [
        "sessionId": "5e6f05",
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        "location": location,
        "message": message,
        "data": data
    ]
    if !hypothesisId.isEmpty { payload["hypothesisId"] = hypothesisId }
    guard let json = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: json, encoding: .utf8) else { return }
    let lineData = (line + "\n").data(using: .utf8)!
    if FileManager.default.fileExists(atPath: path) {
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(lineData)
        handle.closeFile()
    } else {
        try? lineData.write(to: URL(fileURLWithPath: path))
    }
    // #endregion
}
