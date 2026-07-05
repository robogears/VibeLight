#import "MoonlightSession.h"
#import <Limelight.h>
#import <string.h>

// moonlight-common-c is a single-connection C library whose callbacks are global
// function pointers, so we keep one active session and forward to it. (Same model
// as moonlight-ios Connection.m.)
static __weak MoonlightSession *sActive = nil;

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

@implementation MoonlightSession {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    // Backing storage the C structs point into — must outlive LiStartConnection.
    NSString *_address, *_appVersion, *_gfeVersion, *_rtspUrl;
    // Video decode state.
    AVSampleBufferDisplayLayer *_displayLayer;
    CMVideoFormatDescriptionRef _formatDesc;
    NSData *_sps, *_pps, *_vps;
    int _videoFormat;
    // Set (on LifecycleQueue) once LiStartConnection has actually run, so stop only
    // calls LiStopConnection for a connection that was really started.
    BOOL _didStart;
    // Diagnostics: distinguish "frames never reached the decoder" (network/FEC)
    // from "frames decoded but nothing on screen" (display-layer/view) without
    // spamming the log.
    int _framesEnqueued;
    BOOL _loggedLayerFail;
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

    _address = [address copy];
    _appVersion = [appVersion copy];
    _gfeVersion = [gfeVersion copy];
    _rtspUrl = [rtspUrl copy];

    memset(&_serverInfo, 0, sizeof(_serverInfo));
    _serverInfo.address = _address.UTF8String;
    _serverInfo.serverInfoAppVersion = _appVersion.UTF8String;
    _serverInfo.serverInfoGfeVersion = _gfeVersion.length ? _gfeVersion.UTF8String : NULL;
    _serverInfo.rtspSessionUrl = _rtspUrl.length ? _rtspUrl.UTF8String : NULL;
    _serverInfo.serverCodecModeSupport = codecModeSupport;

    memset(&_streamConfig, 0, sizeof(_streamConfig));
    _streamConfig.width = width;
    _streamConfig.height = height;
    _streamConfig.fps = fps;
    _streamConfig.bitrate = bitrateKbps;
    _streamConfig.packetSize = 1392;
    _streamConfig.streamingRemotely = STREAM_CFG_AUTO;
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
    sActive = self;
    // Surfaces the host's REAL appVersion (drives control-stream encryption) +
    // the negotiated config, so a failed connect is diagnosable from the console.
    NSLog(@"[VibeLight] connect: appVersion=%s enc=0x%x %dx%d@%d %dkbps fmts=0x%x codecMode=%d",
          _serverInfo.serverInfoAppVersion ?: "(nil)", _streamConfig.encryptionFlags,
          _streamConfig.width, _streamConfig.height, _streamConfig.fps, _streamConfig.bitrate,
          _streamConfig.supportedVideoFormats, _serverInfo.serverCodecModeSupport);
    dispatch_async(LifecycleQueue(), ^{
        // A newer session may have superseded us while queued — don't start a
        // connection nobody is listening to (and that would overlap the new one).
        if (sActive != self) return;

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

        self->_didStart = YES;
        LiStartConnection(&self->_serverInfo, &self->_streamConfig, &cl, &dr, &ar,
                          NULL, 0, NULL, 0);
    });
}

- (void)stop {
    if (sActive == self) sActive = nil;
    // Unblock any in-flight LiStartConnection so the serial queue drains and the
    // teardown below can run (and complete before the next session's start).
    LiInterruptConnection();
    __weak typeof(self) weakSelf = self;
    dispatch_async(LifecycleQueue(), ^{
        typeof(self) s = weakSelf;
        if (s && s->_didStart) {
            s->_didStart = NO;
            LiStopConnection();
        }
    });
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
static void ClStageFailed(int stage, int errorCode) { [sActive notifyFailStage:(MoonlightStage)stage error:errorCode]; }
static void ClConnectionStarted(void) { [sActive notifyStage:MoonlightStageConnected]; }
static void ClConnectionTerminated(int errorCode) { [sActive notifyTerminated:errorCode]; }
static void ClLogMessage(const char *format, ...) {
    va_list ap; va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:@(format) arguments:ap];
    va_end(ap);
    NSLog(@"[moonlight] %@", msg);
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
    if (hevc) {
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, count, ps, sz, 4, NULL, &_formatDesc);
    } else {
        CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, count, ps, sz, 4, &_formatDesc);
    }
}

- (int)submit:(PDECODE_UNIT)du {
    if (!_displayLayer) return DR_OK;
    if (_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        if (!_loggedLayerFail) {
            _loggedLayerFail = YES;   // once — decode/format problem, not network
            NSLog(@"[VibeLight] display layer FAILED after %d frames: %@",
                  _framesEnqueued, _displayLayer.error);
        }
        [_displayLayer flush];
        return DR_NEED_IDR;   // ask the host to resend keyframe data
    }

    // Walk the buffer chain: parameter sets rebuild the format description;
    // picture NALUs get their Annex-B start code swapped for a 4-byte AVCC length.
    NSMutableData *avcc = [NSMutableData dataWithCapacity:du->fullLength];
    BOOL paramSetsChanged = NO;
    for (PLENTRY e = du->bufferList; e != NULL; e = e->next) {
        const uint8_t *d = (const uint8_t *)e->data;
        int sc = startCodeLen(d, e->length);
        const uint8_t *nalu = d + sc;
        int naluLen = e->length - sc;
        if (naluLen <= 0) continue;
        switch (e->bufferType) {
            case BUFFER_TYPE_SPS: _sps = [NSData dataWithBytes:nalu length:naluLen]; paramSetsChanged = YES; break;
            case BUFFER_TYPE_PPS: _pps = [NSData dataWithBytes:nalu length:naluLen]; paramSetsChanged = YES; break;
            case BUFFER_TYPE_VPS: _vps = [NSData dataWithBytes:nalu length:naluLen]; paramSetsChanged = YES; break;
            default: {   // BUFFER_TYPE_PICDATA (and IDR slice NALUs)
                uint32_t be = CFSwapInt32HostToBig((uint32_t)naluLen);
                [avcc appendBytes:&be length:4];
                [avcc appendBytes:nalu length:naluLen];
            }
        }
    }
    if (paramSetsChanged) [self rebuildFormatDescription];
    if (!_formatDesc || avcc.length == 0) return DR_OK;

    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, avcc.length, kCFAllocatorDefault,
                                           NULL, 0, avcc.length, 0, &bb) != noErr) return DR_OK;
    CMBlockBufferReplaceDataBytes(avcc.bytes, bb, 0, avcc.length);

    CMSampleBufferRef sb = NULL;
    size_t sampleSize = avcc.length;
    OSStatus st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, _formatDesc, 1, 0, NULL, 1, &sampleSize, &sb);
    CFRelease(bb);
    if (st != noErr || !sb) return DR_OK;

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
    }
    return DR_OK;
}

static int  DrSetup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags) {
    MoonlightSession *s = sActive; if (s) s->_videoFormat = videoFormat;
    NSLog(@"[VibeLight] video decode setup: format=0x%x %dx%d@%d", videoFormat, width, height, redrawRate);
    return 0;
}
static void DrStart(void) {}
static void DrStop(void) {}
static void DrCleanup(void) {
    MoonlightSession *s = sActive;
    if (s && s->_formatDesc) { CFRelease(s->_formatDesc); s->_formatDesc = NULL; }
}
static int  DrSubmit(PDECODE_UNIT decodeUnit) {
    MoonlightSession *s = sActive; return s ? [s submit:decodeUnit] : DR_OK;
}

// MARK: - No-op audio sink (Phase 4 decodes Opus → CoreAudio)

static int  ArInit(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void *context, int arFlags) { return 0; }
static void ArStart(void) {}
static void ArStop(void) {}
static void ArCleanup(void) {}
static void ArDecode(char *sampleData, int sampleLength) {}

@end
