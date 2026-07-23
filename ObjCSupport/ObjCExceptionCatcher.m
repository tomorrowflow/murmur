#import "ObjCExceptionCatcher.h"

NSError * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^tryBlock)(void)) {
    @try {
        tryBlock();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if (exception.name) {
            info[@"ExceptionName"] = exception.name;
        }
        if (exception.reason) {
            info[NSLocalizedDescriptionKey] = exception.reason;
        }
        if (exception.userInfo) {
            [info addEntriesFromDictionary:exception.userInfo];
        }
        return [NSError errorWithDomain:@"ObjCExceptionCatcher" code:0 userInfo:info];
    }
}
