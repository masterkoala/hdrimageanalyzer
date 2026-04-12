import XCTest
@testable import HDRImageAnalyzerPro

/// Performance benchmark tests for the enhanced system
final class BenchmarkTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        try super.tearDownWithError()
    }

    /// Benchmark audio analysis performance
    func testAudioAnalysisPerformance() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()

        // Create benchmark data (larger dataset for realistic testing)
        var testData = [Float]()
        for i in 0..<50000 {
            testData.append(Float(i % 1000) / 1000.0)
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Process multiple frames to get a meaningful benchmark
        for _ in 0..<20 {
            _ = audioAnalyzer.processFrame(audioData: testData, channelCount: 2)
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        // Should complete within reasonable time (this is a rough benchmark)
        XCTAssertLessThan(processingTime, 10.0, "Processing 20 audio frames should complete within 10 seconds")

        print("Audio analysis benchmark: \(processingTime) seconds for 20 frames")
    }

    /// Benchmark QC system performance
    func testQCSystemPerformance() throws {
        let qcSystem = EnhancedQCSystem.shared

        let startTime = CFAbsoluteTimeGetCurrent()

        // Log multiple events to simulate real usage
        for i in 0..<1000 {
            qcSystem.logVideoEvent(
                frameNumber: i,
                resolution: "1920x1080",
                fps: 30.0,
                colorSpace: "Rec.2020",
                description: "Benchmark event \(i)"
            )
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        // Should complete within reasonable time
        XCTAssertLessThan(processingTime, 5.0, "Logging 1000 events should complete within 5 seconds")

        print("QC system benchmark: \(processingTime) seconds for 1000 events")
    }

    /// Benchmark OFX simulation performance
    func testOFXSimulationPerformance() throws {
        let simulation = OFXDeviceSimulation.shared

        let startTime = CFAbsoluteTimeGetCurrent()

        // Create multiple simulations to test performance
        for i in 0..<50 {
            let simID = simulation.createTestPatternSimulation(
                name: "BenchmarkSim\(i)",
                resolution: "1920x1080",
                frameRate: 30.0
            )

            if let id = simID {
                simulation.startSimulation(simulationID: id)
                simulation.stopSimulation(simulationID: id)
            }
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        // Should complete within reasonable time
        XCTAssertLessThan(processingTime, 10.0, "Creating and managing 50 simulations should complete within 10 seconds")

        print("OFX simulation benchmark: \(processingTime) seconds for 50 simulations")
    }

    /// Benchmark web server performance
    func testWebServerPerformance() throws {
        let webServer = EnhancedWebServer.shared

        let startTime = CFAbsoluteTimeGetCurrent()

        // Test multiple operations on the web server
        for i in 0..<100 {
            // Simulate web server operations
            let _ = webServer.getStatistics()

            if i % 10 == 0 {
                // Occasionally add/remove devices to simulate real usage
                if i % 20 == 0 {
                    webServer.resetStatistics()
                }
            }
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        // Should complete within reasonable time
        XCTAssertLessThan(processingTime, 5.0, "Web server operations should complete within 5 seconds")

        print("Web server benchmark: \(processingTime) seconds for 100 operations")
    }

    /// Test memory usage patterns
    func testMemoryUsagePatterns() throws {
        let qcSystem = EnhancedQCSystem.shared

        // Log events and monitor memory behavior
        for i in 0..<500 {
            qcSystem.logVideoEvent(
                frameNumber: i,
                resolution: "1920x1080",
                fps: 30.0,
                colorSpace: "Rec.2020",
                description: "Memory test event \(i)"
            )
        }

        let stats = qcSystem.getStatistics()

        // Verify system can handle large volumes
        XCTAssertTrue(stats.totalEvents >= 500, "Should have processed at least 500 events")
        XCTAssertGreaterThan(stats.videoEvents, 499, "Should have logged many video events")
    }

    /// Benchmark combined system performance
    func testCombinedSystemPerformance() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()
        let qcSystem = EnhancedQCSystem.shared
        let simulation = OFXDeviceSimulation.shared

        let startTime = CFAbsoluteTimeGetCurrent()

        // Simulate a realistic workflow
        var testData = [Float]()
        for i in 0..<1000 {
            testData.append(Float(i % 1000) / 1000.0)
        }

        // Process audio frames while logging QC events and managing simulations
        for i in 0..<20 {
            _ = audioAnalyzer.processFrame(audioData: testData, channelCount: 2)

            qcSystem.logAudioEvent(
                channelCount: 2,
                sampleRate: 48000.0,
                loudness: -23.0 + Double(i * 0.1),
                peakLevel: -5.0 + Double(i * 0.2),
                description: "Combined test audio event \(i)"
            )

            if i % 5 == 0 {
                let simID = simulation.createTestPatternSimulation(
                    name: "CombinedTestSim\(i)",
                    resolution: "1920x1080",
                    frameRate: 30.0
                )

                if let id = simID {
                    simulation.startSimulation(simulationID: id)
                    simulation.stopSimulation(simulationID: id)
                }
            }
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        // Should complete within reasonable time
        XCTAssertLessThan(processingTime, 15.0, "Combined system operations should complete within 15 seconds")

        print("Combined system benchmark: \(processingTime) seconds for complex workflow")
    }
}