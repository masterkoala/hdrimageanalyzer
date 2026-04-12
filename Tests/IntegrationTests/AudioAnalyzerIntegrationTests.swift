import XCTest
@testable import HDRImageAnalyzerPro

/// Integration tests for Advanced Audio Analyzer
final class AudioAnalyzerIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        try super.tearDownWithError()
    }

    /// Test audio analyzer initialization
    func testAudioAnalyzerInitialization() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()

        XCTAssertNotNil(audioAnalyzer, "Audio analyzer should not be nil")
        XCTAssertGreaterThan(audioAnalyzer.sampleRate, 0.0, "Sample rate should be positive")
        XCTAssertEqual(audioAnalyzer.channels, 2, "Default channels should be 2")
    }

    /// Test basic audio frame processing
    func testAudioFrameProcessing() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()

        // Create test audio data (100 samples of stereo audio)
        var testData = [Float]()
        for i in 0..<100 {
            testData.append(Float(i % 100) / 100.0) // Simple sine wave pattern
        }

        // Process the frame
        let result = audioAnalyzer.processFrame(audioData: testData, channelCount: 2)

        XCTAssertNotNil(result, "Processing should return a result")
        XCTAssertGreaterThan(result.processingTime, 0.0, "Processing time should be positive")
    }

    /// Test audio statistics retrieval
    func testAudioStatistics() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()

        // Create test audio data
        var testData = [Float]()
        for i in 0..<100 {
            testData.append(Float(i % 100) / 100.0)
        }

        // Process the frame to populate statistics
        _ = audioAnalyzer.processFrame(audioData: testData, channelCount: 2)

        let stats = audioAnalyzer.getStatistics()

        XCTAssertNotNil(stats, "Statistics should not be nil")
        XCTAssertGreaterThan(stats.loudness, -100.0, "Loudness should be reasonable")
    }

    /// Test reset functionality
    func testAudioAnalyzerReset() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()

        // Create and process some test data
        var testData = [Float]()
        for i in 0..<50 {
            testData.append(Float(i % 50) / 50.0)
        }

        _ = audioAnalyzer.processFrame(audioData: testData, channelCount: 2)

        // Reset the analyzer
        audioAnalyzer.reset()

        let stats = audioAnalyzer.getStatistics()

        // After reset, statistics should be at default values
        XCTAssertEqual(stats.loudness, 0.0, "Loudness should reset to 0.0")
        XCTAssertTrue(stats.peakLevels.isEmpty, "Peak levels should be empty after reset")
    }

    /// Test different channel configurations
    func testDifferentChannelConfigurations() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()

        // Test stereo (2 channels)
        var stereoData = [Float]()
        for i in 0..<100 {
            stereoData.append(Float(i % 100) / 100.0)
        }

        let stereoResult = audioAnalyzer.processFrame(audioData: stereoData, channelCount: 2)
        XCTAssertNotNil(stereoResult, "Stereo processing should succeed")

        // Test mono (1 channel)
        var monoData = [Float]()
        for i in 0..<100 {
            monoData.append(Float(i % 100) / 100.0)
        }

        let monoResult = audioAnalyzer.processFrame(audioData: monoData, channelCount: 1)
        XCTAssertNotNil(monoResult, "Mono processing should succeed")
    }

    /// Test performance with large data sets
    func testAudioPerformance() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()

        // Create larger test data set
        var largeTestData = [Float]()
        for i in 0..<10000 {
            largeTestData.append(Float(i % 10000) / 10000.0)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let result = audioAnalyzer.processFrame(audioData: largeTestData, channelCount: 2)
        let endTime = CFAbsoluteTimeGetCurrent()

        XCTAssertNotNil(result, "Large data processing should succeed")
        XCTAssertLessThan(endTime - startTime, 1.0, "Processing should complete within 1 second")
    }
}