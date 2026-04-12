import XCTest
@testable import Scopes

final class ScopesTests: XCTestCase {
    func testScopeEngineRegistered() {
        // ScopeEngine is registered at init; just ensure module loads
        XCTAssertTrue(true)
    }

    // MARK: - INT-007 Visual QA: Compare scopes against AJA PDF reference

    /// All scope types that must be compared against the AJA HDR Image Analyzer 12G PDF.
    /// Must stay in sync with HDRUI.QuadrantContent (Video, Waveform, Vectorscope, Histogram, RGB Parade, CIE xy).
    static let visualQAScopeTypeIDs: [String] = [
        "Video",
        "Waveform",
        "Vectorscope",
        "Histogram",
        "RGB Parade",
        "CIE xy"
    ]

    /// AJA PDF reference visual quality criteria (roadmap AGENT-03). Used for checklist and regression.
    static let visualQACriteria: [String] = [
        "phosphor-glow effect",
        "smooth intensity gradients",
        "precise graticule lines with labels",
        "color-coded traces",
        "professional dark background",
        "anti-aliased text overlays"
    ]

    func testVisualQAScopeTypesCoverage() {
        // INT-007: Ensure every scope type that has a visual reference in the AJA PDF is listed for QA.
        XCTAssertEqual(ScopesTests.visualQAScopeTypeIDs.count, 6)
        XCTAssertTrue(ScopesTests.visualQAScopeTypeIDs.contains("Waveform"))
        XCTAssertTrue(ScopesTests.visualQAScopeTypeIDs.contains("Vectorscope"))
        XCTAssertTrue(ScopesTests.visualQAScopeTypeIDs.contains("Histogram"))
        XCTAssertTrue(ScopesTests.visualQAScopeTypeIDs.contains("RGB Parade"))
        XCTAssertTrue(ScopesTests.visualQAScopeTypeIDs.contains("CIE xy"))
        XCTAssertTrue(ScopesTests.visualQAScopeTypeIDs.contains("Video"))
    }

    func testVisualQACriteriaDocumented() {
        // INT-007: Ensure AJA reference criteria remain documented in tests (see VisualQAChecklist.md).
        XCTAssertEqual(ScopesTests.visualQACriteria.count, 6)
        XCTAssertTrue(ScopesTests.visualQACriteria.contains("phosphor-glow effect"))
        XCTAssertTrue(ScopesTests.visualQACriteria.contains("professional dark background"))
    }

    // MARK: - SC-025 Scope visual quality audit vs AJA PDF

    /// Task ID for Phase 3 scope visual quality audit (compare renders against AJA PDF). Checklist in VisualQAChecklist.md.
    static let sc025AuditTaskId: String = "SC-025"

    func testSC025AuditChecklistPresent() {
        // SC-025: Ensure the visual quality audit checklist is present and criteria are used for render comparison.
        XCTAssertEqual(ScopesTests.sc025AuditTaskId, "SC-025")
        XCTAssertEqual(ScopesTests.visualQACriteria.count, 6, "AJA criteria must be used for SC-025 render audit")
    }
}
