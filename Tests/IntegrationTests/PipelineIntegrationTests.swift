import XCTest
import Metal
import Common
import Logging
@testable import Capture
@testable import MetalEngine

/// INT-001: Full pipeline integration test — SDI input (simulated) -> scopes -> display.
/// Exercises: frame submission (simulating SDI/capture callback) -> MasterPipeline processFrame (convert + scope compute) -> display texture and scope render path.
/// Skips when no Metal device (e.g. CI headless). Does not require physical DeckLink hardware.
final class PipelineIntegrationTests: XCTestCase {

    /// Full path: submit frame (simulated SDI) -> processFrame (convert + scopes) -> verify display texture; then render scope to offscreen texture (display path).
    func testFullPipelineSDIInputToScopesToDisplay() throws {
        guard let engine = MetalEngine.shared else {
            throw XCTSkip("No Metal device — skip pipeline integration test")
        }
        guard let pipeline = MasterPipeline(engine: engine) else {
            throw XCTSkip("MasterPipeline init failed — skip pipeline integration test")
        }

        // 1) SDI input (simulated): same contract as Capture onFrame callback — submit raw frame bytes.
        let width = 1920
        let height = 1080
        let rowBytes = width * 4
        let bufferLength = rowBytes * height
        guard let buffer = engine.device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
            XCTFail("Failed to allocate frame buffer for pipeline integration test")
            return
        }
        memset(buffer.contents(), 0x40, bufferLength) // placeholder path uses raw bytes

        let pixelFormat: FramePixelFormat = 0 // placeholder (non-v210, non-R12L)
        pipeline.submitFrame(
            bytes: buffer.contents(),
            rowBytes: rowBytes,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )

        // 2) Process frame: convert -> scopes (waveform/vectorscope/parade/ciexy) -> display texture.
        let outTexture = pipeline.processFrame()
        XCTAssertNotNil(outTexture, "processFrame() should return a texture after submitFrame (SDI -> scopes -> display)")

        let displayTex = pipeline.displayTexture
        XCTAssertNotNil(displayTex, "displayTexture should be non-nil after processFrame")
        XCTAssertEqual(displayTex?.width, width, "Display texture width should match submitted frame")
        XCTAssertEqual(displayTex?.height, height, "Display texture height should match submitted frame")

        // 3) Display path: render scope output (or display texture) to an offscreen texture.
        guard let offscreen = engine.texturePool.getTexture(width: width, height: height, format: .bgra8Unorm) else {
            XCTFail("Failed to get offscreen texture for scope render")
            return
        }
        defer { engine.texturePool.returnTexture(offscreen) }

        pipeline.renderScopeToTexture(offscreen)
        // No drawable in test; renderScopeToTexture commits command buffer. Sync is internal (lastScopeCommandBuffer wait).
        engine.commandQueue.makeCommandBuffer()?.waitUntilCompleted()
        // If we got here without crash, display path (scope -> texture) executed.
    }

    /// Verifies Capture module provides the SDI input contract (device enumeration and frame callback types).
    func testCaptureSDIContractAvailable() {
        let mgr = DeckLinkDeviceManager()
        XCTAssertNotNil(mgr)
        let devices = mgr.enumerateDevices()
        XCTAssertNotNil(devices)
        // Optional: if device present, we could start capture and feed pipeline; here we only assert contract exists.
    }

    /// Multiple frames through pipeline to stress convert + scopes path (no display render).
    func testPipelineSustainedFramesSDIToScopes() throws {
        guard let engine = MetalEngine.shared else {
            throw XCTSkip("No Metal device")
        }
        guard let pipeline = MasterPipeline(engine: engine) else {
            throw XCTSkip("MasterPipeline init failed")
        }

        let width = 1280
        let height = 720
        let rowBytes = width * 4
        let bufferLength = rowBytes * height
        guard let buffer = engine.device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
            XCTFail("Failed to allocate frame buffer")
            return
        }
        memset(buffer.contents(), 0, bufferLength)

        let frameCount = 30
        for _ in 0..<frameCount {
            pipeline.submitFrame(
                bytes: buffer.contents(),
                rowBytes: rowBytes,
                width: width,
                height: height,
                pixelFormat: 0
            )
            let tex = pipeline.processFrame()
            XCTAssertNotNil(tex)
        }
        XCTAssertNotNil(pipeline.displayTexture)
    }

    // MARK: - INT-002: Multi-channel integration test — 4x simultaneous 4K inputs

    /// 4K resolution (UHD 3840×2160). Used for INT-002 multi-channel test.
    private static let k4KWidth = 3840
    private static let k4KHeight = 2160
    private static let k4KChannels = 4

    /// INT-002: Simulates 4 channels feeding 4K frames into the pipeline. Uses shared pipeline and frame manager;
    /// 4 threads submit frames (simulating 4 simultaneous capture inputs) while the main thread processes.
    /// Validates pipeline accepts 4K and remains thread-safe under concurrent submit.
    func testMultiChannel4x4KSimultaneousInputs() throws {
        guard let engine = MetalEngine.shared else {
            throw XCTSkip("No Metal device — skip multi-channel 4K integration test")
        }
        guard let pipeline = MasterPipeline(engine: engine) else {
            throw XCTSkip("MasterPipeline init failed — skip multi-channel 4K integration test")
        }

        let width = Self.k4KWidth
        let height = Self.k4KHeight
        let rowBytes = width * 4
        let bufferLength = rowBytes * height

        // Allocate 4 channel buffers (4x 4K simulated inputs)
        var channelBuffers: [MTLBuffer] = []
        for ch in 0..<Self.k4KChannels {
            guard let buf = engine.device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
                XCTFail("Failed to allocate 4K buffer for channel \(ch)")
                return
            }
            // Distinct fill per channel so we could detect mix-ups
            memset(buf.contents(), Int32(0x30 + ch), bufferLength)
            channelBuffers.append(buf)
        }
        defer { channelBuffers.removeAll() }

        let submitCountPerChannel = 8
        let expectation = expectation(description: "4 channels submitted and processed")
        expectation.expectedFulfillmentCount = 1

        // 4 producer threads: each submits submitCountPerChannel frames
        let queue = DispatchQueue(label: "com.hdranalyzer.int2.submit", attributes: .concurrent)
        for ch in 0..<Self.k4KChannels {
            let buffer = channelBuffers[ch]
            queue.async {
                for _ in 0..<submitCountPerChannel {
                    pipeline.submitFrame(
                        bytes: buffer.contents(),
                        rowBytes: rowBytes,
                        width: width,
                        height: height,
                        pixelFormat: 0
                    )
                }
            }
        }

        // Consumer: process frames until we see at least one 4K result (or cap iterations)
        queue.async(flags: .barrier) {
            var processed4K = false
            for _ in 0..<(Self.k4KChannels * submitCountPerChannel + 10) {
                if let tex = pipeline.processFrame(), tex.width == width, tex.height == height {
                    processed4K = true
                    break
                }
            }
            XCTAssertTrue(processed4K, "Pipeline should produce at least one 4K display texture under 4-channel submit")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)

        if let displayTex = pipeline.displayTexture {
            XCTAssertEqual(displayTex.width, width, "Display texture width should be 4K")
            XCTAssertEqual(displayTex.height, height, "Display texture height should be 4K")
        }
    }

    /// INT-002: Sequential 4x 4K round-robin — each of 4 "channels" submits one 4K frame in turn; process after each. Repeats several rounds.
    func testMultiChannel4x4KSequentialRoundRobin() throws {
        guard let engine = MetalEngine.shared else {
            throw XCTSkip("No Metal device")
        }
        guard let pipeline = MasterPipeline(engine: engine) else {
            throw XCTSkip("MasterPipeline init failed")
        }

        let width = Self.k4KWidth
        let height = Self.k4KHeight
        let rowBytes = width * 4
        let bufferLength = rowBytes * height

        var channelBuffers: [MTLBuffer] = []
        for ch in 0..<Self.k4KChannels {
            guard let buf = engine.device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
                XCTFail("Failed to allocate 4K buffer for channel \(ch)")
                return
            }
            memset(buf.contents(), Int32(0x40 + ch), bufferLength)
            channelBuffers.append(buf)
        }

        let rounds = 5
        for round in 0..<rounds {
            for ch in 0..<Self.k4KChannels {
                let buf = channelBuffers[ch]
                pipeline.submitFrame(
                    bytes: buf.contents(),
                    rowBytes: rowBytes,
                    width: width,
                    height: height,
                    pixelFormat: 0
                )
                let tex = pipeline.processFrame()
                XCTAssertNotNil(tex, "Round \(round) channel \(ch): processFrame should return texture")
                if let t = tex {
                    XCTAssertEqual(t.width, width)
                    XCTAssertEqual(t.height, height)
                }
            }
        }
        XCTAssertNotNil(pipeline.displayTexture)
        XCTAssertEqual(pipeline.displayTexture?.width, width)
        XCTAssertEqual(pipeline.displayTexture?.height, height)
    }
}
