#import "MoonlightSession.h"
#import <Limelight.h>

// Phase 2 skeleton. This file's job right now is to prove the vendored C core
// (moonlight-common-c + enet + nanors, linked against mbedcrypto) compiles and
// links into the iOS app and is callable from Swift. The full LiStartConnection
// drive — SERVER_INFORMATION / STREAM_CONFIGURATION (from a /launch we don't yet
// issue) + the decoder/audio/connection callbacks — lands in Phase 3+.

@implementation MoonlightSession

+ (NSString *)stageName:(NSInteger)stage {
    // LiGetStageName lives in Connection.o — calling it proves the whole static
    // lib linked (not just that the header parsed).
    return @(LiGetStageName((int)stage));
}

@end
