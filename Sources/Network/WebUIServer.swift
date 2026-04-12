// Web UI single-page app and layout API (Phase 9, NET-005, NET-006, NET-007, NET-010).
// Serves the scope layout control SPA, GET/POST /api/layout, GET /api/scope/jpeg (scope stream),
// GET/POST /api/input (input source), GET/POST /api/colorspace (colorspace selection),
// and NET-010: POST /api/auth/login with session cookie for authentication.

import Foundation

// MARK: - NET-010: Web UI authentication (session-based)

private let webAuthLock = NSLock()
private var _webAuthPassword: String? = "hdranalyzer"  // default; set to nil or "" to disable auth
private var _webAuthSessions: Set<String> = []         // valid session tokens

/// Set the password required for web UI access (NET-010). Pass nil or empty to disable authentication.
public func setWebUIAuthPassword(_ password: String?) {
    webAuthLock.lock()
    _webAuthPassword = (password?.isEmpty == true) ? nil : password
    _webAuthSessions.removeAll()
    webAuthLock.unlock()
}

/// Returns true if web UI authentication is enabled.
public func isWebUIAuthEnabled() -> Bool {
    webAuthLock.lock()
    let enabled = _webAuthPassword != nil
    webAuthLock.unlock()
    return enabled
}

private func webAuthCreateSession() -> String {
    let token = UUID().uuidString
    webAuthLock.lock()
    _webAuthSessions.insert(token)
    webAuthLock.unlock()
    return token
}

private func webAuthValidateToken(_ token: String) -> Bool {
    webAuthLock.lock()
    let valid = _webAuthSessions.contains(token)
    webAuthLock.unlock()
    return valid
}

private func webAuthExtractToken(from request: HTTPRequest) -> String? {
    if let cookie = request.headers["cookie"] {
        let parts = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            if part.hasPrefix("session=") {
                let value = String(part.dropFirst("session=".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
                break
            }
        }
    }
    if let auth = request.headers["authorization"], auth.hasPrefix("Bearer ") {
        return String(auth.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

private func webAuthRequiresAuth(path: String, method: String) -> Bool {
    if path == "/health" { return false }
    if path == "/" || path == "/index.html" { return false }
    if path == "/api/auth/login" && method == "POST" { return false }
    return true
}

/// Provider for scope display JPEG stream (NET-006). Set by app when pipeline is available; returns nil if no frame.
private let scopeStreamProviderLock = NSLock()
private var _scopeStreamProvider: (() -> Data?)?

/// Scope layout state for the four quadrants. Raw values match HDRUI.QuadrantContent.
private let defaultScopeIds = ["Video", "Waveform", "Histogram", "Vectorscope"]
private let validScopeIds = Set(["Video", "Waveform", "Vectorscope", "Histogram", "RGB Parade", "CIE xy"])

/// In-memory layout state (quadrant index 1...4 -> scope id). Thread-safe.
private final class WebUILayoutState {
    private let lock = NSLock()
    private var storage: [Int: String] = [1: "Video", 2: "Waveform", 3: "Histogram", 4: "Vectorscope"]

    func get() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "quadrant1": storage[1] ?? defaultScopeIds[0],
            "quadrant2": storage[2] ?? defaultScopeIds[1],
            "quadrant3": storage[3] ?? defaultScopeIds[2],
            "quadrant4": storage[4] ?? defaultScopeIds[3]
        ]
    }

    func set(quadrant1: String?, quadrant2: String?, quadrant3: String?, quadrant4: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let v = quadrant1, validScopeIds.contains(v) { storage[1] = v }
        if let v = quadrant2, validScopeIds.contains(v) { storage[2] = v }
        if let v = quadrant3, validScopeIds.contains(v) { storage[3] = v }
        if let v = quadrant4, validScopeIds.contains(v) { storage[4] = v }
    }
}

private let layoutState = WebUILayoutState()

/// Set the provider for scope JPEG stream (NET-006). Called by app when pipeline is available; closure returns JPEG Data or nil.
public func setScopeStreamProvider(_ provider: (() -> Data?)?) {
    scopeStreamProviderLock.lock()
    _scopeStreamProvider = provider
    scopeStreamProviderLock.unlock()
}

// MARK: - NET-007: Input source (device + format) provider and setter

private let inputSourceLock = NSLock()
private var _inputSourceProvider: (() -> Data?)?
private var _inputSourceSelectionCallback: ((Int, Int) -> Void)?

/// Set the provider for input source list (NET-007). Closure returns JSON Data: { devices: [{ name, modes: [{ name, width, height, frameRate }] }], selectedDeviceIndex, selectedModeIndex }. Called from app (HDRUI) with Capture state.
public func setInputSourceProvider(_ provider: (() -> Data?)?) {
    inputSourceLock.lock()
    _inputSourceProvider = provider
    inputSourceLock.unlock()
}

/// Set the callback to apply input source selection (NET-007). Called when Web UI POSTs deviceIndex and modeIndex. App should dispatch to main and update CapturePreviewState.
public func setInputSourceSelectionCallback(_ callback: ((Int, Int) -> Void)?) {
    inputSourceLock.lock()
    _inputSourceSelectionCallback = callback
    inputSourceLock.unlock()
}

// MARK: - NET-007: Colorspace provider and setter

private let colorspaceLock = NSLock()
private var _colorspaceProvider: (() -> String?)?
private var _colorspaceSelectionCallback: ((String) -> Void)?

private let validColorspaceValues = ["rec709", "rec2020", "p3", "pq", "hlg"]

/// Set the provider for current colorspace (NET-007). Closure returns raw value e.g. "rec709". Called from app (HDRUI) with AppConfig.
public func setColorspaceProvider(_ provider: (() -> String?)?) {
    colorspaceLock.lock()
    _colorspaceProvider = provider
    colorspaceLock.unlock()
}

/// Set the callback to apply colorspace selection (NET-007). Called when Web UI POSTs colorspace. App should update AppConfig and save.
public func setColorspaceSelectionCallback(_ callback: ((String) -> Void)?) {
    colorspaceLock.lock()
    _colorspaceSelectionCallback = callback
    colorspaceLock.unlock()
}

/// Returns an HTTP request handler that serves the Web UI SPA, /api/layout, and /api/scope/jpeg.
/// Use with NetworkService.setWebServerHandler(WebUIServer.requestHandler()).
public enum WebUIServer {
    public static func requestHandler() -> HTTPRequestHandler {
        return { request in
            let path = request.path
            let method = request.method.uppercased()

            // NET-010: Authentication — require valid session for all routes except login and /health
            webAuthLock.lock()
            let authEnabled = _webAuthPassword != nil
            webAuthLock.unlock()
            if authEnabled && webAuthRequiresAuth(path: path, method: method) {
                let token = webAuthExtractToken(from: request)
                guard let t = token, webAuthValidateToken(t) else {
                    return HTTPResponse.unauthorized(body: "{\"error\":\"Unauthorized\",\"login\":\"/api/auth/login\"}".data(using: .utf8))
                }
            }

            // API: POST /api/auth/login (NET-010) — authenticate with password, set session cookie
            if path == "/api/auth/login" && method == "POST" {
                guard let body = request.body,
                      let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let password = obj["password"] as? String else {
                    return HTTPResponse(statusCode: 400, body: "{\"error\":\"Bad Request\"}".data(using: .utf8), contentType: "application/json; charset=utf-8")
                }
                webAuthLock.lock()
                let expected = _webAuthPassword
                webAuthLock.unlock()
                guard expected == password else {
                    return HTTPResponse(statusCode: 401, body: "{\"error\":\"Invalid password\"}".data(using: .utf8), contentType: "application/json; charset=utf-8")
                }
                let sessionToken = webAuthCreateSession()
                let cookieValue = "session=\(sessionToken); HttpOnly; Path=/; SameSite=Strict"
                return HTTPResponse(
                    statusCode: 200,
                    body: "{\"ok\":true}".data(using: .utf8),
                    contentType: "application/json; charset=utf-8",
                    headers: ["Set-Cookie": cookieValue]
                )
            }

            // WebSocket upgrade (NET-009): GET /ws — real-time control channel
            if path == "/ws" && method == "GET" {
                let upgrade = request.headers["upgrade"]?.lowercased().contains("websocket") ?? false
                let key = request.headers["sec-websocket-key"]
                guard upgrade, let key = key, let acceptKey = webSocketAcceptKey(from: key) else {
                    return HTTPResponse(statusCode: 400, body: "Bad Request".data(using: .utf8), contentType: "text/plain; charset=utf-8")
                }
                return .webSocketUpgrade(acceptKey: acceptKey)
            }

            // API: GET /api/scope/jpeg — JPEG stream of current scope display (NET-006)
            if path == "/api/scope/jpeg" && method == "GET" {
                scopeStreamProviderLock.lock()
                let provider = _scopeStreamProvider
                scopeStreamProviderLock.unlock()
                guard let provider = provider, let jpegData = provider() else {
                    return HTTPResponse(
                        statusCode: 503,
                        body: "Scope stream unavailable".data(using: .utf8),
                        contentType: "text/plain; charset=utf-8"
                    )
                }
                return HTTPResponse(statusCode: 200, body: jpegData, contentType: "image/jpeg")
            }

            // SPA: serve index.html for / and /index.html
            if path == "/" || path == "/index.html" {
                guard let data = loadWebUIIndexHTML() else {
                    return .serverError("Web UI resource not found")
                }
                return HTTPResponse(statusCode: 200, body: data, contentType: "text/html; charset=utf-8")
            }

            // API: GET /api/layout
            if path == "/api/layout" && method == "GET" {
                let layout = layoutState.get()
                guard let json = try? JSONSerialization.data(withJSONObject: layout) else {
                    return .serverError("JSON serialization failed")
                }
                return HTTPResponse(statusCode: 200, body: json, contentType: "application/json; charset=utf-8")
            }

            // API: POST /api/layout
            if path == "/api/layout" && method == "POST" {
                guard let body = request.body,
                      let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return HTTPResponse(statusCode: 400, body: "Bad Request".data(using: .utf8), contentType: "text/plain; charset=utf-8")
                }
                let q1 = obj["quadrant1"] as? String
                let q2 = obj["quadrant2"] as? String
                let q3 = obj["quadrant3"] as? String
                let q4 = obj["quadrant4"] as? String
                layoutState.set(quadrant1: q1, quadrant2: q2, quadrant3: q3, quadrant4: q4)
                return .ok(text: "OK")
            }

            // API: GET /api/input (NET-007) — device list + modes + current selection
            if path == "/api/input" && method == "GET" {
                inputSourceLock.lock()
                let provider = _inputSourceProvider
                inputSourceLock.unlock()
                guard let provider = provider, let data = provider() else {
                    return HTTPResponse(statusCode: 503, body: "Input source unavailable".data(using: .utf8), contentType: "text/plain; charset=utf-8")
                }
                return HTTPResponse(statusCode: 200, body: data, contentType: "application/json; charset=utf-8")
            }

            // API: POST /api/input (NET-007) — set device and mode by index
            if path == "/api/input" && method == "POST" {
                guard let body = request.body,
                      let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let deviceIndex = obj["deviceIndex"] as? Int,
                      let modeIndex = obj["modeIndex"] as? Int else {
                    return HTTPResponse(statusCode: 400, body: "Bad Request".data(using: .utf8), contentType: "text/plain; charset=utf-8")
                }
                inputSourceLock.lock()
                let callback = _inputSourceSelectionCallback
                inputSourceLock.unlock()
                callback?(deviceIndex, modeIndex)
                return .ok(text: "OK")
            }

            // API: GET /api/colorspace (NET-007) — options + current
            if path == "/api/colorspace" && method == "GET" {
                colorspaceLock.lock()
                let provider = _colorspaceProvider
                colorspaceLock.unlock()
                let current = provider?() ?? "rec709"
                let payload: [String: Any] = ["options": validColorspaceValues, "current": current]
                guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
                    return .serverError("JSON serialization failed")
                }
                return HTTPResponse(statusCode: 200, body: json, contentType: "application/json; charset=utf-8")
            }

            // API: POST /api/colorspace (NET-007) — set current colorspace
            if path == "/api/colorspace" && method == "POST" {
                guard let body = request.body,
                      let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let raw = obj["colorspace"] as? String,
                      validColorspaceValues.contains(raw) else {
                    return HTTPResponse(statusCode: 400, body: "Bad Request".data(using: .utf8), contentType: "text/plain; charset=utf-8")
                }
                colorspaceLock.lock()
                let callback = _colorspaceSelectionCallback
                colorspaceLock.unlock()
                callback?(raw)
                return .ok(text: "OK")
            }

            // Health for compatibility
            if path == "/health" {
                return .ok(text: "OK")
            }

            return .notFound()
        }
    }

    /// Current layout (for app sync). Keys: quadrant1...quadrant4.
    public static func currentLayout() -> [String: String] {
        layoutState.get()
    }
}

// MARK: - Load Web UI resource

private func loadWebUIIndexHTML() -> Data? {
    guard let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "WebUI")
        ?? Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Resources/WebUI") else {
        return nil
    }
    return try? Data(contentsOf: url)
}
