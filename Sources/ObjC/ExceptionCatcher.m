#import "ExceptionCatcher.h"

NSError *OCCatchException(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        NSString *msg = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
        return [NSError errorWithDomain:@"OpenCapture.ObjCException" code:9001
                               userInfo:@{NSLocalizedDescriptionKey: msg}];
    }
}
