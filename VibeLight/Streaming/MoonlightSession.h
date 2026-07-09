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

/// Touch phases, mirroring moonlight-common-c's LI_TOUCH_EVENT_* values.
typedef NS_ENUM(uint8_t, MoonlightTouchPhase) {
    MoonlightTouchPhaseDown   = 0x01,
    MoonlightTouchPhaseUp     = 0x02,
    MoonlightTouchPhaseMove   = 0x03,
    MoonlightTouchPhaseCancel = 0x04,
};

/// Forwards one touch to the host. Coordinates are normalized 0…1 within the
/// VIDEO area. Uses native touch passthrough (LiSendTouchEvent) when the host
/// supports it; otherwise falls back to absolute mouse position + left click
/// (primary pointer only).
- (void)sendTouch:(MoonlightTouchPhase)phase
        pointerId:(uint32_t)pointerId
      normalizedX:(float)x
      normalizedY:(float)y;

/// Announces a gamepad slot to the host with its family + capabilities, so the
/// host materializes a MATCHING virtual pad before the first input event locks
/// the slot as a default X360 (`type` is a LI_CTYPE_* value: 0 unknown, 1 Xbox,
/// 2 PlayStation, 3 Nintendo — with Sunshine/Apollo `gamepad=auto`, PlayStation
/// becomes a virtual DS4). Must be this slot's FIRST controller packet. Falls
/// back to a plain controller event on hosts without arrival support.
- (void)sendControllerArrivalForNumber:(uint8_t)controllerNumber
                            activeMask:(uint16_t)activeMask
                                  type:(uint8_t)type
                      supportedButtons:(uint32_t)supportedButtons
                          capabilities:(uint16_t)capabilities;

/// Announces a player-1 gamepad (legacy single-pad wrapper for the above).
- (void)sendControllerArrivalWithButtons:(uint32_t)supportedButtons
                            capabilities:(uint16_t)capabilities;

/// Restarts the audio unit after an AVAudioSession interruption ends (phone
/// call, Siri, alarm). Safe no-op when no stream audio exists.
+ (void)resumeAudio;

/// Forwards a complete gamepad snapshot for one slot (LiSendMultiControllerEvent).
/// `activeMask` is the live set of allocated slots — sending an event whose mask
/// has this slot's bit CLEARED is the removal signal that makes the host destroy
/// the virtual pad. Sticks: -32768…32767, up/right positive. Triggers: 0…255.
/// No-op when this session isn't the active connection.
- (void)sendControllerNumber:(uint8_t)controllerNumber
                  activeMask:(uint16_t)activeMask
                 buttonFlags:(int)buttonFlags
                 leftTrigger:(uint8_t)leftTrigger
                rightTrigger:(uint8_t)rightTrigger
                  leftStickX:(int16_t)leftStickX
                  leftStickY:(int16_t)leftStickY
                 rightStickX:(int16_t)rightStickX
                 rightStickY:(int16_t)rightStickY;

/// Player-1 snapshot (legacy single-pad wrapper for the above).
- (void)sendControllerButtonFlags:(int)buttonFlags
                      leftTrigger:(uint8_t)leftTrigger
                     rightTrigger:(uint8_t)rightTrigger
                       leftStickX:(int16_t)leftStickX
                       leftStickY:(int16_t)leftStickY
                      rightStickX:(int16_t)rightStickX
                      rightStickY:(int16_t)rightStickY;

/// Forwards one hardware-keyboard key change to the host (LiSendKeyboardEvent).
/// `keyCode` is a Windows virtual-key code; `modifiers` is the MODIFIER_* mask
/// of currently-held modifier keys. No-op when this session isn't the active
/// connection.
- (void)sendKeyboardEvent:(int16_t)keyCode
                     down:(BOOL)down
                modifiers:(uint8_t)modifiers;

@end

NS_ASSUME_NONNULL_END
