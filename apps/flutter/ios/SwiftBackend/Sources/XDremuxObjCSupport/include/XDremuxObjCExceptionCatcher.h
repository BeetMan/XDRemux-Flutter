#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an ObjC @try/@catch and returns the caught
/// NSException (nil when none was raised). iOS cannot run the macOS
/// validation helpers out-of-process, so private-framework calls go
/// through this instead.
FOUNDATION_EXPORT NSException *_Nullable XDRemuxCatchException(
    void (NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
