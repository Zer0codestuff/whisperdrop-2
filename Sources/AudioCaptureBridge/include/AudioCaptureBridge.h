#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts AVAudioEngine's Objective-C exceptions into recoverable capture errors.
@interface WDAudioCaptureBridge : NSObject
+ (BOOL)installTapOnNode:(AVAudioNode *)node
             bufferSize:(AVAudioFrameCount)bufferSize
                 format:(AVAudioFormat *)format
                  block:(AVAudioNodeTapBlock)block
                  error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)startEngine:(AVAudioEngine *)engine error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
