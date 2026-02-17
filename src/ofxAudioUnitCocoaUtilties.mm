#include "ofxAudioUnit.h"
#include "ofxAudioUnitUtils.h"

#if !(TARGET_OS_IPHONE)
#include <CoreAudioKit/CoreAudioKit.h>
#include <AudioUnit/AUCocoaUIView.h>

#pragma mark Objective-C

// Forward declaration for tracking functions
@interface ofxAudioUnitUIWindow : NSWindow
@property (nonatomic, strong) NSView *auView;
- (instancetype)initWithAudioUnit:(AudioUnit)unit forceGeneric:(BOOL)useGeneric;
@end

// Static set to keep strong references to open windows (prevents premature release under ARC)
static NSMutableSet *gOpenWindows;

static void TrackWindow(ofxAudioUnitUIWindow *window) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gOpenWindows = [[NSMutableSet alloc] init];
    });
    [gOpenWindows addObject:window];
}

static void UntrackWindow(ofxAudioUnitUIWindow *window) {
    [gOpenWindows removeObject:window];
}

@implementation ofxAudioUnitUIWindow

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSViewFrameDidChangeNotification
                                                  object:self.auView];
    UntrackWindow(self);
#if !__has_feature(objc_arc)
    [_auView release];
    [super dealloc];
#endif
}

- (instancetype)initWithAudioUnit:(AudioUnit)unit forceGeneric:(BOOL)useGeneric {
    NSView *view = nil;

    if (useGeneric) {
        view = [self createGenericViewForUnit:unit];
    } else if ([ofxAudioUnitUIWindow audioUnitHasCocoaView:unit]) {
        view = [self createCocoaViewForUnit:unit] ?: [self createGenericViewForUnit:unit];
    } else if ([ofxAudioUnitUIWindow audioUnitHasCarbonView:unit]) {
        NSLog(@"This audio unit only has a Carbon-based UI. Carbon support has been removed.");
        return nil;
    } else {
        view = [self createGenericViewForUnit:unit];
    }

    if (!view) return nil;

    self = [self initWithAudioUnitView:view];
    if (self) {
        TrackWindow(self);
    }
    return self;
}

- (NSView *)createGenericViewForUnit:(AudioUnit)unit {
    AUGenericView *view = [[AUGenericView alloc] initWithAudioUnit:unit];
    view.showsExpertParameters = YES;
#if !__has_feature(objc_arc)
    [view autorelease];
#endif
    return view;
}

- (NSView *)createCocoaViewForUnit:(AudioUnit)unit {
    UInt32 dataSize;
    Boolean isWriteable;
    if (AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global,
                                  0, &dataSize, &isWriteable) != noErr) {
        return nil;
    }

    UInt32 numberOfClasses = (dataSize - sizeof(CFURLRef)) / sizeof(CFStringRef);
    if (numberOfClasses == 0) return nil;

    AudioUnitCocoaViewInfo *cocoaViewInfo = (AudioUnitCocoaViewInfo *)malloc(dataSize);
    if (!cocoaViewInfo) return nil;

    NSView *view = nil;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global,
                              0, cocoaViewInfo, &dataSize) == noErr) {
        NSBundle *bundle = [NSBundle bundleWithURL:(__bridge NSURL *)cocoaViewInfo->mCocoaAUViewBundleLocation];
        Class factoryClass = [bundle classNamed:(__bridge NSString *)cocoaViewInfo->mCocoaAUViewClass[0]];
        if (factoryClass) {
            id<AUCocoaUIBase> factory = [[factoryClass alloc] init];
            view = [factory uiViewForAudioUnit:unit withSize:NSZeroSize];
#if !__has_feature(objc_arc)
            [factory release];
#endif
        }
    }

    free(cocoaViewInfo);
    return view;
}

- (instancetype)initWithAudioUnitView:(NSView *)view {
    NSRect contentRect = NSMakeRect(0, 0, view.frame.size.width, view.frame.size.height);
    self = [super initWithContentRect:contentRect
                            styleMask:(NSWindowStyleMaskTitled |
                                       NSWindowStyleMaskClosable |
                                       NSWindowStyleMaskMiniaturizable)
                              backing:NSBackingStoreBuffered
                                defer:NO];

    if (self) {
        self.auView = view;
        self.contentView = view;
        self.releasedWhenClosed = NO;  // Critical: prevents crash on window close

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(viewFrameChanged:)
                                                     name:NSViewFrameDidChangeNotification
                                                   object:view];
    }
    return self;
}

- (void)viewFrameChanged:(NSNotification *)notification {
    NSView *view = (NSView *)notification.object;
    if (view != self.auView) return;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSViewFrameDidChangeNotification
                                                  object:view];

    NSRect newFrame = self.frame;
    NSSize newSize = [self frameRectForContentRect:view.frame].size;
    newFrame.origin.y -= newSize.height - newFrame.size.height;
    newFrame.size = newSize;
    [self setFrame:newFrame display:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(viewFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:view];
}

+ (BOOL)audioUnitHasCocoaView:(AudioUnit)unit {
    UInt32 dataSize;
    Boolean isWriteable;
    OSStatus result = AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI,
                                               kAudioUnitScope_Global, 0, &dataSize, &isWriteable);
    if (result != noErr) return NO;
    UInt32 numberOfClasses = (dataSize - sizeof(CFURLRef)) / sizeof(CFStringRef);
    return numberOfClasses > 0;
}

+ (BOOL)audioUnitHasCarbonView:(AudioUnit)unit {
    UInt32 dataSize;
    Boolean isWriteable;
    OSStatus result = AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_GetUIComponentList,
                                               kAudioUnitScope_Global, 0, &dataSize, &isWriteable);
    return (result == noErr) && (dataSize >= sizeof(ComponentDescription));
}

@end

#pragma mark - C++

void ofxAudioUnit::showUI(const std::string &title, int x, int y, bool forceGeneric) {
    if (!_unit.get()) return;

    AudioUnitRef auRef = _unit;
    std::string titleCopy = title;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!auRef) return;

        ofxAudioUnitUIWindow *window = [[ofxAudioUnitUIWindow alloc] initWithAudioUnit:*auRef
                                                                          forceGeneric:forceGeneric];
        if (!window) return;

        CGFloat flippedY = [[NSScreen mainScreen] visibleFrame].size.height - y - window.frame.size.height;
        [window setFrameOrigin:NSMakePoint(x, flippedY)];
        [window setTitle:[NSString stringWithUTF8String:titleCopy.c_str()] ?: @"Audio Unit UI"];
        [window makeKeyAndOrderFront:nil];

#if !__has_feature(objc_arc)
        [window release];
#endif
    });
}

#endif //TARGET_OS_IPHONE
