#import "MoonlightSession.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CFNetwork/CFNetwork.h>
#import <Limelight.h>
#import <opus_multistream.h>
#import <string.h>
#include <atomic>

/// True when an active VPN/tunnel interface is up (Tailscale, WireGuard, …).
/// Mirrors moonlight-ios Utils.m: the scoped proxy-settings dictionary lists
/// per-interface keys; tunnels show up as utun/tap/tun/ppp/ipsec.
static BOOL VLIsVpnActive(void) {
    BOOL active = NO;
    CFDictionaryRef settings = CFNetworkCopySystemProxySettings();
    if (settings) {
        NSDictionary *scoped = ((__bridge NSDictionary *)settings)[@"__SCOPED__"];
        for (NSString *key in scoped.allKeys) {
            if ([key containsString:@"utun"] || [key containsString:@"tap"] ||
                [key containsString:@"tun"] || [key containsString:@"ppp"] ||
                [key containsString:@"ipsec"]) { active = YES; break; }
        }
        CFRelease(settings);
    }
    return active;
}

// moonlight-common-c is a single-connection C library whose callbacks are global
// function pointers, so we keep one active session and forward to it. (Same model
// as moonlight-ios Connection.m.)
//
// Two references, deliberately: sActive is the callback sink and is ONLY
// assigned on the lifecycle queue right before LiStartConnection — after the
// previous connection's teardown has fully drained on that same serial queue —
// so a dying connection's late callbacks (stageFailed/terminated/frames) can
// never misroute into the next session (phantom .ending on a fresh stream).
// sPending marks the most recently start()ed session for supersession checks.
static __weak MoonlightSession *sActive = nil;
static __weak MoonlightSession *sPending = nil;

// LiStartConnection / LiStopConnection must never overlap — the library holds one
// connection's worth of global state, and a second LiStartConnection before the
// first is torn down double-frees (seen on-device as a malloc crash) and mixes up
// the per-session AES keys (stale audio packets then fail to decrypt). Serializing
// every lifecycle call through one queue guarantees old-stop-then-new-start
// ordering. LiStartConnection returns once the connection is established (the
// session then runs on its own internal threads), so a serial queue never
// deadlocks; LiInterruptConnection is called inline to unblock an in-flight start.
static dispatch_queue_t LifecycleQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.vibelight.moonlight.lifecycle", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// Latched when the host rejects LiSendTouchEvent (older Sunshine): route all
// subsequent touches through the absolute-mouse fallback without re-asking.
static BOOL sNativeTouchUnsupported = NO;
// Mouse-fallback state (mirrors moonlight-ios AbsoluteTouchHandler): a single
// gesture owner (whichever pointer went down first — NOT slot 0, which gets
// reassigned to later fingers mid-gesture), plus the last tap-up for the
// double-click deadzone.
static uint32_t sFallbackOwner = UINT32_MAX;
static CFAbsoluteTime sLastTapUpTime = 0;
static float sLastTapUpX = 0, sLastTapUpY = 0;
// Defined in the audio section below; ArInit self-cleans on failure paths.
static void ArCleanup(void);

@implementation MoonlightSession {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    // Owned C-string storage SERVER_INFORMATION points into. -UTF8String returns
    // an interior/temporary buffer that is NOT pinned by retaining the NSString
    // (tagged-pointer strings hand back autoreleased memory) — the struct must
    // point at storage with the session's own lifetime.
    char _addressC[256], _appVersionC[64], _gfeVersionC[128], _rtspUrlC[512];
    // Video decode state.
    AVSampleBufferDisplayLayer *_displayLayer;
    CMVideoFormatDescriptionRef _formatDesc;
    NSData *_sps, *_pps, *_vps;
    int _videoFormat;
    // Set (on LifecycleQueue) once LiStartConnection has actually run, so stop only
    // calls LiStopConnection for a connection that was really started.
    BOOL _didStart;
    // Set by ClStageFailed; lets start() synthesize a failure callback when
    // LiStartConnection fails BEFORE any stage ran (pre-validation errors would
    // otherwise strand the UI in .launching forever).
    BOOL _sawStageFailure;
    // Diagnostics: distinguish "frames never reached the decoder" (network/FEC)
    // from "frames decoded but nothing on screen" (display-layer/view) without
    // spamming the log.
    int _framesEnqueued;
    BOOL _loggedLayerFail;
    int _notReadyStreak;   // consecutive frames with isReadyForMoreMediaData == NO
    int _videoWidth, _videoHeight;
    // Stream statistics. Written only on the video decode thread; read at 1 Hz
    // from the main thread (32/64-bit loads are single-copy atomic on arm64,
    // and the HUD tolerates a torn read once in a blue moon anyway).
    int _lastStatFrameNumber;
    VLStreamStats _stats;
}

- (void)attachDisplayLayer:(AVSampleBufferDisplayLayer *)layer {
    _displayLayer = layer;
}

+ (NSString *)launchUrlQueryParameters {
    const char *p = LiGetLaunchUrlQueryParameters();
    return p ? @(p) : @"";
}

- (instancetype)initWithAddress:(NSString *)address
                     appVersion:(NSString *)appVersion
                     gfeVersion:(NSString *)gfeVersion
                        rtspUrl:(NSString *)rtspUrl
              codecModeSupport:(int)codecModeSupport
                          width:(int)width
                         height:(int)height
                            fps:(int)fps
                     bitrateKbps:(int)bitrateKbps
                    enableHevc:(BOOL)enableHevc
                    enableHdr:(BOOL)enableHdr
                         aesKey:(NSData *)aesKey
                          aesIv:(NSData *)aesIv {
    if (!(self = [super init])) return nil;

    strlcpy(_addressC, address.UTF8String ?: "", sizeof(_addressC));
    strlcpy(_appVersionC, appVersion.UTF8String ?: "", sizeof(_appVersionC));
    strlcpy(_gfeVersionC, gfeVersion.UTF8String ?: "", sizeof(_gfeVersionC));
    strlcpy(_rtspUrlC, rtspUrl.UTF8String ?: "", sizeof(_rtspUrlC));

    memset(&_serverInfo, 0, sizeof(_serverInfo));
    _serverInfo.address = _addressC;
    _serverInfo.serverInfoAppVersion = _appVersionC;
    _serverInfo.serverInfoGfeVersion = _gfeVersionC[0] ? _gfeVersionC : NULL;
    _serverInfo.rtspSessionUrl = _rtspUrlC[0] ? _rtspUrlC : NULL;
    _serverInfo.serverCodecModeSupport = codecModeSupport;

    memset(&_streamConfig, 0, sizeof(_streamConfig));
    _streamConfig.width = width;
    _streamConfig.height = height;
    _streamConfig.fps = fps;
    _streamConfig.bitrate = bitrateKbps;
    // Over a VPN/tunnel (Tailscale et al.) the path MTU is ~1280 — 1392-byte
    // payloads fragment or drop. Mirror moonlight-ios: force remote + 1024.
    if (VLIsVpnActive()) {
        _streamConfig.packetSize = 1024;
        _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
    } else {
        _streamConfig.packetSize = 1392;
        _streamConfig.streamingRemotely = STREAM_CFG_AUTO;
    }
    _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    _streamConfig.supportedVideoFormats = VIDEO_FORMAT_H264;
    if (enableHevc) _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
    if (enableHevc && enableHdr) _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
    _streamConfig.clientRefreshRateX100 = fps * 100;
    _streamConfig.colorSpace = COLORSPACE_REC_709;
    _streamConfig.colorRange = COLOR_RANGE_LIMITED;
    // ENCFLG_NONE: don't REQUEST audio/video encryption. On-device, RTSP+control
    // (AES-GCM) succeed but every audio packet (AES-CBC) fails to decrypt and no
    // video IDR ever assembles — the signature of a broken mbedcrypto CBC path
    // (the working moonlight-qt helper uses OpenSSL; only our iOS build uses
    // mbedcrypto). Requesting no encryption makes the host send plaintext A/V
    // (Sunshine's default — encryption is optional unless the host requires it),
    // sidestepping the CBC path entirely. If the host *requires* encryption,
    // common-c re-enables it and the failures return — which itself tells us the
    // mbedcrypto build needs fixing rather than this flag.
    _streamConfig.encryptionFlags = ENCFLG_NONE;
    memcpy(_streamConfig.remoteInputAesKey, aesKey.bytes, MIN((NSUInteger)16, aesKey.length));
    memcpy(_streamConfig.remoteInputAesIv, aesIv.bytes, MIN((NSUInteger)16, aesIv.length));

    return self;
}

- (void)start {
    sPending = self;
    // Surfaces the host's REAL appVersion (drives control-stream encryption) +
    // the negotiated config, so a failed connect is diagnosable from the console.
    NSLog(@"[VibeLight] connect: appVersion=%s enc=0x%x %dx%d@%d %dkbps fmts=0x%x codecMode=%d",
          _serverInfo.serverInfoAppVersion ?: "(nil)", _streamConfig.encryptionFlags,
          _streamConfig.width, _streamConfig.height, _streamConfig.fps, _streamConfig.bitrate,
          _streamConfig.supportedVideoFormats, _serverInfo.serverCodecModeSupport);
    dispatch_async(LifecycleQueue(), ^{
        // A newer session may have superseded us while queued — don't start a
        // connection nobody is listening to (and that would overlap the new one).
        if (sPending != self) return;
        // Take the callback sink only now: everything earlier on this serial
        // queue (the previous connection's stop) has fully completed, so no
        // stale callback can land on this session.
        sActive = self;
        sNativeTouchUnsupported = NO;   // re-probe per connection (host may differ)
        sFallbackOwner = UINT32_MAX;
        sLastTapUpTime = 0;

        CONNECTION_LISTENER_CALLBACKS cl = {0};
        cl.stageStarting = ClStageStarting;
        cl.stageComplete = ClStageComplete;
        cl.stageFailed = ClStageFailed;
        cl.connectionStarted = ClConnectionStarted;
        cl.connectionTerminated = ClConnectionTerminated;
        cl.logMessage = ClLogMessage;
        // The rest (rumble, HDR, motion, LED, adaptive triggers, status) are
        // optional — moonlight-common-c tolerates NULL and we don't need them yet.

        DECODER_RENDERER_CALLBACKS dr = {0};
        dr.setup = DrSetup;
        dr.start = DrStart;
        dr.stop = DrStop;
        dr.cleanup = DrCleanup;
        dr.submitDecodeUnit = DrSubmit;
        dr.capabilities = CAPABILITY_DIRECT_SUBMIT;

        AUDIO_RENDERER_CALLBACKS ar = {0};
        ar.init = ArInit;
        ar.start = ArStart;
        ar.stop = ArStop;
        ar.cleanup = ArCleanup;
        ar.decodeAndPlaySample = ArDecode;
        // Decode on the receive thread (skips the player-thread hop); ArDecode
        // is allocation-free C, so it's safe and lower-latency.
        ar.capabilities = CAPABILITY_DIRECT_SUBMIT;

        self->_didStart = YES;
        self->_sawStageFailure = NO;
        int ret = LiStartConnection(&self->_serverInfo, &self->_streamConfig, &cl, &dr, &ar,
                                    NULL, 0, NULL, 0);
        // Pre-stage validation failures return non-zero WITHOUT any stageFailed
        // callback — synthesize one or the UI waits in .launching forever.
        if (ret != 0 && !self->_sawStageFailure) {
            [self notifyFailStage:MoonlightStagePlatformInit error:ret];
        }
    });
}

- (void)stop {
    if (sPending == self) sPending = nil;
    if (sActive == self) sActive = nil;
    // Unblock any in-flight LiStartConnection so the serial queue drains and the
    // teardown below can run (and complete before the next session's start).
    LiInterruptConnection();
    // Capture self STRONGLY: the engine drops its reference right after calling
    // stop(), and a weak capture would deallocate the session before this block
    // runs — skipping LiStopConnection entirely and leaking the connection's
    // threads + audio unit. One-shot block ⇒ no retain cycle; the block's
    // release afterward drops the last reference at exactly the right time.
    dispatch_async(LifecycleQueue(), ^{
        if (self->_didStart) {
            self->_didStart = NO;
            LiStopConnection();
        }
    });
}

- (void)dealloc {
    if (_formatDesc) { CFRelease(_formatDesc); _formatDesc = NULL; }
}

// MARK: - Perf stats (int reads are single-copy atomic on arm64; 1 Hz HUD polling)

- (int32_t)framesEnqueuedCount { return _framesEnqueued; }
- (int)videoWidth  { return _videoWidth; }
- (int)videoHeight { return _videoHeight; }
- (void)getStats:(VLStreamStats *)outStats { *outStats = _stats; }
- (BOOL)getEstimatedRtt:(uint32_t *)rttMs variance:(uint32_t *)varianceMs {
    if (sActive != self) return NO;
    return LiGetEstimatedRttInfo(rttMs, varianceMs) ? YES : NO;
}

- (void)sendTouch:(MoonlightTouchPhase)phase
        pointerId:(uint32_t)pointerId
      normalizedX:(float)x
      normalizedY:(float)y {
    if (sActive != self) return;
    if (!sNativeTouchUnsupported) {
        // Pressure 0.0 = "unknown" for contact phases per Limelight.h (1.0 would
        // claim a max-force press to pen/touch-aware apps on the host).
        int err = LiSendTouchEvent((uint8_t)phase, pointerId, x, y, 0.0f, 0.0f, 0.0f, LI_ROT_UNKNOWN);
        if (err != LI_ERR_UNSUPPORTED) return;
        sNativeTouchUnsupported = YES;
        NSLog(@"[VibeLight] host lacks native touch — falling back to absolute mouse");
    }
    // Absolute-mouse fallback: the FIRST finger down owns the gesture; extra
    // fingers are ignored until it lifts (a stray second finger must not warp
    // the cursor or re-click).
    short w = _videoWidth > 0 ? (short)_videoWidth : 1920;
    short h = _videoHeight > 0 ? (short)_videoHeight : 1080;
    switch (phase) {
        case MoonlightTouchPhaseDown: {
            if (sFallbackOwner != UINT32_MAX) return;
            sFallbackOwner = pointerId;
            // Double-click deadzone: Windows measures double-click distance
            // between the two button-DOWN cursor positions — a quick second tap
            // near the last one must NOT move the cursor first or the wobble
            // defeats the double-click.
            BOOL nearLastTap = (CFAbsoluteTimeGetCurrent() - sLastTapUpTime < 0.5)
                && fabsf(x - sLastTapUpX) < 0.02f && fabsf(y - sLastTapUpY) < 0.02f;
            if (!nearLastTap) {
                LiSendMousePositionEvent((short)(x * (float)w), (short)(y * (float)h), w, h);
            }
            LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
            break;
        }
        case MoonlightTouchPhaseMove:
            if (pointerId != sFallbackOwner) return;
            LiSendMousePositionEvent((short)(x * (float)w), (short)(y * (float)h), w, h);
            break;
        case MoonlightTouchPhaseUp:
        case MoonlightTouchPhaseCancel:
            if (pointerId != sFallbackOwner) return;
            sFallbackOwner = UINT32_MAX;
            // Release only — repositioning on lift would defeat the deadzone.
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            sLastTapUpTime = CFAbsoluteTimeGetCurrent();
            sLastTapUpX = x; sLastTapUpY = y;
            break;
    }
}

- (int)sendControllerArrivalForNumber:(uint8_t)controllerNumber
                           activeMask:(uint16_t)activeMask
                                 type:(uint8_t)type
                     supportedButtons:(uint32_t)supportedButtons
                         capabilities:(uint16_t)capabilities {
    if (sActive != self) return -1;
    // Falls back to a plain LiSendMultiControllerEvent on hosts without
    // arrival support, per Limelight.h. Nonzero until the input stream is up.
    return LiSendControllerArrivalEvent(controllerNumber, activeMask, type,
                                        supportedButtons, capabilities);
}

- (void)sendControllerArrivalWithButtons:(uint32_t)supportedButtons
                            capabilities:(uint16_t)capabilities {
    [self sendControllerArrivalForNumber:0 activeMask:0x1 type:LI_CTYPE_UNKNOWN
                        supportedButtons:supportedButtons capabilities:capabilities];
}

+ (void)resumeAudio {
    // Called from the AVAudioSession interruption handler on the main thread.
    // sAudioUnit is disposed by ArCleanup inside LiStopConnection, which `stop`
    // runs on LifecycleQueue — hop there so we can never AudioOutputUnitStart a
    // unit a concurrent teardown is mid-dispose on, and gate on a live session
    // (nothing to resume once the stream is gone).
    dispatch_async(LifecycleQueue(), ^{
        if (sActive && sAudioUnit) AudioOutputUnitStart(sAudioUnit);
    });
}

- (void)sendControllerNumber:(uint8_t)controllerNumber
                  activeMask:(uint16_t)activeMask
                 buttonFlags:(int)buttonFlags
                 leftTrigger:(uint8_t)leftTrigger
                rightTrigger:(uint8_t)rightTrigger
                  leftStickX:(int16_t)leftStickX
                  leftStickY:(int16_t)leftStickY
                 rightStickX:(int16_t)rightStickX
                 rightStickY:(int16_t)rightStickY {
    if (sActive != self) return;
    // Returns an error before the input stream is up — safe to ignore; the
    // next snapshot after connect goes through.
    LiSendMultiControllerEvent(controllerNumber, activeMask, buttonFlags,
                               leftTrigger, rightTrigger,
                               leftStickX, leftStickY, rightStickX, rightStickY);
}

- (void)sendControllerButtonFlags:(int)buttonFlags
                      leftTrigger:(uint8_t)leftTrigger
                     rightTrigger:(uint8_t)rightTrigger
                       leftStickX:(int16_t)leftStickX
                       leftStickY:(int16_t)leftStickY
                      rightStickX:(int16_t)rightStickX
                      rightStickY:(int16_t)rightStickY {
    [self sendControllerNumber:0 activeMask:0x1 buttonFlags:buttonFlags
                   leftTrigger:leftTrigger rightTrigger:rightTrigger
                    leftStickX:leftStickX leftStickY:leftStickY
                   rightStickX:rightStickX rightStickY:rightStickY];
}

- (void)sendKeyboardEvent:(int16_t)keyCode down:(BOOL)down modifiers:(uint8_t)modifiers {
    if (sActive != self) return;
    LiSendKeyboardEvent(keyCode, down ? KEY_ACTION_DOWN : KEY_ACTION_UP, (char)modifiers);
}

// MARK: - Delegate marshalling (called from C callbacks below, on the main queue)

- (void)notifyStage:(MoonlightStage)stage {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate session:self didReachStage:stage]; });
}
- (void)notifyFailStage:(MoonlightStage)stage error:(int)err {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate session:self didFailAtStage:stage error:err]; });
}
- (void)notifyTerminated:(int)err {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate session:self didTerminateWithError:err]; });
}

// MARK: - C connection callbacks

static void ClStageStarting(int stage) {}
static void ClStageComplete(int stage) { [sActive notifyStage:(MoonlightStage)stage]; }
static void ClStageFailed(int stage, int errorCode) {
    MoonlightSession *s = sActive;
    if (s) s->_sawStageFailure = YES;
    [s notifyFailStage:(MoonlightStage)stage error:errorCode];
}
static void ClConnectionStarted(void) { [sActive notifyStage:MoonlightStageConnected]; }
static void ClConnectionTerminated(int errorCode) { [sActive notifyTerminated:errorCode]; }
static void ClLogMessage(const char *format, ...) {
    // Also called from pool-less moonlight threads; @(format) is autoreleased.
    @autoreleasepool {
        va_list ap; va_start(ap, format);
        NSString *msg = [[NSString alloc] initWithFormat:@(format) arguments:ap];
        va_end(ap);
        NSLog(@"[moonlight] %@", msg);
    }
}

// MARK: - Video sink → VideoToolbox / AVSampleBufferDisplayLayer

// Length of the Annex-B start code at the front of a NALU (00 00 01 or 00 00 00 01).
static int startCodeLen(const uint8_t *p, int len) {
    if (len >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) return 4;
    if (len >= 3 && p[0] == 0 && p[1] == 0 && p[2] == 1) return 3;
    return 0;
}

- (void)rebuildFormatDescription {
    if (_formatDesc) { CFRelease(_formatDesc); _formatDesc = NULL; }
    if (!_sps.length || !_pps.length) return;
    const uint8_t *ps[3]; size_t sz[3]; size_t count = 0;
    // H.264: {SPS, PPS}. HEVC: {VPS, SPS, PPS}.
    BOOL hevc = (_videoFormat & VIDEO_FORMAT_MASK_H265) != 0;
    if (hevc && _vps.length) { ps[count] = (const uint8_t *)_vps.bytes; sz[count] = _vps.length; count++; }
    ps[count] = (const uint8_t *)_sps.bytes; sz[count] = _sps.length; count++;
    ps[count] = (const uint8_t *)_pps.bytes; sz[count] = _pps.length; count++;
    OSStatus st;
    if (hevc) {
        st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, count, ps, sz, 4, NULL, &_formatDesc);
    } else {
        st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, count, ps, sz, 4, &_formatDesc);
    }
    if (st != noErr) {
        // Leave NULL: submit: then returns DR_NEED_IDR until a parseable
        // parameter set arrives (silently keeping a stale desc corrupts).
        NSLog(@"[VibeLight] format description create failed: %d", (int)st);
        _formatDesc = NULL;
    }
}

- (int)submit:(PDECODE_UNIT)du {
    // Stats accounting first — even frames we end up dropping were received.
    _stats.framesReceived++;
    if (_lastStatFrameNumber != 0 && du->frameNumber > _lastStatFrameNumber + 1) {
        _stats.networkDroppedFrames += du->frameNumber - _lastStatFrameNumber - 1;
    }
    _lastStatFrameNumber = du->frameNumber;
    _stats.videoBytes += (uint64_t)du->fullLength;
    if (du->frameHostProcessingLatency != 0) {
        _stats.hostLatencySumTenthMs += du->frameHostProcessingLatency;
        _stats.hostLatencyCount++;
        if (du->frameHostProcessingLatency > _stats.hostLatencyMaxTenthMs) {
            _stats.hostLatencyMaxTenthMs = du->frameHostProcessingLatency;
        }
    }
    if (du->enqueueTimeUs >= du->receiveTimeUs) {
        _stats.receiveDurationSumUs += du->enqueueTimeUs - du->receiveTimeUs;
    }

    // Contract (Limelight.h): return DR_NEED_IDR whenever the frame can't be
    // processed — DR_OK on an IDR marks it consumed in the depacketizer, after
    // which NOTHING re-requests a keyframe and the stream is black/corrupt
    // until manual disconnect.
    if (!_displayLayer) return DR_NEED_IDR;
    if (_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        if (!_loggedLayerFail) {
            _loggedLayerFail = YES;   // once — decode/format problem, not network
            NSLog(@"[VibeLight] display layer FAILED after %d frames: %@",
                  _framesEnqueued, _displayLayer.error);
        }
        [_displayLayer flush];
        return DR_NEED_IDR;   // ask the host to resend keyframe data
    }
    if (!_displayLayer.isReadyForMoreMediaData) {
        // Transient not-ready is NORMAL during network jitter bursts — the
        // layer's queue legally absorbs extra samples and drains via
        // DisplayImmediately, so keep enqueueing. Only a layer that stays
        // not-ready for ~a second is genuinely stalled; then flush + resync on
        // a keyframe (the jetsam guard) instead of queueing unboundedly.
        if (++_notReadyStreak >= 120) {
            _notReadyStreak = 0;
            [_displayLayer flush];
            return DR_NEED_IDR;
        }
    } else {
        _notReadyStreak = 0;
    }

    // Walk the buffer chain. Parameter-set entries are whole NALUs and rebuild
    // the format description. PICDATA entries are RTP FRAGMENTS, not NALUs — a
    // frame's picture data spans many entries where only NALU starts carry an
    // Annex-B start code. So: reassemble the full Annex-B picture stream first,
    // THEN convert to AVCC by scanning for real start codes. (Treating each
    // fragment as a NALU injects bogus length headers mid-NALU — every frame
    // over ~1KB decodes to garbage and VideoToolbox drops it silently: the
    // on-device "frames enqueue fine but the screen stays black" bug.)
    NSMutableData *annexB = [NSMutableData dataWithCapacity:du->fullLength];
    BOOL paramSetsChanged = NO;
    for (PLENTRY e = du->bufferList; e != NULL; e = e->next) {
        const uint8_t *d = (const uint8_t *)e->data;
        switch (e->bufferType) {
            case BUFFER_TYPE_SPS:
            case BUFFER_TYPE_PPS:
            case BUFFER_TYPE_VPS: {
                int sc = startCodeLen(d, e->length);
                int naluLen = e->length - sc;
                if (naluLen <= 0) break;
                NSData *ps = [NSData dataWithBytes:d + sc length:naluLen];
                if (e->bufferType == BUFFER_TYPE_SPS) _sps = ps;
                else if (e->bufferType == BUFFER_TYPE_PPS) _pps = ps;
                else _vps = ps;
                paramSetsChanged = YES;
                break;
            }
            default:   // BUFFER_TYPE_PICDATA fragment — append raw
                [annexB appendBytes:d length:e->length];
        }
    }
    if (paramSetsChanged) [self rebuildFormatDescription];

    // Annex-B → AVCC: replace each start code with a 4-byte big-endian length of
    // the NALU that follows (start codes only occur at NALU boundaries in the
    // reassembled elementary stream).
    NSMutableData *avcc = [NSMutableData dataWithCapacity:annexB.length + 8];
    {
        const uint8_t *p = (const uint8_t *)annexB.bytes;
        NSUInteger len = annexB.length;
        NSUInteger i = 0;
        while (i < len) {
            int sc = startCodeLen(p + i, (int)(len - i));
            if (sc == 0) { i++; continue; }   // resync (shouldn't happen on clean frames)
            NSUInteger naluStart = i + sc;
            // Find the next start code (or end of stream).
            NSUInteger j = naluStart;
            while (j + 3 <= len) {
                if (p[j] == 0 && p[j+1] == 0 && (p[j+2] == 1 || (j + 4 <= len && p[j+2] == 0 && p[j+3] == 1))) break;
                j++;
            }
            if (j + 3 > len) j = len;
            NSUInteger naluLen = j - naluStart;
            if (naluLen > 0) {
                uint32_t be = CFSwapInt32HostToBig((uint32_t)naluLen);
                [avcc appendBytes:&be length:4];
                [avcc appendBytes:p + naluStart length:naluLen];
            }
            i = j;
        }
    }
    if (!_formatDesc || avcc.length == 0) return DR_NEED_IDR;

    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, avcc.length, kCFAllocatorDefault,
                                           NULL, 0, avcc.length, 0, &bb) != noErr) return DR_NEED_IDR;
    CMBlockBufferReplaceDataBytes(avcc.bytes, bb, 0, avcc.length);

    CMSampleBufferRef sb = NULL;
    size_t sampleSize = avcc.length;
    OSStatus st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, _formatDesc, 1, 0, NULL, 1, &sampleSize, &sb);
    CFRelease(bb);
    if (st != noErr || !sb) return DR_NEED_IDR;

    // Render as soon as possible — we don't buffer for A/V sync in this pass.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    if (attachments && CFArrayGetCount(attachments)) {
        CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(d, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    [_displayLayer enqueueSampleBuffer:sb];
    CFRelease(sb);
    if (_framesEnqueued++ == 0) {
        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(_formatDesc);
        NSLog(@"[VibeLight] first video frame enqueued (%dx%d) — decode path OK", dim.width, dim.height);
    } else if (_framesEnqueued % 7200 == 0) {   // ~every minute at 120fps
        NSLog(@"[VibeLight] %d frames enqueued, layer status=%ld", _framesEnqueued, (long)_displayLayer.status);
    }
    return DR_OK;
}

static int  DrSetup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags) {
    MoonlightSession *s = sActive;
    if (s) { s->_videoFormat = videoFormat; s->_videoWidth = width; s->_videoHeight = height; }
    // Pool-less video thread: NSLog autoreleases an NSString with no pool to
    // drain it. One-shot per connect, but wrap it anyway (see DrSubmit).
    @autoreleasepool {
        NSLog(@"[VibeLight] video decode setup: format=0x%x %dx%d@%d", videoFormat, width, height, redrawRate);
    }
    return 0;
}
static void DrStart(void) {}
static void DrStop(void) {}
static void DrCleanup(void) {
    MoonlightSession *s = sActive;
    if (s && s->_formatDesc) { CFRelease(s->_formatDesc); s->_formatDesc = NULL; }
}
static int  DrSubmit(PDECODE_UNIT decodeUnit) {
    // Runs on moonlight's raw video pthread — NO autorelease pool exists there.
    // submit: creates autoreleased NSData/NSMutableData per frame; without a
    // pool drain they accumulate forever (≈20+ MB/s at 4K120) until jetsam
    // kills the app. Observed on-device as a mid-stream crash.
    @autoreleasepool {
        MoonlightSession *s = sActive; return s ? [s submit:decodeUnit] : DR_OK;
    }
}

// MARK: - Audio sink: Opus multistream → RemoteIO AudioUnit
//
// All C/C++ — these callbacks run on moonlight's pool-less audio thread and
// CoreAudio's realtime render thread, so no ObjC allocation anywhere. PCM flows
// through a single-producer/single-consumer lock-free byte ring: ArDecode
// (producer) writes decoded frames; the render callback (consumer) drains or
// zero-fills on underrun.

static OpusMSDecoder *sOpusDecoder;
static OPUS_MULTISTREAM_CONFIGURATION sOpusCfg;
static AudioComponentInstance sAudioUnit;
// Latency bound: max queued-but-unplayed PCM before new packets are dropped.
// Without it, every jitter burst ratchets the backlog up (the ring only
// dropped when FULL at ~0.7 s) and the lag never drains — audio ends up
// permanently ~a second behind video. 60 ms of headroom; set per-config.
static size_t sMaxAudioBacklogBytes = 11520;

static const size_t kAudioRingCapacity = 256 * 1024;   // ~0.7 s of 48 kHz stereo
static uint8_t sAudioRing[kAudioRingCapacity];
static std::atomic<uint64_t> sRingHead{0};   // producer-owned
static std::atomic<uint64_t> sRingTail{0};   // consumer-owned

static OSStatus ArRender(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                         const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                         UInt32 inNumberFrames, AudioBufferList *ioData) {
    uint8_t *out = (uint8_t *)ioData->mBuffers[0].mData;
    const size_t want = ioData->mBuffers[0].mDataByteSize;
    const uint64_t head = sRingHead.load(std::memory_order_acquire);
    const uint64_t tail = sRingTail.load(std::memory_order_relaxed);
    size_t take = (size_t)MIN((uint64_t)want, head - tail);
    const size_t start = (size_t)(tail % kAudioRingCapacity);
    const size_t first = MIN(take, kAudioRingCapacity - start);
    memcpy(out, &sAudioRing[start], first);
    memcpy(out + first, &sAudioRing[0], take - first);
    if (take < want) memset(out + take, 0, want - take);   // underrun → silence
    sRingTail.store(tail + take, std::memory_order_release);
    return noErr;
}

static int ArInit(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void *context, int arFlags) {
    // Runs on moonlight's pool-less audio setup thread; the NSLogs below
    // autorelease NSStrings with no pool to drain them. One-shot per connect —
    // wrap the whole body so nothing leaks (mirrors DrSubmit's per-frame pool).
    @autoreleasepool {
    sOpusCfg = *opusConfig;
    int err = 0;
    sOpusDecoder = opus_multistream_decoder_create(opusConfig->sampleRate, opusConfig->channelCount,
                                                   opusConfig->streams, opusConfig->coupledStreams,
                                                   opusConfig->mapping, &err);
    if (sOpusDecoder == NULL || err != OPUS_OK) {
        NSLog(@"[VibeLight] opus decoder create failed: %d", err);
        ArCleanup();   // common-c never calls cleanup when init fails
        return -1;
    }

    AudioComponentDescription desc = {};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (comp == NULL || AudioComponentInstanceNew(comp, &sAudioUnit) != noErr) {
        NSLog(@"[VibeLight] RemoteIO create failed");
        ArCleanup();
        return -1;
    }

    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = opusConfig->sampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = (UInt32)opusConfig->channelCount;
    fmt.mBitsPerChannel = 16;
    fmt.mBytesPerFrame = fmt.mChannelsPerFrame * 2;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame;
    AudioUnitSetProperty(sAudioUnit, kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));

    AURenderCallbackStruct cb = {};
    cb.inputProc = ArRender;
    AudioUnitSetProperty(sAudioUnit, kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input, 0, &cb, sizeof(cb));

    if (AudioUnitInitialize(sAudioUnit) != noErr) {
        NSLog(@"[VibeLight] RemoteIO init failed");
        ArCleanup();
        return -1;
    }
    sRingHead.store(0); sRingTail.store(0);
    // 60 ms latency bound at the negotiated rate/channels (16-bit samples).
    sMaxAudioBacklogBytes = (size_t)opusConfig->sampleRate * (size_t)opusConfig->channelCount * 2 * 60 / 1000;
    NSLog(@"[VibeLight] audio: %d Hz, %d ch, %d samples/frame",
          opusConfig->sampleRate, opusConfig->channelCount, opusConfig->samplesPerFrame);
    return 0;
    }  // @autoreleasepool
}

static void ArStart(void) { if (sAudioUnit) AudioOutputUnitStart(sAudioUnit); }
static void ArStop(void)  { if (sAudioUnit) AudioOutputUnitStop(sAudioUnit); }

static void ArCleanup(void) {
    if (sAudioUnit) {
        AudioOutputUnitStop(sAudioUnit);
        AudioUnitUninitialize(sAudioUnit);
        AudioComponentInstanceDispose(sAudioUnit);
        sAudioUnit = NULL;
    }
    if (sOpusDecoder) {
        opus_multistream_decoder_destroy(sOpusDecoder);
        sOpusDecoder = NULL;
    }
}

static void ArDecode(char *sampleData, int sampleLength) {
    if (sOpusDecoder == NULL) return;
    // Latency bound: when the backlog already exceeds ~60 ms, drop this packet
    // instead of queueing it — jitter-burst backlog otherwise ratchets up and
    // NEVER drains (playback consumes exactly real-time), leaving audio
    // permanently behind video.
    {
        const uint64_t head = sRingHead.load(std::memory_order_relaxed);
        const uint64_t tail = sRingTail.load(std::memory_order_acquire);
        if ((size_t)(head - tail) > sMaxAudioBacklogBytes) return;
    }
    // Worst case: 8 channels × up to 3× nominal frame; NULL data = packet loss →
    // Opus PLC synthesizes concealment for one frame.
    int16_t pcm[1440 * AUDIO_CONFIGURATION_MAX_CHANNEL_COUNT];
    int frames = opus_multistream_decode(sOpusDecoder,
                                         (const unsigned char *)sampleData, sampleLength,
                                         pcm, sOpusCfg.samplesPerFrame, 0);
    if (frames <= 0) return;
    const size_t bytes = (size_t)frames * sOpusCfg.channelCount * sizeof(int16_t);
    const uint64_t head = sRingHead.load(std::memory_order_relaxed);
    const uint64_t tail = sRingTail.load(std::memory_order_acquire);
    if (kAudioRingCapacity - (size_t)(head - tail) < bytes) return;   // full → drop (stale audio is worse)
    const uint8_t *src = (const uint8_t *)pcm;
    const size_t start = (size_t)(head % kAudioRingCapacity);
    const size_t first = MIN(bytes, kAudioRingCapacity - start);
    memcpy(&sAudioRing[start], src, first);
    memcpy(&sAudioRing[0], src + first, bytes - first);
    sRingHead.store(head + bytes, std::memory_order_release);
}

@end
