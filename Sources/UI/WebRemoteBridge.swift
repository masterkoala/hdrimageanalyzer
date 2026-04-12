import Foundation
import Network

/// Bridge to Network module's free functions — isolates `import Network` from MainView
/// to avoid Apple Network framework name collision causing Swift type-checker crash.
enum WebRemoteBridge {
    static func registerScopeStreamProvider(_ provider: (() -> Data?)?) {
        setScopeStreamProvider(provider)
    }

    static func registerInputSourceProvider(_ provider: (() -> Data?)?) {
        setInputSourceProvider(provider)
    }

    static func registerInputSourceSelectionCallback(_ callback: ((Int, Int) -> Void)?) {
        setInputSourceSelectionCallback(callback)
    }

    static func registerColorspaceProvider(_ provider: (() -> String?)?) {
        setColorspaceProvider(provider)
    }

    static func registerColorspaceSelectionCallback(_ callback: ((String) -> Void)?) {
        setColorspaceSelectionCallback(callback)
    }
}
