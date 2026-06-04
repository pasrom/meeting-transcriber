#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try/@catch and bridges any raised
/// NSException to a Swift-catchable NSError. Returns nil when the block
/// completes normally.
///
/// AVFoundation APIs such as `-[AVAudioNode installTapOnBus:...]` signal
/// misuse by raising an NSException, which Swift's `do/catch` cannot
/// intercept — it propagates to `std::terminate`/`abort`. Wrapping the call
/// here converts that whole class of aborts into a recoverable Swift error.
/// The block is non-escaping: it runs synchronously before this returns.
NSError *_Nullable audiotap_tryBlock(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
