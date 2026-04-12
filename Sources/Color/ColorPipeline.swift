import Foundation
import Logging
import Common

/// Color pipeline (Phase 4 will add PQ, HLG, LUTs).
public enum ColorPipeline {
    public static func register() {
        HDRLogger.info(category: "Color", "ColorPipeline registered")
    }
}
