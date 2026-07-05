#import "MoonlightSession.h"
#import <Limelight.h>
#import <string.h>

// moonlight-common-c is a single-connection C library whose callbacks are global
// function pointers, so we keep one active session and forward to it. (Same model
// as moonlight-ios Connection.m.)
static __weak MoonlightSession *sActive = nil;

@implementation MoonlightSession {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    // Backing storage the C structs point into — must outlive LiStartConnection.
    NSString *_address, *_appVersion, *_gfeVersion, *_rtspUrl;
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
    _streamConfig.encryptionFlags = ENCFLG_AUDIO;   // input always encrypted; audio too. Video off for a safe first connect.
    memcpy(_streamConfig.remoteInputAesKey, aesKey.bytes, MIN((NSUInteger)16, aesKey.length));
    memcpy(_streamConfig.remoteInputAesIv, aesIv.bytes, MIN((NSUInteger)16, aesIv.length));

    return self;
}

- (void)start {
    sActive = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
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

        LiStartConnection(&self->_serverInfo, &self->_streamConfig, &cl, &dr, &ar,
                          NULL, 0, NULL, 0);
    });
}

- (void)stop {
    LiInterruptConnection();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LiStopConnection();
    });
    if (sActive == self) sActive = nil;
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

// MARK: - No-op video sink (Phase 3b feeds VideoToolbox)

static int  DrSetup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags) { return 0; }
static void DrStart(void) {}
static void DrStop(void) {}
static void DrCleanup(void) {}
static int  DrSubmit(PDECODE_UNIT decodeUnit) { return DR_OK; }

// MARK: - No-op audio sink (Phase 4 decodes Opus → CoreAudio)

static int  ArInit(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void *context, int arFlags) { return 0; }
static void ArStart(void) {}
static void ArStop(void) {}
static void ArCleanup(void) {}
static void ArDecode(char *sampleData, int sampleLength) {}

@end
