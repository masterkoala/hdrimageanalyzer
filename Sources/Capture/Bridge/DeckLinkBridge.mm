#import "DeckLinkBridge.h"
#import "DeckLinkAPI.h"
#import "DeckLinkAPIConfiguration.h"
#import "DeckLinkAPIVideoFrame_v14_2_1.h"
#import <CoreFoundation/CFPlugInCOM.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <Foundation/Foundation.h>
#include <string.h>
#include <map>
#include <mutex>
#include <vector>

/// DL-008: Try to get timecode string from frame (RP188 Any, then LTC, VITC1, VITC). Writes UTF-8 into outBuf (max outBufLen bytes). Returns true if a non-empty string was written.
static bool GetTimecodeStringFromFrame(IDeckLinkVideoInputFrame *videoFrame, char *outBuf, size_t outBufLen) {
    if (!videoFrame || !outBuf || outBufLen == 0) return false;
    outBuf[0] = '\0';
    static const BMDTimecodeFormat kFormats[] = {
        bmdTimecodeRP188Any,
        bmdTimecodeRP188LTC,
        bmdTimecodeRP188VITC1,
        bmdTimecodeVITC
    };
    for (BMDTimecodeFormat format : kFormats) {
        IDeckLinkTimecode *timecode = nullptr;
        if (videoFrame->GetTimecode(format, &timecode) != S_OK || !timecode) continue;
        CFStringRef cfStr = nullptr;
        if (timecode->GetString(&cfStr) != S_OK || !cfStr) {
            timecode->Release();
            continue;
        }
        Boolean ok = CFStringGetCString(cfStr, outBuf, (CFIndex)outBufLen, kCFStringEncodingUTF8);
        CFRelease(cfStr);
        timecode->Release();
        if (ok && outBuf[0] != '\0') return true;
    }
    return false;
}

static const REFIID s_IID_IUnknown = CFUUIDGetUUIDBytes(IUnknownUUID);

static IDeckLinkIterator *CreateIterator(void) {
    return CreateDeckLinkIteratorInstance();
}

// MARK: - Device list (CapturePreview sample: list ONLY from Discovery callbacks — no Iterator; sample never uses Iterator for device list)

static std::mutex s_deviceListMutex;
static std::vector<IDeckLink*> s_devices;  // refcounted: AddRef when adding, Release when removing

static std::string GetDeviceDisplayName(IDeckLink *dl);

// MARK: - DL-012 Device hot-plug (IDeckLinkDeviceNotificationCallback) — CapturePreview: addDevice/removeDevice

class DeviceNotificationCallback : public IDeckLinkDeviceNotificationCallback {
public:
    DeviceNotificationCallback(DeckLinkBridgeDeviceNotificationCallback cb, void *ctx)
        : m_cb(cb), m_ctx(ctx), m_refCount(1) {}
    virtual ~DeviceNotificationCallback() {}

    ULONG AddRef() override { return __sync_add_and_fetch(&m_refCount, 1); }
    ULONG Release() override {
        ULONG n = __sync_sub_and_fetch(&m_refCount, 1);
        if (n == 0) delete this;
        return n;
    }
    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (!ppv) return E_POINTER;
        if (memcmp(&iid, &IID_IDeckLinkDeviceNotificationCallback, sizeof(REFIID)) == 0 || memcmp(&iid, &s_IID_IUnknown, sizeof(REFIID)) == 0) {
            *ppv = this;
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    HRESULT DeckLinkDeviceArrived(IDeckLink *deckLinkDevice) override {
        if (!deckLinkDevice) return S_OK;
        std::string newName = GetDeviceDisplayName(deckLinkDevice);
        std::lock_guard<std::mutex> lock(s_deviceListMutex);
        for (IDeckLink *p : s_devices) {
            if (p == deckLinkDevice) {
                if (m_cb) m_cb(m_ctx, 1);
                return S_OK;  // same pointer already in list
            }
        }
        // Deduplicate by name: if we already have a device with this name (e.g. from Iterator merge), replace it with this callback pointer.
        for (size_t i = 0; i < s_devices.size(); ++i) {
            if (GetDeviceDisplayName(s_devices[i]) == newName) {
                s_devices[i]->Release();
                deckLinkDevice->AddRef();
                s_devices[i] = deckLinkDevice;
                if (m_cb) m_cb(m_ctx, 1);
                return S_OK;
            }
        }
        deckLinkDevice->AddRef();
        s_devices.push_back(deckLinkDevice);
        if (m_cb) m_cb(m_ctx, 1);
        return S_OK;
    }
    HRESULT DeckLinkDeviceRemoved(IDeckLink *deckLinkDevice) override {
        if (!deckLinkDevice) return S_OK;
        std::lock_guard<std::mutex> lock(s_deviceListMutex);
        for (auto it = s_devices.begin(); it != s_devices.end(); ++it) {
            if (*it == deckLinkDevice) {
                (*it)->Release();
                s_devices.erase(it);
                break;
            }
        }
        if (m_cb) m_cb(m_ctx, 0);
        return S_OK;
    }

private:
    DeckLinkBridgeDeviceNotificationCallback m_cb;
    void *m_ctx;
    ULONG m_refCount;
};

static std::mutex s_notificationMutex;
static IDeckLinkDiscovery *s_discovery = nullptr;
static DeviceNotificationCallback *s_notificationCallback = nullptr;
static DeckLinkBridgeDeviceNotificationCallback s_userNotificationCb = nullptr;
static void *s_userNotificationCtx = nullptr;

/// Get IDeckLink at index (caller must Release). Uses device list from Discovery + initial enumeration.
static IDeckLink *GetDeviceAt(int index) {
    std::lock_guard<std::mutex> lock(s_deviceListMutex);
    if (index < 0 || (size_t)index >= s_devices.size()) return nullptr;
    IDeckLink *dl = s_devices[(size_t)index];
    dl->AddRef();
    return dl;
}

int DeckLinkBridgeDeviceCount(void) {
    std::lock_guard<std::mutex> lock(s_deviceListMutex);
    return (int)s_devices.size();
}

std::string GetDeviceDisplayName(IDeckLink *dl) {
    if (!dl) return "";
    CFStringRef cfName = nullptr;
    if (dl->GetDisplayName(&cfName) != S_OK || !cfName) return "";
    NSString *ns = (__bridge_transfer NSString *)cfName;
    if (!ns) return "";
    const char *cstr = [ns UTF8String];
    return cstr ? std::string(cstr) : "";
}

void DeckLinkBridgeRefreshDeviceListFromIterator(void) {
    IDeckLinkIterator *iter = CreateIterator();
    if (!iter) return;
    IDeckLink *dl = nullptr;
    std::vector<std::string> existingNames;
    {
        std::lock_guard<std::mutex> lock(s_deviceListMutex);
        for (IDeckLink *p : s_devices)
            existingNames.push_back(GetDeviceDisplayName(p));
        while (iter->Next(&dl) == S_OK && dl) {
            std::string name = GetDeviceDisplayName(dl);
            bool found = false;
            for (const std::string &n : existingNames) {
                if (n == name) { found = true; break; }
            }
            if (!found) {
                dl->AddRef();
                s_devices.push_back(dl);
                existingNames.push_back(name);
            }
            dl->Release();
        }
    }
    iter->Release();
}

int DeckLinkBridgeDeviceName(int index, char *displayName, int maxLen) {
    if (!displayName || maxLen <= 0) return -1;
    displayName[0] = '\0';
    IDeckLink *dl = GetDeviceAt(index);
    if (!dl) return -1;
    CFStringRef cfName = nullptr;
    HRESULT hr = dl->GetDisplayName(&cfName);
    dl->Release();
    if (hr != S_OK || !cfName) return -1;
    NSString *ns = (__bridge_transfer NSString *)cfName;
    if (ns) {
        const char *cstr = [ns UTF8String];
        if (cstr) strncpy(displayName, cstr, (size_t)(maxLen - 1));
        displayName[maxLen - 1] = '\0';
    }
    return 0;
}

/// Get current input connection for device (from IDeckLinkConfiguration). Returns bmdVideoConnectionUnspecified (0) if not set or error.
static BMDVideoConnection GetCurrentInputConnectionForDevice(IDeckLink *dl) {
    if (!dl) return bmdVideoConnectionUnspecified;
    IDeckLinkConfiguration *config = nullptr;
    if (dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&config) != S_OK || !config)
        return bmdVideoConnectionUnspecified;
    int64_t conn = 0;
    config->GetInt(bmdDeckLinkConfigVideoInputConnection, &conn);
    config->Release();
    return (BMDVideoConnection)conn;
}

// MARK: - Input connection API (CapturePreview sample parity)

int64_t DeckLinkBridgeGetSupportedInputConnections(int deviceIndex) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return -1;
    IDeckLinkProfileAttributes *attrs = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attrs);
    dl->Release();
    if (hr != S_OK || !attrs) return -1;
    int64_t val = 0;
    hr = attrs->GetInt(BMDDeckLinkVideoInputConnections, &val);
    attrs->Release();
    return (hr == S_OK) ? val : -1;
}

int64_t DeckLinkBridgeGetCurrentInputConnection(int deviceIndex) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return 0;
    IDeckLinkConfiguration *config = nullptr;
    if (dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&config) != S_OK || !config) {
        dl->Release();
        return 0;
    }
    int64_t conn = 0;
    config->GetInt(bmdDeckLinkConfigVideoInputConnection, &conn);
    config->Release();
    dl->Release();
    return conn;
}

int DeckLinkBridgeSetCurrentInputConnection(int deviceIndex, int64_t connection) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return -1;
    IDeckLinkConfiguration *config = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&config);
    dl->Release();
    if (hr != S_OK || !config) return -1;
    hr = config->SetInt(bmdDeckLinkConfigVideoInputConnection, connection);
    config->Release();
    return (hr == S_OK) ? 0 : -1;
}

int DeckLinkBridgeDeviceSupportsInputFormatDetection(int deviceIndex) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return -1;
    IDeckLinkProfileAttributes *attrs = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attrs);
    dl->Release();
    if (hr != S_OK || !attrs) return -1;
    bool flag = false;
    hr = attrs->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &flag);
    attrs->Release();
    return (hr == S_OK) ? (flag ? 1 : 0) : -1;
}

/// Count display modes supported for the device's current input connection (CapturePreview: DoesSupportVideoMode per mode).
int DeckLinkBridgeDisplayModeCount(int deviceIndex) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return -1;
    BMDVideoConnection connection = GetCurrentInputConnectionForDevice(dl);
    if (connection == 0)
        connection = bmdVideoConnectionUnspecified;
    IDeckLinkInput *input = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkInput, (void **)&input);
    dl->Release();
    if (hr != S_OK || !input) return -1;
    IDeckLinkDisplayModeIterator *iter = nullptr;
    hr = input->GetDisplayModeIterator(&iter);
    if (hr != S_OK || !iter) {
        input->Release();
        return -1;
    }
    int n = 0;
    IDeckLinkDisplayMode *mode = nullptr;
    while (iter->Next(&mode) == S_OK && mode) {
        BMDDisplayMode actualMode = (BMDDisplayMode)0;
        bool supported = false;
        if (input->DoesSupportVideoMode(connection, mode->GetDisplayMode(), bmdFormatUnspecified, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, &actualMode, &supported) == S_OK && supported)
            n++;
        mode->Release();
    }
    iter->Release();
    input->Release();
    return n;
}

int DeckLinkBridgeDisplayModeInfo(int deviceIndex, int modeIndex, char *nameBuf, int nameLen, int *outWidth, int *outHeight, double *outFrameRate, int *outModeFlags) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return -1;
    BMDVideoConnection connection = GetCurrentInputConnectionForDevice(dl);
    if (connection == 0)
        connection = bmdVideoConnectionUnspecified;
    IDeckLinkInput *input = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkInput, (void **)&input);
    dl->Release();
    if (hr != S_OK || !input) return -1;
    IDeckLinkDisplayModeIterator *modeIter = nullptr;
    hr = input->GetDisplayModeIterator(&modeIter);
    if (hr != S_OK || !modeIter) {
        input->Release();
        return -1;
    }
    IDeckLinkDisplayMode *mode = nullptr;
    int supportedIndex = 0;
    while (modeIter->Next(&mode) == S_OK && mode) {
        BMDDisplayMode actualMode = (BMDDisplayMode)0;
        bool supported = false;
        if (input->DoesSupportVideoMode(connection, mode->GetDisplayMode(), bmdFormatUnspecified, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, &actualMode, &supported) != S_OK || !supported) {
            mode->Release();
            continue;
        }
        if (supportedIndex == modeIndex) {
            if (outWidth) *outWidth = (int)mode->GetWidth();
            if (outHeight) *outHeight = (int)mode->GetHeight();
            BMDTimeValue duration = 0, scale = 0;
            if (outFrameRate && mode->GetFrameRate(&duration, &scale) == S_OK && duration > 0 && scale > 0) {
                *outFrameRate = (double)scale / (double)duration;
            } else if (outFrameRate) {
                *outFrameRate = 0.0;
            }
            if (outModeFlags)
                *outModeFlags = 1;
            if (nameBuf && nameLen > 0) {
                nameBuf[0] = '\0';
                CFStringRef cfName = nullptr;
                if (mode->GetName(&cfName) == S_OK && cfName) {
                    NSString *ns = (__bridge_transfer NSString *)cfName;
                    if (ns) {
                        const char *cstr = [ns UTF8String];
                        if (cstr) {
                            strncpy(nameBuf, cstr, (size_t)(nameLen - 1));
                            nameBuf[nameLen - 1] = '\0';
                        }
                    }
                }
            }
            mode->Release();
            modeIter->Release();
            input->Release();
            return 0;
        }
        mode->Release();
        supportedIndex++;
    }
    modeIter->Release();
    input->Release();
    return -1;
}

int DeckLinkBridgeDeviceSupportsQuadLinkSDI(int deviceIndex) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return -1;
    IDeckLinkProfileAttributes *attrs = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attrs);
    dl->Release();
    if (hr != S_OK || !attrs) return -1;
    bool flag = false;
    hr = attrs->GetFlag(BMDDeckLinkSupportsQuadLinkSDI, &flag);
    attrs->Release();
    if (hr != S_OK) return -1;
    return flag ? 1 : 0;
}

// MARK: - DL-004 Capture (IDeckLinkInputCallback)

static BMDDisplayMode GetDisplayModeAt(int deviceIndex, int modeIndex) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return (BMDDisplayMode)0;
    BMDVideoConnection connection = GetCurrentInputConnectionForDevice(dl);
    if (connection == 0)
        connection = bmdVideoConnectionUnspecified;
    IDeckLinkInput *input = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkInput, (void **)&input);
    dl->Release();
    if (hr != S_OK || !input) return (BMDDisplayMode)0;
    IDeckLinkDisplayModeIterator *iter = nullptr;
    hr = input->GetDisplayModeIterator(&iter);
    if (hr != S_OK || !iter) {
        input->Release();
        return (BMDDisplayMode)0;
    }
    IDeckLinkDisplayMode *mode = nullptr;
    BMDDisplayMode result = (BMDDisplayMode)0;
    int supportedIndex = 0;
    while (iter->Next(&mode) == S_OK && mode) {
        BMDDisplayMode actualMode = (BMDDisplayMode)0;
        bool supported = false;
        if (input->DoesSupportVideoMode(connection, mode->GetDisplayMode(), bmdFormatUnspecified, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, &actualMode, &supported) != S_OK || !supported) {
            mode->Release();
            continue;
        }
        if (supportedIndex == modeIndex) {
            result = mode->GetDisplayMode();
            mode->Release();
            iter->Release();
            input->Release();
            return result;
        }
        mode->Release();
        supportedIndex++;
    }
    iter->Release();
    input->Release();
    return (BMDDisplayMode)0;
}

/// Find mode index for displayModeId (BMDDisplayMode). Returns -1 if not found. Used for format-change restart (QuadPreview: apply detected mode).
static int ModeIndexForDisplayMode(int deviceIndex, BMDDisplayMode displayModeId) {
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return -1;
    BMDVideoConnection connection = GetCurrentInputConnectionForDevice(dl);
    if (connection == 0)
        connection = bmdVideoConnectionUnspecified;
    IDeckLinkInput *input = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkInput, (void **)&input);
    dl->Release();
    if (hr != S_OK || !input) return -1;
    IDeckLinkDisplayModeIterator *iter = nullptr;
    hr = input->GetDisplayModeIterator(&iter);
    if (hr != S_OK || !iter) {
        input->Release();
        return -1;
    }
    IDeckLinkDisplayMode *mode = nullptr;
    int supportedIndex = 0;
    while (iter->Next(&mode) == S_OK && mode) {
        BMDDisplayMode actualMode = (BMDDisplayMode)0;
        bool supported = false;
        if (input->DoesSupportVideoMode(connection, mode->GetDisplayMode(), bmdFormatUnspecified, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, &actualMode, &supported) != S_OK || !supported) {
            mode->Release();
            continue;
        }
        if (mode->GetDisplayMode() == displayModeId) {
            iter->Release();
            input->Release();
            mode->Release();
            return supportedIndex;
        }
        mode->Release();
        supportedIndex++;
    }
    iter->Release();
    input->Release();
    return -1;
}

int DeckLinkBridgeModeIndexForDisplayMode(int deviceIndex, unsigned int displayModeId) {
    return ModeIndexForDisplayMode(deviceIndex, (BMDDisplayMode)displayModeId);
}

/// DL-009: Enumerate VANC/HANC packets from frame (IDeckLinkVideoFrameAncillaryPackets) and invoke callback for each packet.
static void DeliverAncillaryFromFrame(IDeckLinkVideoInputFrame *videoFrame, DeckLinkBridgeAncillaryCallback cb, void *ctx) {
    if (!videoFrame || !cb || !ctx) return;
    IDeckLinkVideoFrameAncillaryPackets *packets = nullptr;
    if (videoFrame->QueryInterface(IID_IDeckLinkVideoFrameAncillaryPackets, (void **)&packets) != S_OK || !packets) return;
    IDeckLinkAncillaryPacketIterator *it = nullptr;
    if (packets->GetPacketIterator(&it) != S_OK || !it) {
        packets->Release();
        return;
    }
    IDeckLinkAncillaryPacket *pkt = nullptr;
    while (it->Next(&pkt) == S_OK && pkt) {
        const void *data = nullptr;
        uint32_t size = 0;
        if (pkt->GetBytes(bmdAncillaryPacketFormatUInt8, &data, &size) == S_OK && data && size > 0) {
            cb(ctx, data, size, (uint32_t)pkt->GetLineNumber(), pkt->GetDID(), pkt->GetSDID(), (unsigned int)pkt->GetDataSpace());
        }
        pkt->Release();
        pkt = nullptr;
    }
    it->Release();
    packets->Release();
}

class FrameCaptureCallback : public IDeckLinkInputCallback {
public:
    FrameCaptureCallback(DeckLinkBridgeFrameCallback cb, void *ctx, BMDPixelFormat pixelFormat,
                         DeckLinkBridgeFormatChangeCallback formatChangeCb, void *formatChangeCtx,
                         DeckLinkBridgeCVPixelBufferFrameCallback cvCb,
                         DeckLinkBridgeAudioCallback audioCb, void *audioCtx, BMDAudioSampleType audioSampleType, uint32_t audioChannels,
                         DeckLinkBridgeTimecodeCallback timecodeCb, void *timecodeCtx,
                         DeckLinkBridgeAncillaryCallback ancillaryCb, void *ancillaryCtx)
        : m_cb(cb), m_ctx(ctx), m_pixelFormat(pixelFormat), m_formatChangeCb(formatChangeCb), m_formatChangeCtx(formatChangeCtx), m_cvCb(cvCb),
          m_audioCb(audioCb), m_audioCtx(audioCtx), m_audioSampleType(audioSampleType), m_audioChannels(audioChannels),
          m_timecodeCb(timecodeCb), m_timecodeCtx(timecodeCtx), m_ancillaryCb(ancillaryCb), m_ancillaryCtx(ancillaryCtx), m_refCount(1) {}
    virtual ~FrameCaptureCallback() {}

    ULONG AddRef() override { return __sync_add_and_fetch(&m_refCount, 1); }
    ULONG Release() override {
        ULONG n = __sync_sub_and_fetch(&m_refCount, 1);
        if (n == 0) delete this;
        return n;
    }
    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (!ppv) return E_POINTER;
        if (memcmp(&iid, &IID_IDeckLinkInputCallback, sizeof(REFIID)) == 0 || memcmp(&iid, &s_IID_IUnknown, sizeof(REFIID)) == 0) {
            *ppv = this;
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents notificationEvents, IDeckLinkDisplayMode *newDisplayMode, BMDDetectedVideoInputFormatFlags detectedSignalFlags) override {
        if (m_formatChangeCb && newDisplayMode) {
            BMDTimeValue duration = 0, scale = 0;
            double frameRate = 0.0;
            if (newDisplayMode->GetFrameRate(&duration, &scale) == S_OK && duration > 0 && scale > 0)
                frameRate = (double)scale / (double)duration;
            m_formatChangeCb(m_formatChangeCtx, (unsigned int)notificationEvents, (unsigned int)newDisplayMode->GetDisplayMode(),
                            (int)newDisplayMode->GetWidth(), (int)newDisplayMode->GetHeight(), frameRate, (unsigned int)detectedSignalFlags);
        }
        return S_OK;
    }
    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *videoFrame, IDeckLinkAudioInputPacket *audioPacket) override {
        // DL-010: Handle embedded SDI audio when optional callback is set.
        if (audioPacket && m_audioCb && m_audioChannels > 0) {
            void *rawBuf = nullptr;
            if (audioPacket->GetBytes(&rawBuf) == S_OK && rawBuf) {
                long frameCount = audioPacket->GetSampleFrameCount();
                if (frameCount > 0) {
                    size_t totalSamples = (size_t)frameCount * (size_t)m_audioChannels;
                    std::vector<float> floatBuf(totalSamples);
                    if (m_audioSampleType == bmdAudioSampleType16bitInteger) {
                        const int16_t *src = (const int16_t *)rawBuf;
                        for (size_t i = 0; i < totalSamples; i++)
                            floatBuf[i] = (float)src[i] / 32768.0f;
                    } else {
                        const int32_t *src = (const int32_t *)rawBuf;
                        for (size_t i = 0; i < totalSamples; i++)
                            floatBuf[i] = (float)src[i] / 2147483648.0f;
                    }
                    m_audioCb(m_audioCtx, floatBuf.data(), (uint32_t)frameCount, m_audioChannels);
                }
            }
        }

        if (!videoFrame) return S_OK;

        // DL-008: Timecode (RP188/VITC) — report to Swift if callback set
        if (m_timecodeCb && m_timecodeCtx) {
            char timecodeBuf[64];
            if (GetTimecodeStringFromFrame(videoFrame, timecodeBuf, sizeof(timecodeBuf)))
                m_timecodeCb(m_timecodeCtx, timecodeBuf);
        }

        // DL-009: VANC/HANC ancillary packets — enumerate and report each packet to Swift if callback set
        if (m_ancillaryCb && m_ancillaryCtx)
            DeliverAncillaryFromFrame(videoFrame, m_ancillaryCb, m_ancillaryCtx);

        long width = videoFrame->GetWidth();
        long height = videoFrame->GetHeight();
        long rowBytes = videoFrame->GetRowBytes();
        BMDPixelFormat pf = videoFrame->GetPixelFormat();

        // Log first frame details for diagnostics
        static int sFrameLogCount = 0;
        if (sFrameLogCount < 3) {
            char pfStr[5] = {0};
            pfStr[0] = (char)((pf >> 24) & 0xFF);
            pfStr[1] = (char)((pf >> 16) & 0xFF);
            pfStr[2] = (char)((pf >> 8) & 0xFF);
            pfStr[3] = (char)(pf & 0xFF);
            NSLog(@"DeckLink frame[%d]: %ldx%ld rowBytes=%ld pf=0x%08X ('%s') requested=0x%08X",
                  sFrameLogCount, width, height, rowBytes, (unsigned)pf, pfStr, (unsigned)m_pixelFormat);
            sFrameLogCount++;
        }

        // DL-005: Use CVPixelBuffer only when format is 32BGRA (pipeline has direct support).
        // v210/422YpCbCr10 etc. fall through to bytes path for correct decode.
        if (m_cvCb) {
            IDeckLinkMacVideoBuffer *macBuf = nullptr;
            if (videoFrame->QueryInterface(IID_IDeckLinkMacVideoBuffer, (void **)&macBuf) == S_OK && macBuf) {
                CVPixelBufferRef cvBuf = nullptr;
                HRESULT hr = macBuf->CreateCVPixelBufferRef((void **)&cvBuf);
                macBuf->Release();
                if (hr == S_OK && cvBuf) {
                    OSType cvFormat = CVPixelBufferGetPixelFormatType(cvBuf);
                    if (cvFormat == kCVPixelFormatType_32BGRA) {
                        m_cvCb(m_ctx, cvBuf, (int)width, (int)height, (unsigned int)pf);
                        return S_OK;
                    }
                    CFRelease(cvBuf);
                }
            }
        }

        // Bytes path (copy): raw frame data — v210, R12L, etc.
        // IDeckLinkVideoInputFrame (latest SDK) does NOT have GetBytes() directly.
        // Must QI to IDeckLinkVideoFrame_v14_2_1 (which has GetBytes) or IDeckLinkVideoBuffer.
        if (!m_cb) return S_OK;
        void *bytes = nullptr;
        HRESULT hr = E_FAIL;

        // Primary: v14.2.1 interface (has GetBytes on IDeckLinkVideoFrame_v14_2_1)
        IDeckLinkVideoFrame_v14_2_1 *frame14 = nullptr;
        if (videoFrame->QueryInterface(IID_IDeckLinkVideoFrame_v14_2_1, (void **)&frame14) == S_OK && frame14) {
            hr = frame14->GetBytes(&bytes);
            frame14->Release();
        }

        // Fallback: IDeckLinkVideoBuffer interface (latest SDK path)
        if (hr != S_OK || !bytes) {
            IDeckLinkVideoBuffer *videoBuf = nullptr;
            if (videoFrame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&videoBuf) == S_OK && videoBuf) {
                hr = videoBuf->GetBytes(&bytes);
                videoBuf->Release();
            }
        }

        if (hr != S_OK || !bytes) {
            static int sGetBytesFailCount = 0;
            if (sGetBytesFailCount < 5) {
                NSLog(@"DeckLink: GetBytes failed (v14.2.1 + VideoBuffer QI) hr=0x%08X bytes=%p pf=0x%X %ldx%ld", (unsigned)hr, bytes, (unsigned)pf, width, height);
                sGetBytesFailCount++;
            }
            return S_OK;
        }

        // Diagnostic: check first bytes of frame data for non-zero content
        static int sByteDiagCount = 0;
        if (sByteDiagCount < 5) {
            const uint32_t *words = (const uint32_t *)bytes;
            long totalBytes = rowBytes * height;
            bool allZero = true;
            long checkLen = (totalBytes < 64) ? totalBytes : 64;
            for (long i = 0; i < checkLen; i++) {
                if (((const uint8_t *)bytes)[i] != 0) { allZero = false; break; }
            }
            NSLog(@"DeckLink bytes[%d]: first4=[0x%08X 0x%08X 0x%08X 0x%08X] allZero=%d total=%ld pf=0x%X",
                  sByteDiagCount, words[0], words[1], words[2], words[3], allZero ? 1 : 0, totalBytes, (unsigned)pf);
            sByteDiagCount++;
        }

        m_cb(m_ctx, bytes, (int)rowBytes, (int)width, (int)height, (unsigned int)pf);
        return S_OK;
    }

private:
    DeckLinkBridgeFrameCallback m_cb;
    void *m_ctx;
    BMDPixelFormat m_pixelFormat;
    DeckLinkBridgeFormatChangeCallback m_formatChangeCb;
    void *m_formatChangeCtx;
    DeckLinkBridgeCVPixelBufferFrameCallback m_cvCb;
    DeckLinkBridgeAudioCallback m_audioCb;
    void *m_audioCtx;
    BMDAudioSampleType m_audioSampleType;
    uint32_t m_audioChannels;
    DeckLinkBridgeTimecodeCallback m_timecodeCb;
    void *m_timecodeCtx;
    DeckLinkBridgeAncillaryCallback m_ancillaryCb;
    void *m_ancillaryCtx;
    ULONG m_refCount;
};

struct CaptureState {
    IDeckLink *device = nullptr;
    IDeckLinkInput *input = nullptr;
    FrameCaptureCallback *callback = nullptr;
};
static std::mutex s_captureMutex;
static std::map<int, CaptureState> s_captureState;

int DeckLinkBridgeStartCapture(int deviceIndex, int modeIndex, unsigned int pixelFormat, int applyDetectedInputMode, DeckLinkBridgeFrameCallback callback, void *ctx, DeckLinkBridgeFormatChangeCallback formatChangeCallback, void *formatChangeCtx, DeckLinkBridgeCVPixelBufferFrameCallback cvPixelBufferCallback, DeckLinkBridgeAudioCallback audioCallback, void *audioCtx, DeckLinkBridgeTimecodeCallback timecodeCallback, void *timecodeCtx, DeckLinkBridgeAncillaryCallback ancillaryCallback, void *ancillaryCtx) {
    if (!callback && !cvPixelBufferCallback) return -1;
    std::lock_guard<std::mutex> lock(s_captureMutex);
    auto it = s_captureState.find(deviceIndex);
    if (it != s_captureState.end()) {
        return -2; // already capturing
    }
    IDeckLink *dl = GetDeviceAt(deviceIndex);
    if (!dl) return -1;
    IDeckLinkInput *input = nullptr;
    HRESULT hr = dl->QueryInterface(IID_IDeckLinkInput, (void **)&input);
    if (hr != S_OK || !input) {
        dl->Release();
        return -1;
    }
    BMDDisplayMode mode = GetDisplayModeAt(deviceIndex, modeIndex);
    if (!mode) {
        NSLog(@"DeckLink StartCapture: invalid mode (device=%d modeIndex=%d)", deviceIndex, modeIndex);
        input->Release();
        dl->Release();
        return -1;
    }
    const uint32_t kAudioChannels = 2;
    BMDAudioSampleType audioSampleType = bmdAudioSampleType16bitInteger;
    FrameCaptureCallback *cb = new FrameCaptureCallback(callback, ctx, (BMDPixelFormat)pixelFormat, formatChangeCallback, formatChangeCtx, cvPixelBufferCallback, audioCallback, audioCtx, audioSampleType, audioCallback ? kAudioChannels : 0, timecodeCallback, timecodeCtx, ancillaryCallback, ancillaryCtx);
    // CapturePreview: videoInputFlags = (supportsFormatDetection && applyDetectedInputMode) ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault
    BMDVideoInputFlags inputFlags = (applyDetectedInputMode != 0) ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault;
    hr = input->EnableVideoInput(mode, (BMDPixelFormat)pixelFormat, inputFlags);
    if (hr != S_OK) {
        // Fallback: try common pixel formats if the requested one is unsupported (e.g. UltraStudio 4K SDI).
        NSLog(@"DeckLink StartCapture: EnableVideoInput failed with requested pixelFormat=0x%X hr=0x%08X, trying fallbacks", (unsigned)pixelFormat, (unsigned)hr);
        BMDPixelFormat fallbacks[] = { bmdFormat10BitYUV, bmdFormat8BitBGRA, bmdFormat12BitRGBLE };
        bool enabledFallback = false;
        for (int i = 0; i < 3; i++) {
            if ((BMDPixelFormat)pixelFormat == fallbacks[i]) continue;  // already tried
            hr = input->EnableVideoInput(mode, fallbacks[i], inputFlags);
            if (hr == S_OK) {
                NSLog(@"DeckLink StartCapture: fallback pixelFormat=0x%X succeeded", (unsigned)fallbacks[i]);
                enabledFallback = true;
                break;
            }
        }
        if (!enabledFallback) {
            NSLog(@"DeckLink StartCapture: all pixel format fallbacks failed mode=0x%08X", (unsigned)mode);
            cb->Release();
            input->Release();
            dl->Release();
            return -1;
        }
    }
    if (audioCallback) {
        hr = input->EnableAudioInput(bmdAudioSampleRate48kHz, audioSampleType, kAudioChannels);
        if (hr != S_OK) {
            input->DisableVideoInput();
            cb->Release();
            input->Release();
            dl->Release();
            return -1;
        }
    }
    hr = input->SetCallback(cb);
    if (hr != S_OK) {
        NSLog(@"DeckLink StartCapture: SetCallback failed hr=0x%08X", (unsigned)hr);
        if (audioCallback) input->DisableAudioInput();
        input->DisableVideoInput();
        cb->Release();
        input->Release();
        dl->Release();
        return -1;
    }
    hr = input->StartStreams();
    if (hr != S_OK) {
        NSLog(@"DeckLink StartCapture: StartStreams failed hr=0x%08X", (unsigned)hr);
        input->SetCallback(nullptr);
        if (audioCallback) input->DisableAudioInput();
        input->DisableVideoInput();
        cb->Release();
        input->Release();
        dl->Release();
        return -1;
    }
    dl->AddRef();
    s_captureState[deviceIndex] = { dl, input, cb };
    cb->Release();
    return 0;
}

void DeckLinkBridgeStopCapture(int deviceIndex) {
    std::lock_guard<std::mutex> lock(s_captureMutex);
    auto it = s_captureState.find(deviceIndex);
    if (it == s_captureState.end()) return;
    it->second.input->StopStreams();
    it->second.input->SetCallback(nullptr);
    it->second.input->DisableAudioInput();
    it->second.input->DisableVideoInput();
    it->second.input->Release();
    it->second.device->Release();
    s_captureState.erase(it);
}

// MARK: - DL-012 Device hot-plug API

void DeckLinkBridgeSetDeviceNotificationCallback(DeckLinkBridgeDeviceNotificationCallback callback, void *ctx) {
    std::lock_guard<std::mutex> lock(s_notificationMutex);
    s_userNotificationCb = callback;
    s_userNotificationCtx = ctx;
}

int DeckLinkBridgeStartDeviceNotifications(void) {
    std::lock_guard<std::mutex> lock(s_notificationMutex);
    if (s_notificationCallback != nullptr)
        return 0; // already installed
    if (!s_discovery)
        s_discovery = CreateDeckLinkDiscoveryInstance();
    if (!s_discovery)
        return -1;
    // Sample uses only InstallDeviceNotifications; SDK calls DeckLinkDeviceArrived for each device (including already-connected). No Iterator.
    s_notificationCallback = new DeviceNotificationCallback(s_userNotificationCb, s_userNotificationCtx);
    HRESULT hr = s_discovery->InstallDeviceNotifications(s_notificationCallback);
    if (hr != S_OK) {
        s_notificationCallback->Release();
        s_notificationCallback = nullptr;
        return -1;
    }
    return 0;
}

void DeckLinkBridgeStopDeviceNotifications(void) {
    std::lock_guard<std::mutex> lock(s_notificationMutex);
    if (!s_discovery || !s_notificationCallback)
        return;
    s_discovery->UninstallDeviceNotifications();
    s_notificationCallback->Release();
    s_notificationCallback = nullptr;
}
