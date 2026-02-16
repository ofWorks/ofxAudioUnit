#include "ofxAudioUnit.h"
#include "ofxAudioUnitUtils.h"

#if !(TARGET_OS_IPHONE)
#include <CoreAudioKit/CoreAudioKit.h>
#include <AudioUnit/AUCocoaUIView.h>

#pragma mark Objective-C

// Keep track of open windows to prevent premature release
static NSMutableSet *gOpenWindows = nil;

static NSMutableSet* GetOpenWindows() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gOpenWindows = [[NSMutableSet alloc] init];
    });
    return gOpenWindows;
}

@interface ofxAudioUnitUIWindow : NSWindow

@property (nonatomic, strong) NSView *auView;

- (instancetype)initWithAudioUnit:(AudioUnit)unit forceGeneric:(BOOL)useGeneric;

@end

@implementation ofxAudioUnitUIWindow

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSViewFrameDidChangeNotification
                                                  object:self.auView];

    // Remove from tracking set
    [[GetOpenWindows() objectsPassingTest:^BOOL(id obj, BOOL *stop) {
        return obj == self;
    }] enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
        [GetOpenWindows() removeObject:obj];
    }];

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
        view = [self createCocoaViewForUnit:unit];
        if (!view) {
            view = [self createGenericViewForUnit:unit];
        }
    } else if ([ofxAudioUnitUIWindow audioUnitHasCarbonView:unit]) {
        [self printUnsupportedCarbonMessage:unit];
        return nil;
    } else {
        view = [self createGenericViewForUnit:unit];
    }

    if (!view) {
        return nil;
    }

    self = [self initWithAudioUnitView:view];

    // Add to tracking set to keep a strong reference
    if (self) {
        [GetOpenWindows() addObject:self];
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
    OSStatus result = AudioUnitGetPropertyInfo(unit,
                                               kAudioUnitProperty_CocoaUI,
                                               kAudioUnitScope_Global,
                                               0,
                                               &dataSize,
                                               &isWriteable);

    if (result != noErr) {
        return nil;
    }

    UInt32 numberOfClasses = (dataSize - sizeof(CFURLRef)) / sizeof(CFStringRef);
    if (numberOfClasses == 0) {
        return nil;
    }

    AudioUnitCocoaViewInfo *cocoaViewInfo = (AudioUnitCocoaViewInfo *)malloc(dataSize);
    if (!cocoaViewInfo) {
        return nil;
    }

    NSView *view = nil;
    OSStatus success = AudioUnitGetProperty(unit,
                                            kAudioUnitProperty_CocoaUI,
                                            kAudioUnitScope_Global,
                                            0,
                                            cocoaViewInfo,
                                            &dataSize);

    if (success == noErr) {
        CFURLRef bundlePath = cocoaViewInfo->mCocoaAUViewBundleLocation;
        CFStringRef className = cocoaViewInfo->mCocoaAUViewClass[0];
        NSBundle *bundle = [NSBundle bundleWithURL:(__bridge NSURL *)bundlePath];

        if (bundle) {
            Class factoryClass = [bundle classNamed:(__bridge NSString *)className];
            if (factoryClass) {
                id<AUCocoaUIBase> factory = [[factoryClass alloc] init];
                if (factory) {
                    view = [factory uiViewForAudioUnit:unit withSize:NSZeroSize];
#if !__has_feature(objc_arc)
                    [factory release];
#endif
                }
            }
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
        self.releasedWhenClosed = NO;  // Don't release when closed, we'll manage it

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

- (void)printUnsupportedCarbonMessage:(AudioUnit)unit {
    NSLog(@"This audio unit only has a Carbon-based UI. Carbon support has been removed from ofxAudioUnit.");
}

+ (BOOL)audioUnitHasCocoaView:(AudioUnit)unit {
    UInt32 dataSize;
    Boolean isWriteable;
    OSStatus result = AudioUnitGetPropertyInfo(unit,
                                               kAudioUnitProperty_CocoaUI,
                                               kAudioUnitScope_Global,
                                               0,
                                               &dataSize,
                                               &isWriteable);

    if (result != noErr) return NO;

    UInt32 numberOfClasses = (dataSize - sizeof(CFURLRef)) / sizeof(CFStringRef);
    return numberOfClasses > 0;
}

+ (BOOL)audioUnitHasCarbonView:(AudioUnit)unit {
    UInt32 dataSize;
    Boolean isWriteable;
    OSStatus result = AudioUnitGetPropertyInfo(unit,
                                               kAudioUnitProperty_GetUIComponentList,
                                               kAudioUnitScope_Global,
                                               0,
                                               &dataSize,
                                               &isWriteable);

    return (result == noErr) && (dataSize >= sizeof(ComponentDescription));
}

@end

#pragma mark - C++

using namespace std;

void ofxAudioUnit::showUI(const string &title, int x, int y, bool forceGeneric) {
    if (!_unit.get()) return;

    AudioUnitRef auRef = _unit;
    string titleCopy = title;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!auRef) return;

        ofxAudioUnitUIWindow *window = [[ofxAudioUnitUIWindow alloc] initWithAudioUnit:*auRef
                                                                          forceGeneric:forceGeneric];
        if (!window) return;

        CGFloat flippedY = [[NSScreen mainScreen] visibleFrame].size.height - y - window.frame.size.height;
        [window setFrameOrigin:NSMakePoint(x, flippedY)];

        NSString *windowTitle = [NSString stringWithUTF8String:titleCopy.c_str()];
        [window setTitle:windowTitle ?: @"Audio Unit UI"];
        [window makeKeyAndOrderFront:nil];

#if !__has_feature(objc_arc)
        [window release];
#endif
    });
}

#endif //TARGET_OS_IPHONE
