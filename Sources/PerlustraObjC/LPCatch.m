#import "LPCatch.h"

BOOL LPTry(NS_NOESCAPE void (^block)(void), NSString **reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (reason) { *reason = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""]; }
        return NO;
    }
}
