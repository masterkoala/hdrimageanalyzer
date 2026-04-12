import Foundation
import Logging
import Common
import MetalEngine
import Metal

/// Interface for scope views that receive texture updates from MetalEngine/MasterPipeline.
/// MasterPipeline.processFrame() produces MTLTexture; call update(texture:) each frame to drive the scope.
public protocol ScopeTextureUpdatable: AnyObject {
    /// Update the scope with the latest display texture (or nil if no frame).
    func update(texture: MTLTexture?)
}

/// Scope rendering engine (Phase 3 will add waveform, vectorscope, etc.).
public enum ScopeEngine {
    public static func register() {
        HDRLogger.info(category: "Scopes", "ScopeEngine registered")
    }
}
