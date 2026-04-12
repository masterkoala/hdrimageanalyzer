# Grey Video Feed — Fix Report and Action Items

## Problem Identification

After analyzing the codebase, I identified several issues causing grey video output:

### Issue 1: Missing Actual Shader Implementation (HIGHEST PRIORITY)

**Location:** `Sources/Metal/MetalEngine.swift`

The embedded shader library only contains placeholder kernels:
```metal
kernel void placeholder_kernel() {}
kernel void convert_v210_to_rgb_placeholder(...) {}
```

These do nothing, producing black/grey frames.

### Issue 2: Capture→Pipeline Flow May Not Be Working

**Location:** `Sources/UI/CapturePreviewView.swift`, lines 294-381

The capture startup path:
1. Creates `DeckLinkCaptureSession` with callbacks
2. Calls `session.start()`
3. Frames arrive via `handleFrameArrived()`
4. Frames submitted to `frameManager.submitFrame()`
5. But `processFrame()` in `MasterPipeline` may not be executing or producing output

### Issue 3: Missing Real v210→RGB Conversion Logic

The `MasterPipeline.processFrame()` has branches for:
- `.v210` (10-bit YUV 4:2:2) → needs conversion kernel
- `.rgb12` (12-bit RGB) → should work
- `.rgb8` (8-bit BGRA) → should work

But the v210 path cannot produce valid video because:
- No actual conversion shader
- `convertV210PipelineState` is nil
- `convert_v210_to_rgb_placeholder` is empty

### Issue 4: Possible DeckLink SDK Integration Issues

**Location:** `Sources/Capture/DeckLinkCaptureSession.swift`

Missing verification of:
- Callback registration success
- Actual frame arrival in `handleFrameArrived()`
- Whether frames are reaching the pipeline

## Recommended Fixes

### Fix A: Add Minimal Working Shader Support

Create actual Metal shader files with functional kernels:

1. **Shaders/Conversion.metal** — v210→RGB conversion
2. **Shaders/Common.metal** — Shared utilities
3. **Sources/Metal/WorkingMetalEngine.swift** — Working engine wrapper

### Fix B: Verify Capture Is Reaching Pipeline

Add logging in critical paths:
- `DeckLinkCaptureSession.handleFrameArrived()` → confirm frames arrive
- `TripleBufferedFrameManager.submitFrame()` → confirm submission
- `MasterPipeline.processFrame()` → confirm processing
- `MTKView.delegate.draw(in:)` → confirm draw succeeded

### Fix C: Test With Easier Pixel Format First

Modify `CapturePreviewState.startCapture()` to try easier formats first:

```swift
// Try rgb8 first (easiest) — should show something immediately
if pixelFormat == .v210 && !shouldStartWithV210 {
    pixelFormat = .rgb8  // or .rgb12 if available
}
```

### Fix D: Ensure Primary Driver Initialization

In `MainView.onAppear`, ensure the preview becomes the primary driver:

```swift
guard let pipeline = captureState.pipelineForDisplay else { return }
pipeline.becomePrimaryDriver(viewId: ObjectIdentifier(self))
```

## Status Report Formatting

Create clear, actionable reports for your agent system:

- **Issue Type:** Production blocker
- **Impact:** Video feed shows grey/black screens
- **Root Cause:** Missing shader implementation or capture→pipeline flow failure
- **Priority:** Highest — prevents any use of the application
- **Estimated Fix Time:** 2-3 hours

## What I've Created So Far

1. ✅ `Shaders/Common.metal` — Shared constants and helpers
2. ✅ `Shaders/Conversion.v210.metal` — V210 conversion framework
3. ✅ `Shaders/Conversion.simple.metal` — Minimal working version
4. ⚠️  `Sources/Metal/WorkingMetalEngine.swift` — Incomplete

## Immediate Next Steps

1. Complete `WorkingMetalEngine.swift` with:
   - Remaining shader source
   - Pipeline creation logic
   - Error handling

2. Modify `MainView.onAppear` to use working engine

3. Add logging to trace frame flow

4. Test with simplest possible case first (rgb8 format if available, or rgb12)

## Confusion Points Requiring Clarification

- Should v210 be supported immediately, or ship simpler format first?
- Is there a screen preview path in DeckLink SDK that works?
- Why would someone choose to start with v210 if it doesn't work yet?

## Files That Need Modification (Not New)

The following files need changes to integrate fixes:

1. `Sources/UI/MainView.swift` — Initialize capture pipeline correctly
2. `Sources/ui/CapturePreviewView.swift` — Verify capture→pipeline integration
3. `Sources/Metal/MasterPipeline.swift` — Ensure processFrame() executes
4. `Sources/capture/DeckLinkCaptureSession.swift` — Confirm callbacks working

## Conclusion

The grey video issue is real and traceable to missing shader implementation or capture pipeline integration. I've created several shader files that should address this, but need to complete the integration work.

**Recommendation:** Prioritize shipping a version that works with simpler pixel formats first (rgb12/rgb8 if available), then add v210 support.