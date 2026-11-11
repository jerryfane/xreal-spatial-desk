#ifdef __APPLE__
#import "CVirtualDisplay.h"

// Private CoreGraphics interfaces (macOS 11+), as declared by DeskPad and Chromium's virtual_display_mac_util.
// The classes are looked up at run time with NSClassFromString, so a macOS without them fails cleanly instead of
// refusing to launch.
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static NSError *XRError(NSString *message) {
    return [NSError errorWithDomain:@"XRVirtualDisplay" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation XRVirtualDisplay {
    id _display;
}

+ (uint32_t)vendorID {
    return 0x5844;  // "XD", not a real vendor
}

+ (BOOL)isAvailable {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor")
        && NSClassFromString(@"CGVirtualDisplayMode") && NSClassFromString(@"CGVirtualDisplaySettings");
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                    sizeInMillimeters:(CGSize)size
                         serialNumber:(uint32_t)serialNumber
                           terminated:(nullable void (^)(void))terminated
                                error:(NSError *_Nullable *_Nullable)error {
    if (!(self = [super init])) return nil;
    if (![XRVirtualDisplay isAvailable]) {
        if (error) *error = XRError(@"CGVirtualDisplay classes are not present on this macOS");
        return nil;
    }
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    NSUInteger scale = hiDPI ? 2 : 1;
    descriptor.maxPixelsWide = (unsigned int)(width * scale);
    descriptor.maxPixelsHigh = (unsigned int)(height * scale);
    descriptor.sizeInMillimeters = size;
    descriptor.vendorID = XRVirtualDisplay.vendorID;
    descriptor.productID = 0x0001;
    descriptor.serialNum = serialNumber;
    if (terminated) {
        void (^handler)(void) = [terminated copy];
        descriptor.terminationHandler = ^(id a, id b) { handler(); };
    }
    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display) {
        if (error) *error = XRError(@"CGVirtualDisplay initWithDescriptor: returned nil");
        return nil;
    }
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width
                                                                                   height:height
                                                                              refreshRate:refreshRate]];
    if (![_display applySettings:settings]) {
        _display = nil;
        if (error) *error = XRError(@"CGVirtualDisplay applySettings: failed");
        return nil;
    }
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? [_display displayID] : kCGNullDirectDisplay;
}

- (void)invalidate {
    _display = nil;
}

@end
#endif
