#import <Foundation/Foundation.h>

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

/// Starts the connection on a background thread. Stage callbacks arrive on the
/// main queue. Non-blocking.
- (void)start;

/// Stops the local connection (LiStopConnection). The remote game keeps running
/// (that's "disconnect but keep playing"; full quit goes through /cancel).
- (void)stop;

@end

NS_ASSUME_NONNULL_END
