#import <Foundation/Foundation.h>

/// Runs `block` and converts any Objective-C exception into an NSError, so AVFoundation setters
/// that throw (activeFormat, activeVideoMinFrameDuration, …) cannot abort the process.
/// Returns nil on success.
NSError * _Nullable OCCatchException(void (^ _Nonnull block)(void));
