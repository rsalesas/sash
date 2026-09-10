#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try. If it raises, the exception is
/// returned through `exception` and the function returns NO; otherwise YES.
///
/// Swift cannot catch Objective-C exceptions. WebKit raises one when a
/// WKURLSchemeTask is used after it has been torn down, and the window in which
/// that can happen cannot be closed from the Swift side. This is the net.
BOOL SashCatchObjCException(void (NS_NOESCAPE ^block)(void),
                            NSException * _Nullable * _Nonnull exception);

NS_ASSUME_NONNULL_END
