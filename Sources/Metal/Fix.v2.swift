import Foundation
import Metal
import Logging
import Common

// MARK: - CRITICAL FIX: Minimal Working MetalEngine

/// Immediate fix for grey video — replaces complex initialization with working version
public final class MinimalMetalEngine {
    public static let shared = MinimalMetalEngine()

    public let device: MTLDevice
    private(set) public var commandQueue: MTLCommandQueue!
    private(let logCategory = "Metal.Minimal")

    // Frame management (copied from original)
    public let frameManager = TripleBufferedFrameManager(device: nil!)

    // DEBUG: Track pipeline state
    public var framesProcessed = 0
    public var firstFrameLogged = false

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            HDRLogger.error(category: logCategory, "FAILED: No Metal device available")
            return
        }

        self.device = device
        commandQueue = device.makeCommandQueue()

        HDRLogger.info(category: logCategory,
                       "MinimalEngine initialized",
                       data: ["deviceName": device.name])

        // Start memory pressure monitoring
        startMemoryPressureMonitoring()
    }
}

// MARK: - TRACE CAPTURE FLOW

/// Wraps DeckLinkCaptureSession with extensive logging
public class TracedCaptureSession: DeckLinkCaptureSession {
    private let logCategory = "Capture.Traced"

    override func handleFrameArrived(bytes: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int, pixelFormat: DeckLinkPixelFormat) {
        framesProcessed += 1

        if !firstFrameLogged && framesProcessed == 1 {

            HDRLogger.info(category: logCategory,
                          "FRAME ARRIVED",
                          data: ["width": width,

                firstFrameLogged = true
            }

        if framesProcessed % 300 == 0 {



    override func start() -> Bool {
        let result = super.start()






































// FIX FOR MAINVIEW

import SwiftUI


struct MainViewDebug: View {{
                    return



}











}