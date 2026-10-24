#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <math.h>

extern void uuss_call_swift_method(void *fn, void *swiftSelf, void *arg0);
extern void uuss_call_swift_geometry(void *fn, void *swiftSelf, double a, double b);

#define UULog(fmt, ...) NSLog(@"[UUScreenSwitch] " fmt, ##__VA_ARGS__)

static const uint8_t kItemTypeShowDesktop      = 3;
static const uint8_t kItemTypeExpandAllWindows = 4;

static const char *kClsToolBar   = "_TtC14nrd_ios_client13RemoteToolBar";
static const char *kClsItem      = "_TtC14nrd_ios_clientP33_7245C1225B2709A2490E4B814BBC544E17RemoteToolBarItem";
static const char *kClsViewModel = "_TtC14nrd_ios_client21ControlPanelViewModel";

static char kAssocDisplayIndex;   // NSNumber: 0 / 1 / -1(不处理)
static char kAssocNormalColor;    // UIColor: 按钮原始文字/图标颜色
static char kAssocActiveIndex;    // NSNumber: session 当前选中的屏幕索引兜底
static char kAssocToolBarWatcher; // UUToolBarWatcher: 定时同步多屏菜单切换状态

static inline SEL kUUAssocViewportMemory(void) {
    return sel_registerName("uu_assoc_viewport_memory");
}

static inline SEL kUUViewportEngineActive(void) {
    return sel_registerName("uu_viewport_engine_active");
}

static IMP sOrigLayout          = NULL;
static IMP sOrigDidClick        = NULL;
static IMP sOrigContentLayout   = NULL;
static IMP sOrigRenderTransform = NULL;

static void UUUpdateToolBar(UIView *toolBar);

// ---- Helpers -----------------------------------------------------------------

static intptr_t UUMainImageSlide(void) {
    static intptr_t slide = 0;
    static BOOL resolved = NO;
    if (resolved) return slide;
    resolved = YES;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0;
        if (len >= 15 && strcmp(name + len - 15, "/nrd-ios-client") == 0) {
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    return slide;
}

static BOOL UUIsSupportedAppVersion(void) {
    return YES;
}

static BOOL UUIsMainImagePointer(void *ptr) {
    uintptr_t addr = (uintptr_t)ptr;
    if (addr < 0x100000000ULL) return NO;
    intptr_t slide = UUMainImageSlide();
    return slide && addr >= (uintptr_t)(slide + 0x100000000ULL) && addr < (uintptr_t)(slide + 0x103000000ULL);
}

static Class UUItemClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = objc_getClass(kClsItem);
        if (!cls) {
            int numClasses = objc_getClassList(NULL, 0);
            if (numClasses > 0) {
                Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
                numClasses = objc_getClassList(classes, numClasses);
                for (int i = 0; i < numClasses; i++) {
                    const char *name = class_getName(classes[i]);
                    if (strstr(name, "RemoteToolBarItem") != NULL) {
                        cls = classes[i];
                        break;
                    }
                }
                free(classes);
            }
        }
    });
    return cls;
}

static id UUObjectIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

static BOOL UURawIvar(id obj, const char *name, void *out, size_t size) {
    if (!obj || !out || size == 0) return NO;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return NO;
    ptrdiff_t offset = ivar_getOffset(iv);
    if (offset < 0 || (size_t)offset + size > class_getInstanceSize(object_getClass(obj))) return NO;
    memcpy(out, (const uint8_t *)(__bridge void *)obj + offset, size);
    return YES;
}

static UIWindow *UUKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

static void UUToast(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = UUKeyWindow();
        if (!win) return;
        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        label.textAlignment = NSTextAlignmentCenter;
        label.layer.cornerRadius = 8;
        label.layer.masksToBounds = YES;
        [label sizeToFit];
        CGRect f = label.frame;
        f.size.width += 24;
        f.size.height += 16;
        label.frame = f;
        label.center = CGPointMake(win.bounds.size.width / 2.0, win.bounds.size.height - 100);
        label.alpha = 0;
        [win addSubview:label];
        [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1.0; } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25 delay:1.2 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL f2) {
                [label removeFromSuperview];
            }];
        }];
    });
}

static id UUViewModelFromVC(UIViewController *vc, Class vmCls) {
    id vm = UUObjectIvar(vc, "viewModel");
    return (vm && [vm isKindOfClass:vmCls]) ? vm : nil;
}

static id UUSearchVCTree(UIViewController *vc, Class vmCls, int depth) {
    if (!vc || depth > 12) return nil;
    id vm = UUViewModelFromVC(vc, vmCls);
    if (vm) return vm;
    for (UIViewController *child in vc.childViewControllers) {
        vm = UUSearchVCTree(child, vmCls, depth + 1);
        if (vm) return vm;
    }
    return UUSearchVCTree(vc.presentedViewController, vmCls, depth + 1);
}

static id UUFindViewModel(UIView *from) {
    Class vmCls = objc_getClass(kClsViewModel);
    if (!vmCls) return nil;
    id cvc = UUObjectIvar(from, "contentViewController");
    if ([cvc isKindOfClass:[UIViewController class]]) {
        id vm = UUViewModelFromVC((UIViewController *)cvc, vmCls);
        if (vm) return vm;
    }
    for (UIResponder *r = from; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            id vm = UUViewModelFromVC((UIViewController *)r, vmCls);
            if (vm) return vm;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            id vm = UUSearchVCTree(w.rootViewController, vmCls, 0);
            if (vm) return vm;
        }
    }
    return nil;
}

static int32_t UUScreenID(id screen) {
    if (!screen) return -1;
    SEL sel = sel_registerName("screen_id");
    if ([screen respondsToSelector:sel]) {
        return ((int32_t (*)(id, SEL))(void *)objc_msgSend)(screen, sel);
    }
    int32_t raw = -1;
    if (UURawIvar(screen, "screen_id", &raw, sizeof(raw)) && raw >= 0) return raw;
    return -1;
}

static NSInteger UUCurrentDisplayIndex(UIView *toolBar) {
    id vm = UUFindViewModel(toolBar);
    if (!vm) return -1;
    id session = UUObjectIvar(vm, "session");
    if (!session) return -1;

    id currentInfo = UUObjectIvar(session, "$__lazy_storage_$_currentScreenInfo");
    int32_t activeID = UUScreenID(currentInfo);

    if (activeID < 0) {
        uint8_t optional[5] = {0, 0, 0, 0, 1};
        if (UURawIvar(session, "currentScreenID", optional, sizeof(optional)) && !(optional[4] & 1)) {
            memcpy(&activeID, optional, sizeof(activeID));
        }
    }

    uintptr_t raw = 0;
    if (!UURawIvar(session, "screenInfos", &raw, sizeof(raw)) || !raw) {
        NSNumber *saved = objc_getAssociatedObject(toolBar, &kAssocActiveIndex);
        return saved ? saved.integerValue : -1;
    }
    if (raw & 0xC000000000000001ULL) {
        NSNumber *saved = objc_getAssociatedObject(toolBar, &kAssocActiveIndex);
        return saved ? saved.integerValue : -1;
    }

    NSInteger count = *(NSInteger *)(raw + 0x10);
    if (count <= 0 || count > 16) {
        NSNumber *saved = objc_getAssociatedObject(toolBar, &kAssocActiveIndex);
        return saved ? saved.integerValue : -1;
    }

    void **items = (void **)(raw + 0x20);
    for (NSInteger i = 0; i < count; i++) {
        id screen = (__bridge id)items[i];
        if (activeID >= 0 && UUScreenID(screen) == activeID) {
            objc_setAssociatedObject(toolBar, &kAssocActiveIndex, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return i;
        }
    }

    if (activeID < 0) {
        NSNumber *saved = objc_getAssociatedObject(toolBar, &kAssocActiveIndex);
        return saved ? saved.integerValue : 0;
    }
    return -1;
}

static BOOL UUFunctionLoadsScreenIDSel(const uint32_t *insns, uintptr_t imageStart, uintptr_t imageEnd) {
    for (size_t i = 0; i < 24; i++) {
        uint32_t insn = insns[i];
        if ((insn & 0x9f000000) != 0x90000000) continue;
        int64_t immhi = (int32_t)((insn >> 5) & 0x7ffff);
        immhi = (immhi << 13) >> 13;
        int64_t immlo = (insn >> 29) & 0x3;
        int64_t pageOffset = (immhi << 2) | immlo;
        uintptr_t pcPage = ((uintptr_t)&insns[i]) & ~0xfffULL;
        uintptr_t page = pcPage + (pageOffset << 12);
        uint32_t reg = insn & 0x1f;

        for (size_t j = i + 1; j < i + 8 && j < 24; j++) {
            uint32_t next = insns[j];
            uintptr_t target = 0;
            if ((next & 0xffc00000) == 0x91000000 && ((next >> 5) & 0x1f) == reg) {
                uint32_t imm12 = (next >> 10) & 0xfff;
                target = page + imm12;
            } else if ((next & 0xffc00000) == 0xf9400000 && ((next >> 5) & 0x1f) == reg) {
                uint32_t imm12 = ((next >> 10) & 0xfff) << 3;
                target = page + imm12;
            }
            if (target >= imageStart && target + 8 <= imageEnd) {
                const char *candidate = (const char *)target;
                if ((next & 0xffc00000) == 0xf9400000) {
                    uintptr_t loaded = *(uintptr_t *)target;
                    if (loaded >= imageStart && loaded < imageEnd) candidate = (const char *)loaded;
                }
                if (strncmp(candidate, "screen_id", 9) == 0) return YES;
            }
        }
    }
    return NO;
}

static void *UUSwitchScreenFunction(void) {
    static void *fn = NULL;
    static BOOL resolved = NO;
    if (resolved) return fn;
    resolved = YES;

    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0;
        if (len >= 15 && strcmp(name + len - 15, "/nrd-ios-client") == 0) {
            mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!mh) { UULog(@"main image not found"); return NULL; }

    uintptr_t textStart = (uintptr_t)mh;
    uintptr_t textEnd = textStart + 0x02600000ULL;
    uintptr_t imageEnd = textStart + 0x04000000ULL;
    const uint8_t *cmdPtr = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmdPtr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmdPtr;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                textStart = (uintptr_t)(seg->vmaddr + slide);
                textEnd = textStart + (uintptr_t)seg->vmsize;
            } else if (strcmp(seg->segname, "__LINKEDIT") != 0 && seg->vmsize > 0) {
                uintptr_t segEnd = (uintptr_t)(seg->vmaddr + slide) + (uintptr_t)seg->vmsize;
                if (segEnd > imageEnd) imageEnd = segEnd;
            }
        }
        cmdPtr += lc->cmdsize;
    }

    Class vmCls = objc_getClass(kClsViewModel);
    if (vmCls) {
        uintptr_t *words = (uintptr_t *)(__bridge void *)vmCls;
        for (size_t off = 0x50 / sizeof(uintptr_t); off < 0x1000 / sizeof(uintptr_t); off++) {
            uintptr_t raw = words[off];
            uintptr_t candidate = raw & 0x0000ffffffffffffULL;
            if (candidate >= textStart + 0x4000 && candidate + 96 < textEnd && (candidate & 0x3) == 0) {
                if (UUFunctionLoadsScreenIDSel((const uint32_t *)candidate, textStart, imageEnd)) {
                    fn = (void *)candidate;
                    UULog(@"resolved switchScreen via vtable[+0x%zx] = %p", off * sizeof(uintptr_t), fn);
                    return fn;
                }
            }
        }
    }
    UULog(@"switchScreen not found in vtable");
    return NULL;
}

// ---- Viewport Memory & Position Fix ------------------------------------------

@interface UUViewportSnapshot : NSObject
@property (nonatomic) double zoom;
@property (nonatomic) CGPoint offset;
@property (nonatomic) CGSize frameSize;
@end
@implementation UUViewportSnapshot
@end

static BOOL UUReadViewport(UIView *view, UUViewportSnapshot *snapshot) {
    Ivar temp = class_getInstanceVariable(view.class, "_tempZoomScale");
    Ivar min = class_getInstanceVariable(view.class, "minimumZoomScale");
    Ivar content = class_getInstanceVariable(view.class, "_contentSize");
    if (!temp || !min || !content) return NO;
    ptrdiff_t offset = ivar_getOffset(temp);
    if (ivar_getOffset(min) != offset + 16 || ivar_getOffset(content) != offset + 32) return NO;
    if (offset < 0 || (size_t)offset + 16 > class_getInstanceSize(view.class)) return NO;
    double zoom;
    memcpy(&zoom, (uint8_t *)(__bridge void *)view + offset + 8, sizeof(double));
    snapshot.zoom = zoom;
    CGPoint position;
    CGSize frame;
    if (!UURawIvar(view, "_contentOffset", &position, sizeof(position)) ||
        !UURawIvar(view, "videoFrameSize", &frame, sizeof(frame))) return NO;
    snapshot.offset = position;
    snapshot.frameSize = frame;
    return isfinite(snapshot.zoom) && snapshot.zoom > 0.001 && snapshot.zoom < 128 &&
        isfinite(position.x) && isfinite(position.y) && fabs(position.x) < 1e7 && fabs(position.y) < 1e7 &&
        isfinite(frame.width) && isfinite(frame.height) && frame.width > 0 && frame.height > 0;
}

static int32_t UUViewportCurrentScreenID(id session) {
    int32_t sid = UUScreenID(UUObjectIvar(session, "$__lazy_storage_$_currentScreenInfo"));
    if (sid >= 0) return sid;
    uint8_t optional[5] = {0, 0, 0, 0, 1};
    if (UURawIvar(session, "currentScreenID", optional, sizeof(optional)) && !(optional[4] & 1)) {
        memcpy(&sid, optional, sizeof(sid));
        if (sid >= 0) return sid;
    }
    uintptr_t raw = 0;
    if (UURawIvar(session, "screenInfos", &raw, sizeof(raw)) && raw && !(raw & 0xC000000000000001ULL)) {
        NSInteger count = *(NSInteger *)(raw + 0x10);
        if (count > 0 && count <= 16) return UUScreenID((__bridge id)(*(void **)(raw + 0x20)));
    }
    return -1;
}

static BOOL UUViewportFunctions(void **zoom, void **offset) {
    if (!UUIsSupportedAppVersion()) return NO;
    intptr_t slide = UUMainImageSlide();
    if (!slide) return NO;
    *zoom = (void *)(slide + 0x100849440);
    *offset = (void *)(slide + 0x10084b0dc);
    return UUIsMainImagePointer(*zoom) && UUIsMainImagePointer(*offset) &&
        memcmp(*zoom, (const uint32_t[]){0x6dbe23e9u, 0xa9017bfdu, 0x910043fdu, 0xb0010b68u}, 16) == 0 &&
        memcmp(*offset, (const uint32_t[]){0x6db923e9u, 0xa9016ffcu, 0xa90267fau, 0xa9035ff8u}, 16) == 0;
}

static BOOL UUApplyViewport(UIView *view, UUViewportSnapshot *saved) {
    void *zoomFn = NULL, *offsetFn = NULL;
    if (!UUViewportFunctions(&zoomFn, &offsetFn)) return NO;
    UUViewportSnapshot *current = [UUViewportSnapshot new];
    if (!UUReadViewport(view, current)) return NO;
    CGPoint point = saved.offset;
    point.x *= current.frameSize.width / saved.frameSize.width;
    point.y *= current.frameSize.height / saved.frameSize.height;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        uuss_call_swift_geometry(zoomFn, (__bridge void *)view, saved.zoom, 0);
        uuss_call_swift_geometry(offsetFn, (__bridge void *)view, point.x, point.y);
    }];
    [CATransaction commit];
    return YES;
}

typedef void (*UURenderTransformFn)(id, SEL, id, uint64_t, float, float, float, float, float, float);
static const char *kRenderTransformSelector = "setTransformFor:forHandel:scale_x:scale_y:trans_x:trans_y:pivot_x:pivot_y:";

@interface UUDeferredRenderTransform : NSObject
@property (nonatomic, weak) id manager;
@property (nonatomic, weak) id renderView;
@property (nonatomic) uint64_t handle;
@property (nonatomic) float sx, sy, tx, ty, px, py;
@end
@implementation UUDeferredRenderTransform
@end

static void UUForwardRenderTransform(UUDeferredRenderTransform *packet) {
    id manager = packet.manager, view = packet.renderView;
    if (manager && view && sOrigRenderTransform) {
        ((UURenderTransformFn)sOrigRenderTransform)(manager, sel_registerName(kRenderTransformSelector), view,
            packet.handle, packet.sx, packet.sy, packet.tx, packet.ty, packet.px, packet.py);
    }
}

@class UUViewportMemory;
static void UURefreshViewportBindings(UUViewportMemory *memory);

@interface UUViewportMemory : NSObject
@property (nonatomic, weak) id session;
@property (nonatomic, weak) id viewModel;
@property (nonatomic, weak) UIView *content;
@property (nonatomic, weak) id renderView;
@property (nonatomic, strong) UUDeferredRenderTransform *deferredTransform;
@property (nonatomic, strong) UUDeferredRenderTransform *lastRenderTransform;
@property (nonatomic) NSUInteger renderSerial;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UUViewportSnapshot *> *screens;
@property (nonatomic, strong) UUViewportSnapshot *pending;
@property (nonatomic, strong) UUViewportSnapshot *lastApplied;
@property (nonatomic, strong) UUViewportSnapshot *source;
@property (nonatomic, strong) UUViewportSnapshot *lastDesired;
@property (nonatomic) int32_t sourceID;
@property (nonatomic) CFRunLoopObserverRef observer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) int32_t targetID;
@property (nonatomic) CFTimeInterval started;
@property (nonatomic) BOOL applying;
@property (nonatomic) BOOL restoringForeground;
- (void)stop;
- (void)start;
- (void)willResign:(NSNotification *)note;
- (void)didBecomeActive:(NSNotification *)note;
- (void)tick:(NSTimer *)timer;
@end

@implementation UUViewportMemory
- (instancetype)init {
    if ((self = [super init])) {
        _screens = [NSMutableDictionary dictionary];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(willResign:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}
- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    if (_observer) {
        CFRunLoopObserverInvalidate(_observer);
        CFRelease(_observer);
        _observer = NULL;
    }
    self.restoringForeground = NO;
    self.pending = nil;
    self.lastApplied = nil;
    self.source = nil;
    self.lastDesired = nil;
    self.deferredTransform = nil;
    self.lastRenderTransform = nil;
}
- (void)start {
    __weak UUViewportMemory *weakMemory = self;
    if (!self.restoringForeground) _observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
        kCFRunLoopBeforeWaiting | kCFRunLoopExit, YES, -1000, ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            [weakMemory tick:nil];
        });
    if (_observer) CFRunLoopAddObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
    self.timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        UUViewportMemory *memory = weakMemory;
        if (memory) [memory tick:timer]; else [timer invalidate];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)willResign:(NSNotification *)note {
    UURefreshViewportBindings(self);
    UUViewportSnapshot *snapshot = [UUViewportSnapshot new];
    int32_t sid = UUViewportCurrentScreenID(self.session);
    UUViewportSnapshot *desired = sid == self.targetID ? self.pending :
        (sid == self.sourceID ? self.source : nil);
    if (sid >= 0 && desired) {
        self.screens[@(sid)] = desired;
    } else if (sid >= 0 && UUReadViewport(self.content, snapshot)) {
        self.screens[@(sid)] = snapshot;
    }
    [self stop];
}
- (void)didBecomeActive:(NSNotification *)note {
    id vm = UUFindViewModel(nil);
    if (UUObjectIvar(vm, "session") == self.session) self.viewModel = vm;
    UURefreshViewportBindings(self);
    int32_t sid = UUViewportCurrentScreenID(self.session);
    UUViewportSnapshot *saved = self.screens[@(sid)];
    [self stop];
    if (!saved || !self.content || !self.session) return;
    self.restoringForeground = YES;
    self.pending = self.source = saved;
    self.targetID = self.sourceID = sid;
    self.started = CACurrentMediaTime();
    [self start];
    [self tick:nil];
}
- (void)tick:(NSTimer *)timer {
    if (self.applying || !self.pending) return;
    UURefreshViewportBindings(self);
    UIView *view = self.content;
    id session = self.session;
    CFTimeInterval now = CACurrentMediaTime();
    if (!session || (!self.restoringForeground && now - self.started > 3.0) ||
        objc_getAssociatedObject(view, kUUAssocViewportMemory()) != self) { [self stop]; return; }
    if (!view.window) return;
    int32_t currentID = UUViewportCurrentScreenID(session);
    if (currentID != self.targetID && currentID != self.sourceID) { [self stop]; return; }
    UUViewportSnapshot *desired = currentID == self.targetID ? self.pending : self.source;
    if (!desired) return;
    BOOL touching = NO, zooming = NO;
    UURawIvar(view, "isTouching", &touching, 1);
    UURawIvar(view, "isZooming", &zooming, 1);
    if (touching || zooming) { [self stop]; return; }
    UUViewportSnapshot *current = [UUViewportSnapshot new];
    if (!UUReadViewport(view, current)) return;
    UUViewportSnapshot *last = self.lastApplied;
    BOOL changed = !last || self.lastDesired != desired || fabs(current.zoom - last.zoom) > 0.0001 ||
        fabs(current.offset.x - last.offset.x) > 0.25 || fabs(current.offset.y - last.offset.y) > 0.25 ||
        !CGSizeEqualToSize(current.frameSize, last.frameSize);
    if (changed) {
        self.applying = YES;
        self.deferredTransform = nil;
        BOOL ok = UUApplyViewport(view, desired);
        UUDeferredRenderTransform *finalTransform = self.deferredTransform;
        self.deferredTransform = nil;
        if (ok && finalTransform) {
            self.lastRenderTransform = finalTransform;
            self.renderSerial++;
            UUForwardRenderTransform(finalTransform);
        }
        self.applying = NO;
        if (!ok) { [self stop]; return; }
        UUViewportSnapshot *applied = [UUViewportSnapshot new];
        if (UUReadViewport(view, applied)) {
            self.lastApplied = applied;
            self.lastDesired = desired;
            if (self.restoringForeground) {
                // Layout/render hooks keep guarding late resets without an idle polling timer.
                [self.timer invalidate];
                self.timer = nil;
            }
        }
    }
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_timer invalidate];
    if (_observer) { CFRunLoopObserverInvalidate(_observer); CFRelease(_observer); }
}
@end

static void UURefreshViewportBindings(UUViewportMemory *memory) {
    UIViewController *vc = UUObjectIvar(memory.viewModel, "contentViewController");
    if ([vc isKindOfClass:UIViewController.class]) {
        UIView *content = UUObjectIvar(vc, "$__lazy_storage_$_remoteContentView");
        if ([content isKindOfClass:objc_getClass("_TtC14nrd_ios_client17RemoteContentView")]) memory.content = content;
    }
    if (memory.content) objc_setAssociatedObject(memory.content, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Ivar iv = class_getInstanceVariable(object_getClass(memory.session), "videoRenderView");
    void *(*loadWeak)(void *) = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_unknownObjectRelease");
    if (iv && loadWeak && release) {
        void *raw = loadWeak((uint8_t *)(__bridge void *)memory.session + ivar_getOffset(iv));
        if (raw) {
            id render = (__bridge id)raw;
            if ([render isKindOfClass:UIView.class]) {
                memory.renderView = render;
                objc_setAssociatedObject(render, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            release(raw);
        }
    }
}

static void hook_render_transform(id self, SEL cmd, id view, uint64_t handle,
    float sx, float sy, float tx, float ty, float px, float py) {
    UUViewportMemory *memory = objc_getAssociatedObject(view, kUUAssocViewportMemory());
    if (NSThread.isMainThread && memory.pending && sOrigRenderTransform) {
        if (memory.applying) {
            UUDeferredRenderTransform *packet = [UUDeferredRenderTransform new];
            packet.manager = self; packet.renderView = view; packet.handle = handle;
            packet.sx = sx; packet.sy = sy; packet.tx = tx; packet.ty = ty; packet.px = px; packet.py = py;
            memory.deferredTransform = packet;
            return;
        }
        NSUInteger serial = memory.renderSerial;
        [memory tick:nil];
        UUDeferredRenderTransform *finalTransform = memory.lastRenderTransform;
        if (memory.pending && finalTransform.renderView == view && finalTransform.handle == handle) {
            if (serial == memory.renderSerial) UUForwardRenderTransform(finalTransform);
            return;
        }
    }
    if (sOrigRenderTransform) ((UURenderTransformFn)sOrigRenderTransform)(self, cmd, view, handle, sx, sy, tx, ty, px, py);
}

static void hook_content_layout(UIView *self, SEL _cmd) {
    if (sOrigContentLayout) ((void (*)(id, SEL))sOrigContentLayout)(self, _cmd);
    UUViewportMemory *memory = objc_getAssociatedObject(self, kUUAssocViewportMemory());
    if (!memory) {
        id vm = UUFindViewModel(self);
        id session = UUObjectIvar(vm, "session");
        UIViewController *vc = UUObjectIvar(vm, "contentViewController");
        void *zoom = NULL, *offset = NULL;
        if (session && UUObjectIvar(vc, "$__lazy_storage_$_remoteContentView") == self &&
            UUViewportFunctions(&zoom, &offset)) {
            memory = objc_getAssociatedObject(session, kUUAssocViewportMemory());
            if (!memory) {
                memory = [UUViewportMemory new];
                memory.session = session;
                objc_setAssociatedObject(session, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            memory.viewModel = vm;
            memory.content = self;
            UURefreshViewportBindings(memory);
        }
    }
    [memory tick:nil];
}

static UUViewportMemory *UUPrepareViewportSwitch(id vm, id session, id targetScreen) {
    void *zoom = NULL, *offset = NULL;
    if (!UUViewportFunctions(&zoom, &offset)) return nil;
    UIViewController *vc = UUObjectIvar(vm, "contentViewController");
    if (![vc isKindOfClass:UIViewController.class]) return nil;
    UIView *content = UUObjectIvar(vc, "$__lazy_storage_$_remoteContentView");
    Class cls = objc_getClass("_TtC14nrd_ios_client17RemoteContentView");
    if (!cls || ![content isKindOfClass:cls]) return nil;
    int32_t nextID = UUScreenID(targetScreen);
    int32_t currentID = UUViewportCurrentScreenID(session);
    if (nextID < 0 || currentID < 0 || nextID == currentID) return nil;
    UUViewportMemory *memory = objc_getAssociatedObject(session, kUUAssocViewportMemory());
    if (!memory) {
        memory = [UUViewportMemory new];
        memory.session = session;
        objc_setAssociatedObject(session, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UUViewportSnapshot *outgoing = [UUViewportSnapshot new];
    BOOL valid = UUReadViewport(content, outgoing);
    if (valid && !memory.pending) memory.screens[@(currentID)] = outgoing;
    UUViewportSnapshot *incoming = memory.screens[@(nextID)] ?: memory.pending ?: (valid ? outgoing : nil);
    UUViewportSnapshot *source = memory.screens[@(currentID)] ?: (valid ? outgoing : nil);
    [memory stop];
    if (!incoming) return nil;
    memory.viewModel = vm;
    memory.content = content;
    UURefreshViewportBindings(memory);
    memory.targetID = nextID;
    memory.pending = incoming;
    memory.source = source;
    memory.sourceID = currentID;
    objc_setAssociatedObject(content, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    memory.started = CACurrentMediaTime();
    return memory;
}

static void UUSwitchToDisplay(UIView *toolBar, NSInteger index) {
    void *fn = UUSwitchScreenFunction();
    if (!fn) {
        UUToast(@"未找到切屏入口");
        return;
    }

    id vm = UUFindViewModel(toolBar);
    if (!vm) { UUToast(@"未找到远控会话"); return; }
    id session = UUObjectIvar(vm, "session");
    if (!session) { UUToast(@"会话未建立"); return; }

    uintptr_t raw = 0;
    if (!UURawIvar(session, "screenInfos", &raw, sizeof(raw)) || !raw) {
        UUToast(@"未读取到屏幕列表");
        return;
    }
    if (raw & 0xC000000000000001ULL) {
        UUToast(@"屏幕列表被锁定");
        return;
    }

    NSInteger count = *(NSInteger *)(raw + 0x10);
    if (count <= 0 || count > 16) {
        UUToast(@"屏幕列表数量异常");
        return;
    }

    if (index < 0 || index >= count) {
        UUToast([NSString stringWithFormat:@"当前仅检测到 %ld 台显示器", (long)count]);
        return;
    }

    void **items = (void **)(raw + 0x20);
    id targetScreen = (__bridge id)items[index];

    id currentInfo = UUObjectIvar(session, "$__lazy_storage_$_currentScreenInfo");
    int32_t activeID = UUScreenID(currentInfo);
    if (activeID == UUScreenID(targetScreen)) {
        UUToast([NSString stringWithFormat:@"当前已是显示器%ld", (long)(index + 1)]);
        return;
    }

    UUViewportMemory *memory = UUPrepareViewportSwitch(vm, session, targetScreen);

    uuss_call_swift_method(fn, (__bridge void *)vm, (__bridge void *)targetScreen);

    objc_setAssociatedObject(toolBar, &kAssocActiveIndex, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UUUpdateToolBar(toolBar);

    if (memory) {
        [memory start];
        [memory tick:nil];
    }
}

// ---- Toolbar Replacement & Blue Indicator ------------------------------------

static UIColor *UUActiveBlueColor(void) {
    return [UIColor colorWithRed:0x3A / 255.0 green:0x7B / 255.0 blue:0xFB / 255.0 alpha:1.0];
}

static UILabel *UUFirstLabel(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return (UILabel *)v;
    for (UIView *sub in v.subviews) {
        UILabel *l = UUFirstLabel(sub);
        if (l) return l;
    }
    return nil;
}

static UIImageView *UUFirstImageView(UIView *v) {
    if ([v isKindOfClass:[UIImageView class]]) return (UIImageView *)v;
    for (UIView *sub in v.subviews) {
        UIImageView *iv = UUFirstImageView(sub);
        if (iv) return iv;
    }
    return nil;
}

static UILabel *UUItemLabel(UIView *item) {
    id l = UUObjectIvar(item, "textLabel");
    if ([l isKindOfClass:[UILabel class]]) return (UILabel *)l;
    return UUFirstLabel(item);
}

static UIImageView *UUItemIcon(UIView *item) {
    id iv = UUObjectIvar(item, "iconImageView");
    if ([iv isKindOfClass:[UIImageView class]]) return (UIImageView *)iv;
    return UUFirstImageView(item);
}

static BOOL UUTextMatchesKeys(NSString *text, NSArray<NSString *> *keys) {
    if (!text.length) return NO;
    for (NSString *k in keys) {
        if ([text containsString:k]) return YES;
    }
    return NO;
}

static NSInteger UUClassifyItem(UIView *item) {
    uint8_t rawType = 0;
    if (UURawIvar(item, "itemType", &rawType, sizeof(rawType))) {
        if (rawType == kItemTypeExpandAllWindows) return 0;
        if (rawType == kItemTypeShowDesktop)      return 1;
    }
    UILabel *label = UUItemLabel(item);
    NSString *text = label.text ?: @"";
    if (UUTextMatchesKeys(text, @[@"展开所有窗口", @"展开全部窗口", @"展开", @"所有窗口", @"全部窗口", @"显示器1"])) return 0;
    if (UUTextMatchesKeys(text, @[@"显示桌面", @"回到桌面", @"桌面", @"显示器2"])) return 1;
    return -1;
}

static UIImage *UUDisplayIcon(NSInteger index, CGSize size, UIColor *color) {
    if (size.width <= 0 || size.height <= 0) size = CGSizeMake(24, 24);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    fmt.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [color setStroke];
        [color setFill];
        CGContextSetLineWidth(c, 1.5);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        CGContextSetLineCap(c, kCGLineCapRound);

        CGRect screenRect = CGRectMake(2.5, 3.5, size.width - 5.0, size.height - 10.0);
        UIBezierPath *screenPath = [UIBezierPath bezierPathWithRoundedRect:screenRect cornerRadius:2.0];
        screenPath.lineWidth = 1.5;
        [screenPath stroke];

        CGFloat midX = size.width / 2.0;
        CGFloat standTop = CGRectGetMaxY(screenRect);
        CGFloat standBottom = size.height - 3.5;
        UIBezierPath *stand = [UIBezierPath bezierPath];
        [stand moveToPoint:CGPointMake(midX, standTop)];
        [stand addLineToPoint:CGPointMake(midX, standBottom)];
        [stand stroke];

        UIBezierPath *base = [UIBezierPath bezierPath];
        [base moveToPoint:CGPointMake(midX - 4.5, standBottom)];
        [base addLineToPoint:CGPointMake(midX + 4.5, standBottom)];
        [base stroke];

        NSString *numStr = (index == 0) ? @"1" : @"2";
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:9.0 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: color,
        };
        CGSize strSize = [numStr sizeWithAttributes:attrs];
        CGRect strRect = CGRectMake(
            midX - strSize.width / 2.0,
            screenRect.origin.y + (screenRect.size.height - strSize.height) / 2.0 - 0.5,
            strSize.width,
            strSize.height
        );
        [numStr drawInRect:strRect withAttributes:attrs];
    }];
}

static void UUStyleItem(UIView *item, NSInteger index, BOOL active) {
    UILabel *label = UUItemLabel(item);
    UIImageView *icon = UUItemIcon(item);

    if (label && !objc_getAssociatedObject(item, &kAssocNormalColor)) {
        UIColor *normal = label.textColor ?: UIColor.whiteColor;
        objc_setAssociatedObject(item, &kAssocNormalColor, normal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIColor *normal = objc_getAssociatedObject(item, &kAssocNormalColor) ?: UIColor.whiteColor;
    UIColor *targetColor = active ? UUActiveBlueColor() : normal;

    NSString *title = (index == 0) ? @"显示器1" : @"显示器2";
    if (label) {
        if (![label.text isEqualToString:title]) label.text = title;
        label.textColor = targetColor;
    }

    if (icon) {
        CGSize sz = icon.bounds.size;
        if (sz.width <= 0 || sz.height <= 0) sz = CGSizeMake(24, 24);
        icon.image = UUDisplayIcon(index, sz, targetColor);
        if ([icon respondsToSelector:@selector(setTintColor:)]) {
            icon.tintColor = targetColor;
        }
    }
}

static void UUCollectItems(UIView *v, Class itemCls, NSMutableArray *out, int depth) {
    if (!v || depth > 4) return;
    if (itemCls && [v isKindOfClass:itemCls]) {
        [out addObject:v];
        return;
    }
    for (UIView *sub in v.subviews) UUCollectItems(sub, itemCls, out, depth + 1);
}

@interface UUToolBarWatcher : NSObject
@property (nonatomic, weak) UIView *toolBar;
@property (nonatomic, strong) NSTimer *timer;
@end
@implementation UUToolBarWatcher
- (void)tick {
    UIView *tb = self.toolBar;
    if (!tb || !tb.window) {
        [self.timer invalidate];
        self.timer = nil;
        return;
    }
    UUUpdateToolBar(tb);
}
@end

static void UUEnsureWatcher(UIView *toolBar) {
    if (objc_getAssociatedObject(toolBar, &kAssocToolBarWatcher)) return;
    UUToolBarWatcher *w = [UUToolBarWatcher new];
    w.toolBar = toolBar;
    w.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:w selector:@selector(tick) userInfo:nil repeats:YES];
    objc_setAssociatedObject(toolBar, &kAssocToolBarWatcher, w, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void UUUpdateToolBar(UIView *toolBar) {
    Class itemCls = UUItemClass();
    NSMutableArray *items = [NSMutableArray array];
    UUCollectItems(toolBar, itemCls, items, 0);

    NSInteger activeIdx = UUCurrentDisplayIndex(toolBar);
    UUEnsureWatcher(toolBar);

    id vm = UUFindViewModel(toolBar);
    id session = vm ? UUObjectIvar(vm, "session") : nil;
    if (session && !objc_getAssociatedObject(session, kUUAssocViewportMemory())) {
        UUViewportMemory *mem = [UUViewportMemory new];
        mem.session = session;
        mem.viewModel = vm;
        objc_setAssociatedObject(session, kUUAssocViewportMemory(), mem, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UURefreshViewportBindings(mem);
    }

    for (UIView *item in items) {
        NSNumber *saved = objc_getAssociatedObject(item, &kAssocDisplayIndex);
        NSInteger kind = saved ? saved.integerValue : UUClassifyItem(item);
        if (kind == 0 || kind == 1) {
            objc_setAssociatedObject(item, &kAssocDisplayIndex, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UUStyleItem(item, kind, activeIdx == kind);
        } else {
            objc_setAssociatedObject(item, &kAssocDisplayIndex, @(-1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

// ---- Hooks -------------------------------------------------------------------

static void hook_layoutSubviews(UIView *self, SEL _cmd) {
    if (sOrigLayout) ((void (*)(id, SEL))sOrigLayout)(self, _cmd);
    @try {
        UUUpdateToolBar(self);
    } @catch (NSException *e) {
        UULog(@"layout exception: %@", e);
    }
}

static void hook_didClickButton(UIView *self, SEL _cmd, id sender) {
    UIView *v = nil;
    if ([sender isKindOfClass:[UIGestureRecognizer class]]) v = ((UIGestureRecognizer *)sender).view;
    else if ([sender isKindOfClass:[UIView class]]) v = sender;

    Class itemCls = UUItemClass();
    for (int d = 0; v && v != self && d < 6; d++, v = v.superview) {
        if (itemCls && [v isKindOfClass:itemCls]) {
            NSNumber *idx = objc_getAssociatedObject(v, &kAssocDisplayIndex);
            if (idx && (idx.integerValue == 0 || idx.integerValue == 1)) {
                UUSwitchToDisplay(self, idx.integerValue);
                return;
            }
            break;
        }
    }
    if (sOrigDidClick) ((void (*)(id, SEL, id))sOrigDidClick)(self, _cmd, sender);
}

static BOOL UUHook(Class cls, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { UULog(@"method not found: %@", NSStringFromSelector(sel)); return NO; }
    BOOL own = NO;
    unsigned int c = 0;
    Method *list = class_copyMethodList(cls, &c);
    for (unsigned int i = 0; i < c; i++) if (list[i] == m) { own = YES; break; }
    free(list);
    if (!own) {
        *orig = method_getImplementation(m);
        return class_addMethod(cls, sel, imp, method_getTypeEncoding(m));
    }
    *orig = method_setImplementation(m, imp);
    return YES;
}

static void UUInstall(void) {
    static BOOL toolbarTried = NO;

    Class tb = objc_getClass(kClsToolBar);
    if (!toolbarTried && tb) {
        toolbarTried = YES;
        BOOL a = UUHook(tb, @selector(layoutSubviews), (IMP)hook_layoutSubviews, &sOrigLayout);
        BOOL b = UUHook(tb, @selector(didClickButton:), (IMP)hook_didClickButton, &sOrigDidClick);
        UULog(@"toolbar hooks: layout=%d click=%d", a, b);
    }

    SEL engineKey = kUUViewportEngineActive();
    if (!objc_getAssociatedObject(UIApplication.sharedApplication, engineKey)) {
        static BOOL renderTried = NO, contentTried = NO;
        Class renderer = objc_getClass("StreamerManager");
        if (!renderTried && renderer && UUIsSupportedAppVersion()) {
            renderTried = YES;
            SEL sel = sel_registerName(kRenderTransformSelector);
            Method method = class_getInstanceMethod(renderer, sel);
            BOOL signature = method && method_getNumberOfArguments(method) == 10;
            const char *expected[] = {"v", "@", "Q", "f", "f", "f", "f", "f", "f"};
            for (unsigned int i = 0; signature && i < 9; i++) {
                char *type = i == 0 ? method_copyReturnType(method) : method_copyArgumentType(method, i + 1);
                signature = type && strcmp(type, expected[i]) == 0;
                free(type);
            }
            BOOL r = signature && UUHook(renderer, sel, (IMP)hook_render_transform, &sOrigRenderTransform);
            UULog(@"viewport render hook=%d", r);
        }

        Class content = objc_getClass("_TtC14nrd_ios_client17RemoteContentView");
        if (!contentTried && content && UUIsSupportedAppVersion()) {
            contentTried = YES;
            BOOL c = UUHook(content, @selector(layoutSubviews), (IMP)hook_content_layout, &sOrigContentLayout);
            UULog(@"viewport layout hook=%d", c);
        }

        if (renderTried || contentTried) {
            objc_setAssociatedObject(UIApplication.sharedApplication, engineKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

__attribute__((constructor)) static void UUInit(void) {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (![bid isEqualToString:@"com.netease.uuremote"]) return;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            UUInstall();
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            UUInstall();
        }];
    }
}
