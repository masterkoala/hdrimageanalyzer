import Foundation
import Logging
import Common

/// Audio metering (Phase 5: level, phase, loudness). QC-011: EBUR128ComplianceChecker for EBU R128 compliance. AU-012: AudioOverUnderDetector for over/under level detection with logging.
public enum AudioEngine {
    public static func register() {
        HDRLogger.info(category: "Audio", "AudioEngine registered")
    }
}
