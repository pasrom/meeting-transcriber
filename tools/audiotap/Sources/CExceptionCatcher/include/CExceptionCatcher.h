#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The implementation is ObjC++ (see CExceptionCatcher.mm for why), so the
// declaration needs C linkage or Swift looks for a mangled symbol.
#ifdef __cplusplus
extern "C" {
#endif

/// Runs `block` inside a C++ catch-all and bridges any raised NSException to a
/// Swift-catchable NSError. Returns nil when the block completes normally.
///
/// A C++ handler rather than `@catch` on purpose: see CExceptionCatcher.mm.
///
/// AVFoundation APIs such as `-[AVAudioNode installTapOnBus:...]` signal
/// misuse by raising an NSException, which Swift's `do/catch` cannot
/// intercept — it propagates to `std::terminate`/`abort`. Wrapping the call
/// here converts that whole class of aborts into a recoverable Swift error.
/// The block is non-escaping: it runs synchronously before this returns.
NSError *_Nullable audiotap_tryBlock(NS_NOESCAPE void (^block)(void));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
