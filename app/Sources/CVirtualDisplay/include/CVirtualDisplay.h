#ifdef __APPLE__
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// One macOS display backed by the private CoreGraphics class `CGVirtualDisplay` (the API DeskPad and
/// BetterDisplay use). The display exists while this object is alive; `invalidate` removes it at once.
/// WindowServer also removes it when the process exits, including on a crash.
@interface XRVirtualDisplay : NSObject

/// Whether this macOS still has the private classes.
+ (BOOL)isAvailable;

/// The vendor number every display made here reports (`CGDisplayVendorNumber`), so they can be told apart from
/// real displays such as the glasses.
@property(class, nonatomic, readonly) uint32_t vendorID;

/// Creates and configures the display. Returns nil and sets `error` if the private API is missing or refuses.
/// `serialNumber` tells several of our displays apart (macOS keys a display's arrangement and settings on vendor,
/// product and serial). `terminated` runs (on the main queue) if the system ends the display.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                    sizeInMillimeters:(CGSize)size
                         serialNumber:(uint32_t)serialNumber
                           terminated:(nullable void (^)(void))terminated
                                error:(NSError *_Nullable *_Nullable)error;

@property(nonatomic, readonly) CGDirectDisplayID displayID;

/// Removes the display. Safe to call more than once.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
#endif
