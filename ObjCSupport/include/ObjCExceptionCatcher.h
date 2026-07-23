#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `tryBlock` inside an Objective-C `@try/@catch`. Returns `nil` on success,
/// or an `NSError` wrapping the caught `NSException`.
///
/// Swift's `do/catch` cannot catch Objective-C `NSException`s: an uncaught one
/// calls `abort()` (SIGABRT) and kills the process. Several AVFoundation calls —
/// notably `-[AVAudioNode installTapOnBus:bufferSize:format:block:]` — raise
/// `NSException`s on invalid state (e.g. a Bluetooth mic changing format mid-route),
/// so throwing calls must be funnelled through here to be recoverable.
NSError * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^tryBlock)(void));

NS_ASSUME_NONNULL_END
