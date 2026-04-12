#ifndef DeckLinkBridge_h
#define DeckLinkBridge_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns number of DeckLink devices (from Discovery callback list only; 1:1 with CapturePreview sample).
int DeckLinkBridgeDeviceCount(void);

/// Fills displayName with device name for index (0-based). Returns 0 on success.
int DeckLinkBridgeDeviceName(int index, char *displayName, int maxLen);

/// Merge devices from Iterator into list by display name (no duplicates). Call on Refresh if list is empty or to pick up devices SDK did not report via callback.
void DeckLinkBridgeRefreshDeviceListFromIterator(void);

/// Returns number of display modes for device at index, or -1 on error (DL-003).
int DeckLinkBridgeDisplayModeCount(int deviceIndex);

/// Returns mode index for given BMDDisplayMode (displayModeId), or -1 if not found. Used when format change callback reports detected mode (apply detected video mode restart).
int DeckLinkBridgeModeIndexForDisplayMode(int deviceIndex, unsigned int displayModeId);

/// Fills mode info for device at deviceIndex, mode at modeIndex. Returns 0 on success. nameBuf may be NULL if nameLen is 0. outModeFlags may be NULL; if non-NULL, set to 1 when mode is supported with SDI quad-link (8K), 0 otherwise (DL-013).
int DeckLinkBridgeDisplayModeInfo(int deviceIndex, int modeIndex, char *nameBuf, int nameLen, int *outWidth, int *outHeight, double *outFrameRate, int *outModeFlags);

/// Returns 1 if device supports quad-link SDI (8K), 0 if not, -1 on error (DL-013). Uses BMDDeckLinkSupportsQuadLinkSDI.
int DeckLinkBridgeDeviceSupportsQuadLinkSDI(int deviceIndex);

// MARK: - Input connection (CapturePreview sample: SDI / HDMI / etc.)

/// Returns supported video input connections bitmask (BMDVideoConnection) for device, or -1 on error.
int64_t DeckLinkBridgeGetSupportedInputConnections(int deviceIndex);
/// Returns current video input connection (bmdDeckLinkConfigVideoInputConnection) for device, or 0 if not set.
int64_t DeckLinkBridgeGetCurrentInputConnection(int deviceIndex);
/// Sets current video input connection for device. Call before enumerating modes or starting capture. Returns 0 on success, -1 on error.
int DeckLinkBridgeSetCurrentInputConnection(int deviceIndex, int64_t connection);
/// Returns 1 if device supports input format detection (BMDDeckLinkSupportsInputFormatDetection), 0 if not, -1 on error.
int DeckLinkBridgeDeviceSupportsInputFormatDetection(int deviceIndex);

/// Frame callback: (ctx, bytes, rowBytes, width, height, pixelFormat). Called from SDK thread; copy data if needed. DL-004.
typedef void (*DeckLinkBridgeFrameCallback)(void *ctx, const void *bytes, int rowBytes, int width, int height, unsigned int pixelFormat);

/// Zero-copy frame callback (DL-005): (ctx, cvPixelBuffer, width, height, pixelFormat). cvPixelBuffer is a CVPixelBufferRef (retained); caller must release when done. Called when IDeckLinkMacVideoBuffer is available (default allocator on macOS). If NULL, bridge uses bytes callback only.
typedef void (*DeckLinkBridgeCVPixelBufferFrameCallback)(void *ctx, void *cvPixelBuffer, int width, int height, unsigned int pixelFormat);

/// Format-change callback (DL-006): (ctx, notificationEvents, displayModeId, width, height, frameRate, detectedSignalFlags). Called from SDK thread when input signal format changes. Enable format detection by passing non-NULL.
typedef void (*DeckLinkBridgeFormatChangeCallback)(void *ctx, unsigned int notificationEvents, unsigned int displayModeId, int width, int height, double frameRate, unsigned int detectedSignalFlags);

/// Audio callback (DL-010): (ctx, samples, frameCount, channels). Samples are interleaved float in [-1, 1]. Called from SDK thread when IDeckLinkAudioInputPacket is present. If non-NULL at start, EnableAudioInput is called (48kHz, 16-bit, stereo).
typedef void (*DeckLinkBridgeAudioCallback)(void *ctx, const float *samples, uint32_t frameCount, uint32_t channels);

/// Timecode callback (DL-008): (ctx, timecodeUTF8). Called from SDK thread when timecode is available for the frame (RP188/VITC). timecodeUTF8 is valid only for the duration of the callback; copy if needed.
typedef void (*DeckLinkBridgeTimecodeCallback)(void *ctx, const char *timecodeUTF8);

/// Ancillary/VANC callback (DL-009): (ctx, bytes, length, lineNumber, did, sdid, dataSpace). Called from SDK thread once per ancillary packet; bytes valid only for the duration of the callback—copy if needed. dataSpace: 0=VANC, 1=HANC.
typedef void (*DeckLinkBridgeAncillaryCallback)(void *ctx, const void *bytes, uint32_t length, uint32_t lineNumber, uint8_t did, uint8_t sdid, unsigned int dataSpace);

/// Start video capture on device. modeIndex from display mode list; pixelFormat e.g. bmdFormat10BitYUV (0x79757632). applyDetectedInputMode: 1 = enable format detection (bmdVideoInputEnableFormatDetection) when formatChangeCallback is set, 0 = fixed mode only. If cvPixelBufferCallback is non-NULL, zero-copy path is tried first. If audioCallback is non-NULL, enables embedded SDI audio (48kHz, 16-bit, 2 ch). If timecodeCallback is non-NULL, timecode (RP188/VITC) is extracted per frame and reported. If ancillaryCallback is non-NULL, VANC/HANC packets are enumerated and reported per packet.
/// Multi-device (DL-007): One active capture per deviceIndex. Concurrent captures on different devices are supported. Returns 0 on success, -1 on error (device/mode invalid, SDK failure), -2 if this deviceIndex is already capturing.
int DeckLinkBridgeStartCapture(int deviceIndex, int modeIndex, unsigned int pixelFormat, int applyDetectedInputMode, DeckLinkBridgeFrameCallback bytesCallback, void *ctx, DeckLinkBridgeFormatChangeCallback formatChangeCallback, void *formatChangeCtx, DeckLinkBridgeCVPixelBufferFrameCallback cvPixelBufferCallback, DeckLinkBridgeAudioCallback audioCallback, void *audioCtx, DeckLinkBridgeTimecodeCallback timecodeCallback, void *timecodeCtx, DeckLinkBridgeAncillaryCallback ancillaryCallback, void *ancillaryCtx);

/// Stop video capture on the given device. Only the session for this deviceIndex is stopped; other devices are unaffected (DL-007).
void DeckLinkBridgeStopCapture(int deviceIndex);

// MARK: - DL-012 Device hot-plug notifications

/// Device notification callback: (ctx, added). added: 1 = device arrived, 0 = device removed. Called from SDK thread; marshal to main thread in Swift if needed.
typedef void (*DeckLinkBridgeDeviceNotificationCallback)(void *ctx, int added);

/// Set the callback and context used when device notifications are active. Call before StartDeviceNotifications.
void DeckLinkBridgeSetDeviceNotificationCallback(DeckLinkBridgeDeviceNotificationCallback callback, void *ctx);

/// Start subscribing to device arrival/removal. Uses IDeckLinkDiscovery::InstallDeviceNotifications. Returns 0 on success, -1 on error.
int DeckLinkBridgeStartDeviceNotifications(void);

/// Stop device notifications (UninstallDeviceNotifications). Safe to call even if not started.
void DeckLinkBridgeStopDeviceNotifications(void);

#ifdef __cplusplus
}
#endif

#endif /* DeckLinkBridge_h */
