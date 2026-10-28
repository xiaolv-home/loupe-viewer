#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Runs `block`, catching any Objective-C exception. Returns NO and fills `reason` on failure.
/// AppKit and PDFKit occasionally raise on malformed input; letting such an exception unwind
/// through Swift code would wedge the main actor, so risky calls go through here.
BOOL LPTry(NS_NOESCAPE void (^block)(void), NSString *_Nullable *_Nullable reason);
NS_ASSUME_NONNULL_END
