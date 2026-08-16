#import "XDremuxObjCExceptionCatcher.h"

NSException *_Nullable XDRemuxCatchException(
    void (NS_NOESCAPE ^_Nonnull block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
