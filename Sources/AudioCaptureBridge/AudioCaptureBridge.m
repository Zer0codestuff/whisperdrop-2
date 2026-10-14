#import "AudioCaptureBridge.h"

static void WDSetCaptureError(NSError **error, NSException *exception) {
    if (error) {
        *error = [NSError errorWithDomain:@"io.github.zer0codestuff.whisperdrop2.audio"
                                    code:1
                                userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"The audio device changed while opening the microphone."}];
    }
}

@implementation WDAudioCaptureBridge
+ (BOOL)installTapOnNode:(AVAudioNode *)node
             bufferSize:(AVAudioFrameCount)bufferSize
                 format:(AVAudioFormat *)format
                  block:(AVAudioNodeTapBlock)block
                  error:(NSError **)error {
    @try {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
        if (@available(macOS 27.0, *)) {
            return [node installTapOnBus:0 bufferSize:bufferSize format:format error:error block:block];
        }
#endif
        [node installTapOnBus:0 bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        WDSetCaptureError(error, exception);
        return NO;
    }
}

+ (BOOL)startEngine:(AVAudioEngine *)engine error:(NSError **)error {
    @try {
        [engine prepare];
        return [engine startAndReturnError:error];
    } @catch (NSException *exception) {
        WDSetCaptureError(error, exception);
        return NO;
    }
}
@end
