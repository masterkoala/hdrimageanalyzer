// MT-006: Shared shader types — layout must match Shaders/Common/ShaderTypes.metal for CPU/GPU buffer uploads.
// Use these structs when filling MTLBuffers consumed by Metal kernels.

import Foundation
import Metal

/// v210 decode params passed to convert_v210_to_rgb kernel (buffer index 1).
/// Layout must match Metal struct V210Params (width, height, rowBytes).
public struct V210Params {
    public var width: UInt32
    public var height: UInt32
    public var rowBytes: UInt32

    public init(width: UInt32, height: UInt32, rowBytes: UInt32) {
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
    }
}

/// SC-002: Point rasterizer params — [accumWidth, accumHeight, inputWidth, inputHeight, mode, maxNits, inputIsPQ, singleLineMode, singleLineRow]. Layout must match kernel buffer(1).
/// SC-005: mode for waveform: 0=Luminance, 1=R, 2=G, 3=B (RGB overlay), 4=Y, 5=Cb, 6=Cr (YCbCr).
/// SC-019: maxNits 100 (SDR IRE) or 10000 (HDR PQ); inputIsPQ 1 = decode PQ to nits before binning.
/// SC-023: singleLineMode 1 = waveform shows only one scan line; singleLineRow = row index (e.g. inputHeight/2 for center).
public struct ScopePointRasterizerParams {
    public var accumWidth: UInt32
    public var accumHeight: UInt32
    public var inputWidth: UInt32
    public var inputHeight: UInt32
    public var mode: UInt32
    public var maxNits: UInt32
    public var inputIsPQ: UInt32
    public var singleLineMode: UInt32
    public var singleLineRow: UInt32

    public init(accumWidth: UInt32, accumHeight: UInt32, inputWidth: UInt32, inputHeight: UInt32, mode: UInt32 = 0, maxNits: UInt32 = 100, inputIsPQ: UInt32 = 0, singleLineMode: UInt32 = 0, singleLineRow: UInt32 = 0) {
        self.accumWidth = accumWidth
        self.accumHeight = accumHeight
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.mode = mode
        self.maxNits = maxNits
        self.inputIsPQ = inputIsPQ
        self.singleLineMode = singleLineMode
        self.singleLineRow = singleLineRow
    }
}

/// SC-003: Phosphor resolve params — gamma and gain for non-linear tone mapping in scope_accumulation_to_texture.
/// Layout must match Metal struct ScopeResolveParams. gamma < 1 brightens midtones (bloom); gain scales output.
/// SC-019: useLogScale 1 = luminance axis displayed in log10(1+nits) for waveform.
public struct ScopeResolveParams {
    public var gamma: Float
    public var gain: Float
    public var useLogScale: UInt32

    public init(gamma: Float = 1.0, gain: Float = 1.0, useLogScale: UInt32 = 0) {
        self.gamma = gamma
        self.gain = gain
        self.useLogScale = useLogScale
    }
}

/// CS-004: Gamut conversion params for gamut_convert kernel. Layout must match Metal struct GamutConversionParams.
/// clampResult: 1 = clamp output RGB to [0,1], 0 = no clamp (e.g. for XYZ or analysis).
public struct GamutConversionParams {
    public var clampResult: UInt32
    public var _pad0: UInt32
    public var _pad1: UInt32
    public var _pad2: UInt32

    public init(clampResult: UInt32 = 1, _pad0: UInt32 = 0, _pad1: UInt32 = 0, _pad2: UInt32 = 0) {
        self.clampResult = clampResult
        self._pad0 = _pad0
        self._pad1 = _pad1
        self._pad2 = _pad2
    }
}

/// General frame params for future use (format, dimensions).
/// Layout must match Metal struct FrameParams.
public struct FrameParams {
    public var width: UInt32
    public var height: UInt32
    public var pixelFormat: UInt32
    public var rowBytes: UInt32

    public init(width: UInt32, height: UInt32, pixelFormat: UInt32, rowBytes: UInt32) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.rowBytes = rowBytes
    }
}
