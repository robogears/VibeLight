#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stage of a live connection, mirroring moonlight-common-c's STAGE_* progression
/// so Swift can render progress without importing Limelight.h.
typedef NS_ENUM(NSInteger, MoonlightStage) {
    MoonlightStageNone = 0,
    MoonlightStagePlatformInit,
    MoonlightStageNameResolution,
    MoonlightStageAudioInit,
    MoonlightStageRtspHandshake,
    MoonlightStageControlInit,
    MoonlightStageVideoInit,
    MoonlightStageInputInit,
    MoonlightStageControlStart,
    MoonlightStageVideoStart,       // first video packets flowing — "connected"
    MoonlightStageAudioStart,
    MoonlightStageInputStart,
    MoonlightStageConnected,        // connectionStarted fired
};

@class MoonlightSession;

@protocol MoonlightSessionDelegate <NSObject>
- (void)session:(MoonlightSession *)session didReachStage:(MoonlightStage)stage;
- (void)session:(MoonlightSession *)session didFailAtStage:(MoonlightStage)stage error:(int)errorCode;
/// errorCode 0 (ML_ERROR_GRACEFUL_TERMINATION) means the host ended it cleanly.
- (void)session:(MoonlightSession *)session didTerminateWithError:(int)errorCode;
@end

/// Drives one in-process moonlight-common-c connection (`LiStartConnection`) on a
/// background thread and surfaces its stages to Swift. moonlight-common-c is a
/// single-connection library, so at most one session runs at a time. Phase 3a:
/// connect with no-op video/audio sinks to validate the launch/RTSP/crypto path
/// on-device; Phase 3b feeds the decoder into VideoToolbox.
@interface MoonlightSession : NSObject

@property (nonatomic, weak, nullable) id<MoonlightSessionDelegate> delegate;

/// moonlight-common-c's query-string additions for /launch (client capabilities,
/// codecs, etc.). Append verbatim to the launch request.
+ (NSString *)launchUrlQueryParameters;

/// @param aesKey/aesIv the 16-byte remote-input key/iv that were sent as
///        rikey/rikeyid in /launch (hex/decimal there, raw bytes here).
- (instancetype)initWithAddress:(NSString *)address
                     appVersion:(NSString *)appVersion
                     gfeVersion:(nullable NSString *)gfeVersion
                        rtspUrl:(nullable NSString *)rtspUrl
              codecModeSupport:(int)codecModeSupport
                          width:(int)width
                         height:(int)height
                            fps:(int)fps
                     bitrateKbps:(int)bitrateKbps
                    enableHevc:(BOOL)enableHevc
                    enableHdr:(BOOL)enableHdr
                         aesKey:(NSData *)aesKey
                          aesIv:(NSData *)aesIv;

/// The layer decoded video is enqueued onto. Attach before `start` so the very
/// first (IDR) frame has somewhere to go.
- (void)attachDisplayLayer:(AVSampleBufferDisplayLayer *)layer;

/// Starts the connection on a background thread. Stage callbacks arrive on the
/// main queue. Non-blocking.
- (void)start;

/// Stops the local connection (LiStopConnection). The remote game keeps running
/// (that's "disconnect but keep playing"; full quit goes through /cancel).
- (void)stop;

/// Total video frames enqueued to the display layer (perf HUD).
- (int32_t)framesEnqueuedCount;
/// Negotiated stream dimensions (0 until the decoder is set up).
- (int)videoWidth;
- (int)videoHeight;
/// Estimated control-stream round-trip time; NO when unavailable.
- (BOOL)getEstimatedRtt:(uint32_t *)rttMs variance:(uint32_t *)varianceMs;

/// Cumulative per-frame stream statistics (monotonic counters — the HUD
/// computes rates from deltas between 1 Hz snapshots).
typedef struct {
    int32_t  framesReceived;            // decode units delivered to the decoder
    int32_t  networkDroppedFrames;      // frame-number gaps (never delivered)
    uint64_t videoBytes;                // sum of frame payload sizes
    uint64_t hostLatencySumTenthMs;     // sum of per-frame host processing latency
    int32_t  hostLatencyCount;          // frames that carried a latency value
    uint32_t hostLatencyMaxTenthMs;     // worst single frame
    uint64_t receiveDurationSumUs;      // Σ(enqueueTime − receiveTime): frame assembly time
} VLStreamStats;
- (void)getStats:(VLStreamStats *)outStats;

/// Forwards a complete player-1 gamepad snapshot to the host
/// (LiSendMultiControllerEvent). Sticks: -32768…32767, up/right positive.
/// Triggers: 0…255. No-op when this session isn't the active connection.
- (void)sendControllerButtonFlags:(int)buttonFlags
                      leftTrigger:(uint8_t)leftTrigger
                     rightTrigger:(uint8_t)rightTrigger
                       leftStickX:(int16_t)leftStickX
                       leftStickY:(int16_t)leftStickY
                      rightStickX:(int16_t)rightStickX
                      rightStickY:(int16_t)rightStickY;

@end

NS_ASSUME_NONNULL_END
