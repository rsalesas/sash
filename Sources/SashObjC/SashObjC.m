#import "SashObjC.h"

BOOL SashCatchObjCException(void (NS_NOESCAPE ^block)(void),
                            NSException * _Nullable * _Nonnull exception) {
    @try {
        *exception = nil;
        block();
        return YES;
    }
    @catch (NSException *raised) {
        *exception = raised;
        return NO;
    }
}
