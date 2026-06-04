#import "CExceptionCatcher.h"

NSError *_Nullable audiotap_tryBlock(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"AudioTapLib.NSException"
                                   code:1
                               userInfo:@{
                                   NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                                   @"exceptionName": exception.name,
                               }];
    }
}
