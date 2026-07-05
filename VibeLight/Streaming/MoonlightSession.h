#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C façade over moonlight-common-c's `LiStartConnection`, so
/// Swift can drive the in-process stream without juggling C function pointers +
/// `void*` context. The C decoder/audio/connection callbacks are global function
/// pointers; bouncing them through this object (à la moonlight-ios `Connection.m`)
/// is cleaner than Swift `@convention(c)` closures. Phase 2 = link + connect with
/// no-op sinks; Phases 3–5 fill in VideoToolbox / Opus / input.
@interface MoonlightSession : NSObject

/// Streaming stages moonlight-common-c reports via its ConnectionListener; the
/// Phase-2 link test succeeds when we reach `MoonlightStageAllComplete`.
typedef NS_ENUM(NSInteger, MoonlightStage) {
    MoonlightStageNone = 0,
    MoonlightStageStarting,
    MoonlightStageRtspHandshake,
    MoonlightStageControlStream,
    MoonlightStageVideoStream,
    MoonlightStageAudioStream,
    MoonlightStageInputStream,
    MoonlightStageAllComplete,
    MoonlightStageFailed,
};

/// Returns moonlight-common-c's name for a connection stage (LiGetStageName) —
/// the trivial call that proves the C core links and is callable from Swift.
+ (NSString *)stageName:(NSInteger)stage;

@end

NS_ASSUME_NONNULL_END
