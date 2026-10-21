// UUScreenSwitch — UU远程多显示器快捷切换插件
//
// 把远控页底部工具栏的「展开所有窗口」「显示桌面」替换为「显示器1」「显示器2」，
// 点击直接切换被控端显示屏，等价于 操作 → 显示 → 多显示屏管理 里点选对应屏幕。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>
#import <math.h>
#import <dlfcn.h>

#define UULog(fmt, ...) NSLog(@"[UUScreenSwitch] " fmt, ##__VA_ARGS__)

extern void uuss_call_swift_method(void *fn, void *swiftSelf, void *arg0);
extern void uuss_call_swift_geometry(void *fn, void *swiftSelf, double a, double b);
extern void uuss_call_key_sink(void *fn, void *sink, void *array, uint8_t action, void *type, void *wtable);

// ---- 常量 -------------------------------------------------------------------

// RemoteToolBarItemType（Swift 无关联值枚举，按声明顺序编号）
static const uint8_t kItemTypeShowDesktop      = 3;
static const uint8_t kItemTypeExpandAllWindows = 4;

static const char *kClsToolBar   = "_TtC14nrd_ios_client13RemoteToolBar";
static const char *kClsItem      = "_TtC14nrd_ios_clientP33_7245C1225B2709A2490E4B814BBC544E17RemoteToolBarItem";
static const char *kClsViewModel = "_TtC14nrd_ios_client21ControlPanelViewModel";
static const char *kClsSession   = "_TtC14nrd_ios_client23RemoteConnectionSession";
static const char *kClsScreen    = "StreamerScreenSourceModel";
static const char *kClsCombineKey = "_TtC14nrd_ios_client24CombineKeyViewController";
static const char *kClsMouse      = "_TtC14nrd_ios_client9MouseView";
static const char *kClsKeyButton  = "_TtC14nrd_ios_client18FullKeyboardButton";

static char kAssocDisplayIndex;   // NSNumber: 0 / 1 / -1(不处理)
static char kAssocNormalColor;    // UIColor: 按钮原始文字/图标颜色
static char kAssocActiveIndex;    // NSNumber: session 当前选中的屏幕索引兜底
static char kAssocToolBarWatcher; // UUToolBarWatcher: 定时同步多屏菜单切换状态
static char kAssocShortcutIndex;     // NSNumber: 新增组合键行的序号
static char kAssocShortcutTemplate;  // UIView: 对应的原始符号键（只读取平台）
static char kAssocShortcutTarget;    // UUShortcutTarget
static char kAssocShortcutRow;       // UIView: 新增组合键行
static char kAssocOriginalFrames;    // NSMapTable: 本轮布局修改前的原始 frame
static char kAssocViewportMemory;    // UUViewportMemory: 当前会话的各屏幕视角
static char kAssocWheelState;        // UUWheelState: 虚拟鼠标滚轮转盘状态
static char kAssocWheelArtworkMask;  // UUWheelArtworkMask: 可恢复的原始绘制遮罩
static char kAssocWheelDial;         // UUWheelDialView: 双层圆圈底盘

static IMP sOrigLayout   = NULL;
static IMP sOrigDidClick = NULL;
static IMP sOrigCkLayout = NULL;
static IMP sOrigCkDidLayout = NULL;
static IMP sOrigMouseLayout = NULL;
static IMP sOrigMousePress = NULL;
static IMP sOrigMouseRelease = NULL;
static IMP sOrigWheel = NULL;
static IMP sOrigContentLayout = NULL;
static IMP sOrigRenderTransform = NULL;

static void UUSendShortcut(UIViewController *vc, UIView *source, UIView *templateButton, NSInteger index);

static void UUUpdateToolBar(UIView *toolBar);
static intptr_t UUMainImageSlide(void);
static BOOL UUIsSupportedAppVersion(void);
static BOOL UUCodeStartsWith(void *fn, uint32_t insn);
static BOOL UUIsMainImagePointer(void *ptr);

@interface UUToolBarWatcher : NSObject
@property (nonatomic, weak) UIView *toolBar;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation UUToolBarWatcher
- (void)tick:(NSTimer *)timer {
    UIView *tb = self.toolBar;
    if (!tb) {
        [timer invalidate];
        self.timer = nil;
        return;
    }
    if (tb.window && !tb.hidden && tb.alpha > 0.01) {
        UUUpdateToolBar(tb);
    }
}
- (void)dealloc {
    [_timer invalidate];
}
@end

static Class UUItemClass(void) {
    static Class cls = Nil;
    if (cls) return cls;
    cls = objc_getClass(kClsItem);
    if (cls) return cls;
    cls = objc_getClass("_TtC14nrd_ios_client17RemoteToolBarItem");
    if (cls) return cls;
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(list[i]);
        if (!name || strncmp(name, "_TtC14nrd_ios_client", 20) != 0) continue;
        size_t len = strlen(name);
        if (len >= 19 && strcmp(name + len - 19, "17RemoteToolBarItem") == 0) {
            cls = list[i];
            break;
        }
    }
    free(list);
    return cls;
}

// ---- 通用工具 ----------------------------------------------------------------

// 读取 Swift/ObjC 对象类型的 ivar（强引用 / Optional 强引用），不存在返回 nil
static id UUObjectIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    void *raw = *(void **)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv));
    return (__bridge id)raw;
}

static BOOL UURawIvar(id obj, const char *name, void *out, size_t size) {
    if (!obj) return NO;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return NO;
    memcpy(out, (uint8_t *)(__bridge void *)obj + ivar_getOffset(iv), size);
    return YES;
}

static UIWindow *UUKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static void UUToast(NSString *text) {
    UULog(@"toast: %@", text);
    UIWindow *window = UUKeyWindow();
    if (!window) return;
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.layer.cornerRadius = 8;
    label.layer.masksToBounds = YES;
    CGSize s = [label sizeThatFits:CGSizeMake(window.bounds.size.width - 80, CGFLOAT_MAX)];
    label.bounds = CGRectMake(0, 0, s.width + 28, s.height + 16);
    label.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    label.userInteractionEnabled = NO;
    [window addSubview:label];
    [UIView animateWithDuration:0.25 delay:1.4 options:0 animations:^{
        label.alpha = 0;
    } completion:^(BOOL finished) {
        [label removeFromSuperview];
    }];
}

// ---- 找到 App 里的 ControlPanelViewModel ------------------------------------

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
    // 0. RemoteToolBar 自带 contentViewController ivar
    id cvc = UUObjectIvar(from, "contentViewController");
    if ([cvc isKindOfClass:[UIViewController class]]) {
        id vm = UUViewModelFromVC((UIViewController *)cvc, vmCls);
        if (vm) return vm;
    }
    // 1. 工具栏的响应链，正常会走到 ControlPanelViewController
    for (UIResponder *r = from; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            id vm = UUViewModelFromVC((UIViewController *)r, vmCls);
            if (vm) return vm;
        }
    }
    // 2. 兜底：遍历所有窗口的 VC 树
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
        return ((int32_t (*)(id, SEL))objc_msgSend)(screen, sel);
    }
    int32_t sid = -1;
    if (UURawIvar(screen, "_screen_id", &sid, sizeof(sid))) return sid;
    return -1;
}

// 获取当前激活的显示器索引（0 = 显示器1，1 = 显示器2）
static NSInteger UUCurrentDisplayIndex(UIView *toolBar) {
    id vm = UUFindViewModel(toolBar);
    if (!vm) return 0;
    id session = UUObjectIvar(vm, "session");
    Class sessionCls = objc_getClass(kClsSession);
    if (!session || !sessionCls || ![session isKindOfClass:sessionCls]) return 0;

    uintptr_t raw = 0;
    if (!UURawIvar(session, "screenInfos", &raw, sizeof(raw)) || raw == 0 || (raw & 0xC000000000000001ULL)) {
        NSNumber *saved = objc_getAssociatedObject(session, &kAssocActiveIndex);
        return saved ? saved.integerValue : 0;
    }
    NSInteger count = *(NSInteger *)(raw + 0x10);
    if (count <= 0 || count > 16) return 0;

    // 1. 优先读取 session.$__lazy_storage_$_currentScreenInfo（官方多屏菜单与 switchScreen 同步更新该字段）
    id curScreen = UUObjectIvar(session, "$__lazy_storage_$_currentScreenInfo");
    if (curScreen) {
        int32_t curID = UUScreenID(curScreen);
        for (NSInteger i = 0; i < count; i++) {
            id s = (__bridge id)(*(void **)(raw + 0x20 + (uintptr_t)i * sizeof(void *)));
            if (!s) continue;
            if (s == curScreen || (curID >= 0 && UUScreenID(s) == curID)) {
                objc_setAssociatedObject(session, &kAssocActiveIndex, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return i;
            }
        }
    }

    // 2. 次选读取 session.currentScreenID（Swift Int32?：前 4 字节为值，第 5 字节 bit0=0 表示有值）
    uint8_t rawCurID[5] = {0, 0, 0, 0, 1};
    if (UURawIvar(session, "currentScreenID", rawCurID, sizeof(rawCurID)) && (rawCurID[4] & 1) == 0) {
        int32_t sid = -1;
        memcpy(&sid, rawCurID, sizeof(sid));
        if (sid >= 0) {
            for (NSInteger i = 0; i < count; i++) {
                id s = (__bridge id)(*(void **)(raw + 0x20 + (uintptr_t)i * sizeof(void *)));
                if (s && UUScreenID(s) == sid) {
                    objc_setAssociatedObject(session, &kAssocActiveIndex, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    return i;
                }
            }
        }
    }

    // 3. 尚未触发过切屏时（与官方 ToolsScreenDisplayViewViewController 逻辑一致，默认选中第 0 块屏幕）
    NSNumber *saved = objc_getAssociatedObject(session, &kAssocActiveIndex);
    if (saved && saved.integerValue >= 0 && saved.integerValue < count) {
        return saved.integerValue;
    }
    return 0;
}

// ---- 切屏（通过 Swift 虚表动态定位，不限制 App 版本） ----------------------

// 检查函数入口前 24 条指令是否在 x1 上加载了 @selector(screen_id)
// ControlPanelViewModel.switchScreen(_: StreamerScreenSourceModel) 入口立即取参数 x0.screen_id
static BOOL UUFunctionLoadsScreenIDSel(const uint32_t *insns, uintptr_t imageStart, uintptr_t imageEnd) {
    SEL targetSel = sel_registerName("screen_id");
    uintptr_t adrpPages[32] = {0};
    for (int i = 0; i < 24; i++) {
        uint32_t insn = insns[i];
        uintptr_t pc = (uintptr_t)&insns[i];
        if ((insn & 0x9f000000u) == 0x90000000u) {
            uint32_t rd = insn & 0x1fu;
            int64_t immlo = (insn >> 29) & 0x3;
            int64_t immhi = (insn >> 5) & 0x7ffff;
            int64_t imm = (immhi << 2) | immlo;
            if (imm & (1LL << 20)) imm -= (1LL << 21);
            adrpPages[rd] = (pc & ~0xfffULL) + (uintptr_t)(imm << 12);
        } else if ((insn & 0xffc00000u) == 0xf9400000u) {
            uint32_t rt = insn & 0x1fu;
            uint32_t rn = (insn >> 5) & 0x1fu;
            uint32_t imm12 = ((insn >> 10) & 0xfffu) * 8u;
            if (rt == 1 && adrpPages[rn] != 0) {
                uintptr_t selRefAddr = adrpPages[rn] + imm12;
                if (selRefAddr >= imageStart && selRefAddr + sizeof(SEL) <= imageEnd) {
                    SEL loaded = *(SEL *)selRefAddr;
                    if (loaded == targetSel) return YES;
                }
            }
        } else if (insn == 0xd65f03c0u) {
            break;
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

    // 从 ControlPanelViewModel 的 Swift 类元数据虚表中动态扫描 switchScreen(_:)
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

// ---- 切屏时按会话、显示器记住远控视角 --------------------------------------

@interface UUViewportSnapshot : NSObject
@property (nonatomic) double zoom;
@property (nonatomic) CGPoint offset;
@property (nonatomic) CGSize frameSize;
@end
@implementation UUViewportSnapshot
@end

// Swift 的 UIKit 子类 ivar 偏移在加载后可能调整，不能使用磁盘元数据里的绝对偏移。
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
    // 与 App 初次连接的默认选择一致，懒加载 currentScreenInfo 尚未建立时使用第一屏。
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
    // 4.42.x 的原生缩放 setter 和平移 setter，均会同步 delegate 的渲染及鼠标坐标。
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
    // 分辨率改变时保持相对位置，最终边界与缩放限制仍由原生 setter 处理。
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

// StreamerManager 的入口直接更新视频渲染器，不能只靠 UIKit 提交前的补偿。
// 参数签名按 App 4.42.0 元数据核对：@16 Q24 f32 f36 f40 f44 f48 f52。
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
    self.pending = nil;
    self.lastApplied = nil;
    self.source = nil;
    self.lastDesired = nil;
    self.deferredTransform = nil;
    self.lastRenderTransform = nil;
}
- (void)start {
    __weak UUViewportMemory *weakMemory = self;
    // 在主 runloop 休眠/退出前修正几何，早于 Core Animation 的常规画面提交。
    // timer 仅负责超时兜底，不再决定第一帧恢复时机。
    _observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
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
    if (sid >= 0 && (!self.pending || self.lastApplied) && UUReadViewport(self.content, snapshot)) {
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
    if (!session || now - self.started > 3.0 ||
        objc_getAssociatedObject(view, &kAssocViewportMemory) != self) { [self stop]; return; }
    if (!view.window) return; // 回前台时等待画面视图重新挂到窗口。
    int32_t currentID = UUViewportCurrentScreenID(session);
    if (currentID != self.targetID && currentID != self.sourceID) { [self stop]; return; }
    // 目标屏尚未确认时保住源屏视角，避免旧画面先缩回默认位置。
    UUViewportSnapshot *desired = currentID == self.targetID ? self.pending : self.source;
    if (!desired) return;
    BOOL touching = NO, zooming = NO;
    UURawIvar(view, "isTouching", &touching, 1);
    UURawIvar(view, "isZooming", &zooming, 1);
    // 用户开始操作后立即交还控制，不能把新的拖动/缩放拉回旧视角。
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
        // 两个原生 setter 可能各发一次渲染更新，只提交最后一个完整结果。
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
    if (memory.content) objc_setAssociatedObject(memory.content, &kAssocViewportMemory, memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // session.videoRenderView 是 Swift 弱引用，必须通过运行时加载，不能直接解读存储字节。
    Ivar iv = class_getInstanceVariable(object_getClass(memory.session), "videoRenderView");
    void *(*loadWeak)(void *) = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_unknownObjectRelease");
    if (iv && loadWeak && release) {
        void *raw = loadWeak((uint8_t *)(__bridge void *)memory.session + ivar_getOffset(iv));
        if (raw) {
            id render = (__bridge id)raw;
            if ([render isKindOfClass:UIView.class]) {
                memory.renderView = render;
                objc_setAssociatedObject(render, &kAssocViewportMemory, memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            release(raw);
        }
    }
}

static void hook_render_transform(id self, SEL cmd, id view, uint64_t handle,
    float sx, float sy, float tx, float ty, float px, float py) {
    UUViewportMemory *memory = objc_getAssociatedObject(view, &kAssocViewportMemory);
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
            return; // 不把刚被替换的原生默认视角再送进视频队列。
        }
    }
    if (sOrigRenderTransform) ((UURenderTransformFn)sOrigRenderTransform)(self, cmd, view, handle, sx, sy, tx, ty, px, py);
}

// 在原生布局返回的同一调用栈内恢复；递归布局由 applying 标记隔离。
static void hook_content_layout(UIView *self, SEL _cmd) {
    if (sOrigContentLayout) ((void (*)(id, SEL))sOrigContentLayout)(self, _cmd);
    UUViewportMemory *memory = objc_getAssociatedObject(self, &kAssocViewportMemory);
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
    UUViewportMemory *memory = objc_getAssociatedObject(session, &kAssocViewportMemory);
    if (!memory) {
        memory = [UUViewportMemory new];
        memory.session = session;
        objc_setAssociatedObject(session, &kAssocViewportMemory, memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UUViewportSnapshot *outgoing = [UUViewportSnapshot new];
    BOOL valid = UUReadViewport(content, outgoing);
    // 连续快速切换时不能把尚未恢复的中间帧覆盖已保存的视角。
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
    objc_setAssociatedObject(content, &kAssocViewportMemory, memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    Class sessionCls = objc_getClass(kClsSession);
    if (!session || !sessionCls || ![session isKindOfClass:sessionCls]) {
        UUToast(@"远控会话尚未就绪");
        return;
    }

    // screenInfos: Swift [StreamerScreenSourceModel]
    uintptr_t raw = 0;
    if (!UURawIvar(session, "screenInfos", &raw, sizeof(raw)) || raw == 0) {
        UUToast(@"未获取到屏幕列表");
        return;
    }
    if (raw & 0xC000000000000001ULL) {
        UULog(@"screenInfos is not native storage: 0x%lx", (unsigned long)raw);
        UUToast(@"屏幕列表格式异常");
        return;
    }
    NSInteger count = *(NSInteger *)(raw + 0x10);
    if (count < 0 || count > 16) { UUToast(@"屏幕列表格式异常"); return; }
    if (index >= count) {
        UUToast(count <= 1 ? @"被控端只有 1 块显示屏"
                           : [NSString stringWithFormat:@"未检测到显示器%ld", (long)index + 1]);
        return;
    }

    id screen = (__bridge id)(*(void **)(raw + 0x20 + (uintptr_t)index * sizeof(void *)));
    Class screenCls = objc_getClass(kClsScreen);
    if (!screen || !screenCls || ![screen isKindOfClass:screenCls]) {
        UUToast(@"屏幕对象类型不匹配");
        return;
    }

    UULog(@"switch -> display %ld / %ld (vm=%p screen=%p)", (long)index + 1, (long)count,
          (__bridge void *)vm, (__bridge void *)screen);
    if (UUScreenID(screen) >= 0 && UUViewportCurrentScreenID(session) == UUScreenID(screen)) {
        UUUpdateToolBar(toolBar);
        return;
    }
    UUViewportMemory *viewport = UUPrepareViewportSwitch(vm, session, screen);
    objc_setAssociatedObject(session, &kAssocActiveIndex, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (viewport.pending) [viewport start];
    // vm / screen 在本作用域内被强引用持有，满足 Swift guaranteed 参数约定
    uuss_call_swift_method(fn, (__bridge void *)vm, (__bridge void *)screen);
    [viewport tick:nil]; // 切屏同步回调产生的重置在当前帧提交前恢复。
    UUUpdateToolBar(toolBar);

    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

// ---- 工具栏按钮改造 -----------------------------------------------------------

static UIColor *UUActiveBlueColor(void) {
    return [UIColor colorWithRed:58.0 / 255.0 green:123.0 / 255.0 blue:251.0 / 255.0 alpha:1.0];
}

static UILabel *UUFirstLabel(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return (UILabel *)v;
    for (UIView *s in v.subviews) { UILabel *l = UUFirstLabel(s); if (l) return l; }
    return nil;
}

static UIImageView *UUFirstImageView(UIView *v) {
    if ([v isKindOfClass:[UIImageView class]]) return (UIImageView *)v;
    for (UIView *s in v.subviews) { UIImageView *i = UUFirstImageView(s); if (i) return i; }
    return nil;
}

static UILabel *UUItemLabel(UIView *item) {
    id l = UUObjectIvar(item, "$__lazy_storage_$_captionLabel");
    return [l isKindOfClass:[UILabel class]] ? l : UUFirstLabel(item);
}

static UIImageView *UUItemIcon(UIView *item) {
    id i = UUObjectIvar(item, "$__lazy_storage_$_icon");
    return [i isKindOfClass:[UIImageView class]] ? i : UUFirstImageView(item);
}

static BOOL UUTextMatchesKeys(NSString *text, NSArray<NSString *> *keys) {
    if (!text.length) return NO;
    for (NSString *k in keys) {
        NSString *v = [NSBundle.mainBundle localizedStringForKey:k value:nil table:nil];
        if (v.length && ![v isEqualToString:k] && [text isEqualToString:v]) return YES;
    }
    return NO;
}

// 根据原始文案（优先）和 type 判断这个按钮要变成哪块屏
static NSInteger UUClassifyItem(UIView *item) {
    NSString *text = UUItemLabel(item).text;
    if (UUTextMatchesKeys(text, @[ @"hover.function.expandAllWindows" ])) return 0;
    if (UUTextMatchesKeys(text, @[ @"Control.Panel.backToDesktop", @"hover.function.showDesktop",
                                   @"Keyboard.Shortcut.desktop" ])) return 1;
    uint8_t type = 0xff;
    if (UURawIvar(item, "type", &type, 1)) {
        if (type == kItemTypeExpandAllWindows) return 0;
        if (type == kItemTypeShowDesktop) return 1;
    }
    return -1;
}

// 显示器图标 + 序号
static UIImage *UUDisplayIcon(NSInteger index, CGSize size, UIColor *color) {
    if (size.width < 8 || size.height < 8) size = CGSizeMake(24, 24);
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:size.height * 0.82 weight:UIImageSymbolWeightRegular];
    UIImage *sym = [[UIImage systemImageNamed:@"display" withConfiguration:cfg]
                    imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGSize ss = sym.size;
        CGFloat scale = MIN(size.width / ss.width, size.height / ss.height);
        CGSize ds = CGSizeMake(ss.width * scale, ss.height * scale);
        CGRect rect = CGRectMake((size.width - ds.width) / 2, (size.height - ds.height) / 2, ds.width, ds.height);
        [sym drawInRect:rect];
        NSString *num = [NSString stringWithFormat:@"%ld", (long)index + 1];
        NSDictionary *attr = @{
            NSFontAttributeName : [UIFont systemFontOfSize:ds.height * 0.46 weight:UIFontWeightBold],
            NSForegroundColorAttributeName : color,
        };
        CGSize ns = [num sizeWithAttributes:attr];
        // 屏幕区域约占符号上部 72%
        CGFloat screenMidY = rect.origin.y + ds.height * 0.36;
        [num drawAtPoint:CGPointMake(CGRectGetMidX(rect) - ns.width / 2, screenMidY - ns.height / 2)
          withAttributes:attr];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static void UUStyleItem(UIView *item, NSInteger index, BOOL active) {
    NSString *title = [NSString stringWithFormat:@"显示器%ld", (long)index + 1];
    UILabel *label = UUItemLabel(item);
    UIColor *normalColor = objc_getAssociatedObject(item, &kAssocNormalColor);
    if (!normalColor) {
        normalColor = (label && label.textColor) ? label.textColor : UIColor.whiteColor;
        objc_setAssociatedObject(item, &kAssocNormalColor, normalColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIColor *targetColor = active ? UUActiveBlueColor() : normalColor;

    if (label) {
        if (![label.text isEqualToString:title]) label.text = title;
        if (![label.textColor isEqual:targetColor]) label.textColor = targetColor;
    }

    UIImageView *icon = UUItemIcon(item);
    if (icon) {
        NSString *stateTag = [NSString stringWithFormat:@"UUScreenSwitch_%ld_%d", (long)index, active ? 1 : 0];
        if (![icon.image.accessibilityIdentifier isEqualToString:stateTag]) {
            CGSize size = icon.image ? icon.image.size : icon.bounds.size;
            UIImage *img = UUDisplayIcon(index, size, targetColor);
            img.accessibilityIdentifier = stateTag;
            icon.image = img;
            icon.tintColor = targetColor;
        }
    }
    item.accessibilityLabel = title;
}

static void UUCollectItems(UIView *v, Class itemCls, NSMutableArray *out, int depth) {
    if (depth > 6) return;
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:itemCls]) [out addObject:s];
        else UUCollectItems(s, itemCls, out, depth + 1);
    }
}

static void UUEnsureWatcher(UIView *toolBar) {
    UUToolBarWatcher *watcher = objc_getAssociatedObject(toolBar, &kAssocToolBarWatcher);
    if (!watcher) {
        watcher = [UUToolBarWatcher new];
        watcher.toolBar = toolBar;
        watcher.timer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                         target:watcher
                                                       selector:@selector(tick:)
                                                       userInfo:nil
                                                        repeats:YES];
        objc_setAssociatedObject(toolBar, &kAssocToolBarWatcher, watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void UUUpdateToolBar(UIView *toolBar) {
    Class itemCls = UUItemClass();
    if (!itemCls) return;
    UUEnsureWatcher(toolBar);
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    UUCollectItems(toolBar, itemCls, items, 0);

    NSInteger activeIndex = UUCurrentDisplayIndex(toolBar);
    BOOL used[2] = {NO, NO};
    for (UIView *item in items) {
        NSNumber *idx = objc_getAssociatedObject(item, &kAssocDisplayIndex);
        if (!idx) {
            NSInteger c = UUClassifyItem(item);
            if (c >= 0 && used[c]) c = -1;   // 每块屏只放一个按钮
            idx = @(c);
            objc_setAssociatedObject(item, &kAssocDisplayIndex, idx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            uint8_t type = 0xff;
            UURawIvar(item, "type", &type, 1);
            UULog(@"item type=%u text=%@ -> %ld", type, UUItemLabel(item).text, (long)c);
        }
        NSInteger i = idx.integerValue;
        if (i == 0 || i == 1) {
            used[i] = YES;
            UUStyleItem(item, i, (i == activeIndex));
        }
    }
}

// ---- 电脑键盘：保留原键位，新增六个常用组合键 ----------------------------

typedef struct {
    uint8_t macModifierHID;
    uint8_t winModifierHID;
    uint8_t keyHID;
    const char *macTitle;
    const char *winTitle;
} UUShortcut;

// 与 App 原生 KeyboardEventSink 一致，直接发送 HID usage 数组。
static const UUShortcut kShortcuts[6] = {
    { 0xe1, 0xe1, 0x28, "Shift+Enter", "Shift+Enter" },
    { 0xe3, 0xe0, 0x04, "⌘A", "Ctrl+A" },
    { 0xe3, 0xe0, 0x1d, "⌘Z", "Ctrl+Z" },
    { 0xe3, 0xe0, 0x1b, "⌘X", "Ctrl+X" },
    { 0xe3, 0xe0, 0x06, "⌘C", "Ctrl+C" },
    { 0xe3, 0xe0, 0x19, "⌘V", "Ctrl+V" },
};

static Class UUKeyboardButtonClass(void) {
    static Class cls = Nil;
    if (!cls) cls = objc_getClass(kClsKeyButton);
    return cls;
}

// 直接读 Swift [FullKeyboardButton]，避免把第二页的同 keyType 按钮也扫进来。
static NSArray<UIView *> *UUFirstPageButtons(id owner) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    uintptr_t raw = 0;
    if (!UURawIvar(owner, "firstPageButtons", &raw, sizeof(raw))) return out;
    if (!raw || (raw & 0xC000000000000001ULL)) return out;
    NSInteger count = *(NSInteger *)(raw + 0x10);
    if (count <= 0 || count > 200) return out;

    Class btnCls = UUKeyboardButtonClass();
    for (NSInteger i = 0; i < count; i++) {
        id button = (__bridge id)(*(void **)(raw + 0x20 + (uintptr_t)i * sizeof(void *)));
        if (!button || !btnCls || ![button isKindOfClass:btnCls]) continue;
        [out addObject:button];
    }
    return out;
}

@interface UUShortcutTarget : NSObject
@property (nonatomic, weak) UIViewController *controller;
- (void)shortcutTapped:(UIButton *)sender;
@end

// 两枚系统符号使用相同绘制尺寸，中间固定留 8pt，避免文本字形大小/字距不一致。
static UIImage *UUShiftEnterImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
        UIImage *shift = [UIImage systemImageNamed:@"shift" withConfiguration:config];
        UIImage *enter = [UIImage systemImageNamed:@"return" withConfiguration:config];
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(38, 16)];
        image = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [shift drawInRect:CGRectMake(0, 1, 15, 14)];
            [enter drawInRect:CGRectMake(23, 1, 15, 14)];
        }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return image;
}

// 新建普通 UIButton，复制原始符号键的背景/字体/文字色，保持键盘观感。
static UIButton *UUMakeShortcutButton(UIView *template, NSInteger index) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    UIFont *font = nil;
    UIColor *textColor = nil;
    if ([template isKindOfClass:[UIButton class]]) {
        UIButton *t = (UIButton *)template;
        UIImage *bg = [t backgroundImageForState:UIControlStateNormal];
        UIImage *bgHi = [t backgroundImageForState:UIControlStateHighlighted];
        if (bg) {
            [btn setBackgroundImage:bg forState:UIControlStateNormal];
            if (bgHi) [btn setBackgroundImage:bgHi forState:UIControlStateHighlighted];
        }
        font = t.titleLabel.font;
        textColor = [t titleColorForState:UIControlStateNormal];
        if (!textColor) textColor = t.titleLabel.textColor;
        if (!font) {
            UILabel *label = UUFirstLabel(t);
            if (label) font = label.font;
        }
        if (!textColor) {
            UILabel *label = UUFirstLabel(t);
            if (label) textColor = label.textColor;
        }
        btn.backgroundColor = t.backgroundColor;
        btn.layer.cornerRadius = t.layer.cornerRadius;
        btn.layer.borderWidth = t.layer.borderWidth;
        btn.layer.borderColor = t.layer.borderColor;
        btn.contentEdgeInsets = t.contentEdgeInsets;
    }
    if (!btn.currentBackgroundImage) {
        BOOL lightText = YES;
        if (textColor) {
            CGFloat r = 0, g = 0, b = 0, a = 0;
            if ([textColor getRed:&r green:&g blue:&b alpha:&a]) {
                lightText = (0.299 * r + 0.587 * g + 0.114 * b) > 0.5;
            }
        } else {
            textColor = UIColor.whiteColor;
        }
        btn.backgroundColor = lightText ? [UIColor colorWithWhite:1.0 alpha:0.16]
                                       : [UIColor colorWithWhite:0.0 alpha:0.06];
        btn.layer.cornerRadius = 6.0;
        btn.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        btn.layer.borderColor = (lightText ? [UIColor colorWithWhite:1.0 alpha:0.12]
                                           : [UIColor colorWithWhite:0.0 alpha:0.10]).CGColor;
        btn.layer.masksToBounds = YES;
    }
    // 原生键可能通过背景图片绘制；所有状态均需在按钮边界裁成圆角。
    btn.layer.cornerRadius = 6.0;
    btn.layer.cornerCurve = kCACornerCurveContinuous;
    btn.clipsToBounds = YES;
    if (!textColor) textColor = UIColor.whiteColor;
    [btn setTitleColor:textColor forState:UIControlStateNormal];
    btn.titleLabel.font = font ?: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    btn.titleLabel.numberOfLines = 1;
    btn.titleLabel.textAlignment = NSTextAlignmentCenter;
    btn.titleLabel.adjustsFontSizeToFitWidth = YES;
    btn.titleLabel.minimumScaleFactor = 0.42;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    btn.titleEdgeInsets = UIEdgeInsetsZero;
    if (index == 0) {
        [btn setImage:UUShiftEnterImage() forState:UIControlStateNormal];
        btn.tintColor = textColor;
        btn.contentEdgeInsets = UIEdgeInsetsMake(2, 2, 2, 2);
        btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    }
    btn.tag = index;
    return btn;
}

// 在系统重新布局前恢复上次的几何信息，避免旋转/反复打开时累计压缩。
static void UURestoreKeyboardFrames(UIViewController *vc) {
    NSMapTable<UIView *, NSValue *> *frames = objc_getAssociatedObject(vc, &kAssocOriginalFrames);
    for (UIView *view in frames) {
        BOOL autoresizes = view.autoresizesSubviews;
        view.autoresizesSubviews = NO;
        view.frame = [frames objectForKey:view].CGRectValue;
        view.autoresizesSubviews = autoresizes;
    }
    objc_setAssociatedObject(vc, &kAssocOriginalFrames, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void UUApplyKeyboardShortcuts(UIViewController *vc) {
    NSArray<UIView *> *buttons = UUFirstPageButtons(vc);
    if (!buttons.count) return;
    UIView *first = nil;
    for (UIView *button in buttons) {
        uint8_t keyType = 0xff;
        if (UURawIvar(button, "keyType", &keyType, 1) && keyType == 0x48) first = button;
    }
    if (!first.superview) return;

    // 共同父视图必须包含所有按键；不改变分页 scrollView 的高度、contentSize 或 offset。
    UIView *content = first.superview;
    for (UIView *button in buttons) {
        while (content && ![button isDescendantOfView:content]) content = content.superview;
    }
    if (!content) return;
    NSMutableArray<UIButton *> *shortcuts = objc_getAssociatedObject(vc, &kAssocShortcutRow);
    if (!shortcuts) {
        shortcuts = [NSMutableArray array];
        UUShortcutTarget *target = [UUShortcutTarget new];
        target.controller = vc;
        objc_setAssociatedObject(vc, &kAssocShortcutTarget, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSInteger i = 0; i < 6; i++) {
            UIButton *button = UUMakeShortcutButton(first, i);
            [button addTarget:target action:@selector(shortcutTapped:) forControlEvents:UIControlEventTouchUpInside];
            [shortcuts addObject:button];
        }
        objc_setAssociatedObject(vc, &kAssocShortcutRow, shortcuts, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIButton *button in shortcuts) {
        if (button.superview != content) [content addSubview:button];
    }

    // 只在首个布局周期取原始尺寸；viewWillLayoutSubviews 会先恢复它们。
    NSMapTable<UIView *, NSValue *> *frames = objc_getAssociatedObject(vc, &kAssocOriginalFrames);
    if (frames) return;
    frames = [NSMapTable weakToStrongObjectsMapTable];
    CGFloat top = CGFLOAT_MAX, bottom = -CGFLOAT_MAX;
    CGFloat left = CGFLOAT_MAX, right = -CGFLOAT_MAX;
    CGRect symbolFrame = [first.superview convertRect:first.frame toView:content];
    for (UIView *button in buttons) {
        CGRect f = [button.superview convertRect:button.frame toView:content];
        if (CGRectIsEmpty(f)) continue;
        left = MIN(left, CGRectGetMinX(f));
        right = MAX(right, CGRectGetMaxX(f));
        top = MIN(top, CGRectGetMinY(f));
        bottom = MAX(bottom, CGRectGetMaxY(f));
    }
    if (top == CGFLOAT_MAX || bottom <= top || right <= left || CGRectIsEmpty(symbolFrame)) return;
    // 新增行与原按键一起按比例分配现有高度，最后一行仍停在原来的底边。
    CGFloat gap = MAX(2.0, symbolFrame.size.height * 0.08);
    CGFloat scale = (bottom - top) / (bottom - top + symbolFrame.size.height + gap);
    CGFloat rowHeight = symbolFrame.size.height * scale;
    CGFloat shift = (symbolFrame.size.height + gap) * scale;
    // 同步移动路径上的行容器，避免按键虽看得见却落在父视图命中区域以外。
    NSMutableOrderedSet<UIView *> *views = [NSMutableOrderedSet orderedSet];
    for (UIView *button in buttons) {
        NSMutableArray<UIView *> *path = [NSMutableArray array];
        for (UIView *v = button; v && v != content; v = v.superview) [path addObject:v];
        for (UIView *v in path.reverseObjectEnumerator) [views addObject:v];
    }
    NSMapTable<UIView *, NSValue *> *destinations = [NSMapTable weakToStrongObjectsMapTable];
    for (UIView *v in views) {
        [frames setObject:[NSValue valueWithCGRect:v.frame] forKey:v];
        CGRect f = [v.superview convertRect:v.frame toView:content];
        f.origin.y = top + shift + (f.origin.y - top) * scale;
        f.size.height *= scale;
        [destinations setObject:[NSValue valueWithCGRect:f] forKey:v];
    }
    // 父容器优先，其后再把子视图转回新的父坐标系。
    for (UIView *v in views) {
        BOOL autoresizes = v.autoresizesSubviews;
        v.autoresizesSubviews = NO;
        v.frame = [content convertRect:[destinations objectForKey:v].CGRectValue toView:v.superview];
        v.autoresizesSubviews = autoresizes;
    }
    objc_setAssociatedObject(vc, &kAssocOriginalFrames, frames, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat width = (right - left - 5 * gap) / 6;
    uint8_t platform = 1;
    UURawIvar(first, "keyboardPlatform", &platform, 1);
    for (NSInteger i = 0; i < 6; i++) {
        UIButton *button = shortcuts[i];
        button.frame = CGRectMake(left + i * (width + gap), top, width, rowHeight);
        NSString *title = [NSString stringWithUTF8String:platform == 0 ? kShortcuts[i].winTitle : kShortcuts[i].macTitle];
        [button setTitle:i == 0 ? nil : title forState:UIControlStateNormal];
        button.accessibilityLabel = title;
        objc_setAssociatedObject(button, &kAssocShortcutIndex, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, &kAssocShortcutTemplate, first, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL UUIsMainImagePointer(void *ptr) {
    if (!ptr) return NO;
    Dl_info info;
    if (!dladdr(ptr, &info) || !info.dli_fname) return NO;
    size_t len = strlen(info.dli_fname);
    return len >= 15 && strcmp(info.dli_fname + len - 15, "/nrd-ios-client") == 0;
}

// swift_bridgeObjectRelease 只解析一次，滚轮每格都会用到。
static void UUSwiftRelease(void *object) {
    if (!object) return;
    static void (*release)(void *);
    static BOOL resolved;
    if (!resolved) {
        resolved = YES;
        release = (void (*)(void *))dlsym(RTLD_DEFAULT, "swift_bridgeObjectRelease");
    }
    if (release) release(object);
}

static BOOL UUSendKeyArray(UIViewController *vc, const uint8_t *codes, size_t count) {
    if (!vc || !codes || count == 0 || count > 8) return NO;
    if (!UUIsSupportedAppVersion()) return NO;

    // CombineKeyViewController.keyboardEventSink 是 16 字节的协议存在量：
    // +0x60 实例指针，+0x68 协议见证表。
    void *existential[2] = {0};
    if (!UURawIvar(vc, "keyboardEventSink", existential, sizeof(existential))) return NO;
    void *sink = existential[0];
    void *wtable = existential[1];
    if (!sink || !wtable) return NO;

    // KeyboardEventSink 只有一个要求，见证表 +8 就是发送方法。
    void *fn = *(void **)((uint8_t *)wtable + 8);
    if (!fn || !UUIsMainImagePointer(fn)) return NO;

    intptr_t slide = UUMainImageSlide();
    if (!slide) return NO;

    // 4.42.x：0x10056d9e4 是 Array 的扩容/复制函数，x3 传空数组存储。
    void *empty = dlsym(RTLD_DEFAULT, "__swiftEmptyArrayStorage");
    if (!empty) empty = *(void **)(slide + 0x1026dc218);
    if (!empty) return NO;
    if (*(uint64_t *)((uint8_t *)empty + 0x10) != 0) return NO; // 必须是空数组

    typedef void *(*EnsureFn)(uint64_t, uint64_t, uint64_t, void *);
    EnsureFn ensure = (EnsureFn)(slide + 0x10056d9e4);
    if (!UUIsMainImagePointer((void *)ensure)) return NO;
    if (!UUCodeStartsWith((void *)ensure, 0xa9bd57f6u)) {
        static BOOL warned = NO;
        if (!warned) {
            warned = YES;
            UULog(@"array allocator address moved, shortcut disabled");
        }
        return NO;
    }

    void *storage = ensure(0, count, 1, empty);
    if (!storage) return NO;

    *(uint64_t *)((uint8_t *)storage + 0x10) = count;
    for (size_t i = 0; i < count; i++) {
        *(uint64_t *)((uint8_t *)storage + 0x20 + i * sizeof(uint64_t)) = codes[i];
    }

    // 与原生发送路径相同，用 swift_getObjectType 取得协议实例的动态类型。
    void *(*getType)(void *) = dlsym(RTLD_DEFAULT, "swift_getObjectType");
    if (!getType) { UUSwiftRelease(storage); return NO; }
    void *type = getType(sink);
    uuss_call_key_sink(fn, sink, storage, 2, type, wtable);

    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        UULog(@"key array send: sink=%p wtable=%p fn=%p count=%zu", sink, wtable, fn, count);
    }

    UUSwiftRelease(storage);
    return YES;
}

static void UUSendShortcut(UIViewController *vc, UIView *source, UIView *templateButton, NSInteger index) {
    if (index < 0 || index >= 6 || !vc) return;
    UIView *button = templateButton ?: source;
    if (!button) return;
    const UUShortcut *sc = &kShortcuts[index];

    uint8_t platform = 1; // 0 = Windows，1 = Mac
    UURawIvar(button, "keyboardPlatform", &platform, 1);

    // 首选：一次发送 [修饰键, 主键] 数组，和 App 原生组合键工具栏一致。
    uint8_t codes[2] = {
        (platform == 0) ? sc->winModifierHID : sc->macModifierHID,
        sc->keyHID
    };
    if (UUSendKeyArray(vc, codes, 2)) return;

    // 不修改原按键 keyType，也不调用会启动连发计时器的 touchDown 方法。
    // 不支持的 App 版本明确失败，避免修饰键停留在按下状态。
    UULog(@"shortcut unavailable for this app version");
}

@implementation UUShortcutTarget
- (void)shortcutTapped:(UIButton *)sender {
    NSNumber *idx = objc_getAssociatedObject(sender, &kAssocShortcutIndex);
    UIView *tpl = objc_getAssociatedObject(sender, &kAssocShortcutTemplate);
    if (!idx || !self.controller) return;
    @try {
        UUSendShortcut(self.controller, sender, tpl, idx.integerValue);
    } @catch (NSException *e) {
        UULog(@"shortcut exception: %@", e);
    }
}
@end

static void hook_ck_layout(UIViewController *self, SEL _cmd) {
    UURestoreKeyboardFrames(self);
    if (sOrigCkLayout) ((void (*)(id, SEL))sOrigCkLayout)(self, _cmd);
}

static void hook_ck_didLayout(UIViewController *self, SEL _cmd) {
    if (sOrigCkDidLayout) ((void (*)(id, SEL))sOrigCkDidLayout)(self, _cmd);
    @try {
        UUApplyKeyboardShortcuts(self);
    } @catch (NSException *e) {
        UULog(@"keyboard layout exception: %@", e);
    }
}

// ---- 1.1.0：虚拟鼠标滚轮改为圆形转盘 --------------------------------

static const double kWheelRadius = 46.0;
static const double kWheelDeadZone = 11.0;
static const double kWheelStep = 14.0 * M_PI / 180.0;

@interface UUWheelState : NSObject
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@property (nonatomic) BOOL active;
@property (nonatomic) double lastAngle;
@property (nonatomic) double accumulated;
@property (nonatomic) double lastTime;
@property (nonatomic) NSInteger lastDirection;
@end

@implementation UUWheelState
@end

// 半透明环带与内外描边；中间镂空，静止时显示独立中心圆。
@interface UUWheelDialView : UIView
@property (nonatomic) CGFloat radius;
@property (nonatomic) BOOL rotating;
@property (nonatomic) CGFloat indicatorAngle;
@property (nonatomic) CGSize hostSize;
@end

@implementation UUWheelDialView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.layer.shadowColor = [UIColor colorWithWhite:0.05 alpha:1.0].CGColor;
        self.layer.shadowOpacity = 0;
        self.layer.shadowRadius = 10.0;
        self.layer.shadowOffset = CGSizeMake(0, 3);
    }
    return self;
}
- (void)setRadius:(CGFloat)radius {
    _radius = radius;
    [self setNeedsDisplay];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = self.radius;
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    self.layer.shadowPath = [UIBezierPath bezierPathWithArcCenter:c radius:r
                                                       startAngle:0 endAngle:M_PI * 2 clockwise:YES].CGPath;
}
- (void)setRotating:(BOOL)rotating {
    _rotating = rotating;
    [self setNeedsDisplay];
}
- (void)setIndicatorAngle:(CGFloat)indicatorAngle {
    _indicatorAngle = indicatorAngle;
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat outerRadius = self.radius + 12.0;
    CGFloat innerRadius = self.radius - 12.0;
    if (innerRadius <= 0) return;
    UIBezierPath *outer = [UIBezierPath bezierPathWithArcCenter:c radius:outerRadius
        startAngle:0 endAngle:2 * M_PI clockwise:YES];
    UIBezierPath *inner = [UIBezierPath bezierPathWithArcCenter:c radius:innerRadius
        startAngle:0 endAngle:2 * M_PI clockwise:YES];
    UIBezierPath *ring = [outer copy];
    [ring appendPath:inner];
    ring.usesEvenOddFillRule = YES;
    [[UIColor colorWithRed:0.65 green:0.73 blue:0.75 alpha:0.42] setFill];
    [ring fill];
    [[UIColor colorWithRed:0.38 green:0.45 blue:0.46 alpha:0.62] setStroke];
    outer.lineWidth = inner.lineWidth = 1.5;
    [outer stroke];
    [inner stroke];
    if (!self.rotating) {
        UIBezierPath *center = [UIBezierPath bezierPathWithArcCenter:c radius:24
            startAngle:0 endAngle:2 * M_PI clockwise:YES];
        [[UIColor colorWithRed:0.76 green:0.82 blue:0.83 alpha:0.65] setFill];
        [center fill];
        [[UIColor colorWithRed:0.38 green:0.45 blue:0.46 alpha:0.62] setStroke];
        center.lineWidth = 1.5;
        [center stroke];
    } else {
        CGPoint indicator = CGPointMake(c.x + self.radius * cos(self.indicatorAngle),
                                        c.y + self.radius * sin(self.indicatorAngle));
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 4, [UIColor colorWithRed:1 green:0.74 blue:0.25 alpha:0.8].CGColor);
        [[UIColor colorWithRed:1 green:0.75 blue:0.28 alpha:0.95] setFill];
        [[UIBezierPath bezierPathWithArcCenter:indicator radius:8 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
        CGContextRestoreGState(ctx);
    }
}

@end

static intptr_t UUMainImageSlide(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0;
        if (len >= 15 && strcmp(name + len - 15, "/nrd-ios-client") == 0) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

// App 内部 build(horizontal, vertical, _, axis) 的第一个参数是横向增量，第二个才是纵向。
// 4.42.x 固定地址，入口指令做指纹校验，App 更新后地址漂移时直接放弃，避免误调用。
static BOOL UUCodeStartsWith(void *fn, uint32_t insn) {
    return fn && *(const uint32_t *)fn == insn;
}

// 调用 App 自己的滚轮数据包构造与发送函数（4.42.x 固定地址，安装前会做版本检查）。
static void UUWheelSend(NSInteger dy) {
    intptr_t slide = UUMainImageSlide();
    if (!slide) return;

    typedef struct { uint64_t a, b; } UUSwiftString;
    UUSwiftString (*build)(int64_t, int64_t, int64_t, uint8_t) =
        (UUSwiftString (*)(int64_t, int64_t, int64_t, uint8_t))(slide + 0x100277280);
    void (*send)(void *, void *, uint64_t, uint64_t) =
        (void (*)(void *, void *, uint64_t, uint64_t))(slide + 0x1007c68d0);

    if (!UUIsMainImagePointer((void *)build) || !UUIsMainImagePointer((void *)send)) return;
    if (!UUCodeStartsWith((void *)build, 0xa9bc5ff8u) ||
        !UUCodeStartsWith((void *)send, 0xd10203ffu)) {
        static BOOL warned = NO;
        if (!warned) {
            warned = YES;
            UULog(@"wheel send address moved, dial disabled");
        }
        return;
    }

    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        UULog(@"wheel send resolved: build=%p send=%p", (void *)build, (void *)send);
    }

    // 纵向滚动：x0 = 0，x1 = dy。
    UUSwiftString packet = build(0, dy, 0, 7);
    // send 从 x1 + 0x10 读重复次数；必须是 1，否则一个包都不会发。
    uint64_t context[4] = { 0, 0, 1, 0 };
    send(context, context, packet.a, packet.b);

    // countAndFlags 最高位为 1 表示小字符串（字节内联，不是堆对象），不能按对象释放。
    if (!(packet.b & 0x8000000000000000ULL)) UUSwiftRelease((void *)packet.a);
}

// 遮罩只影响绘制，不改变 UIView.alpha/hidden，也不影响手势命中。
// 退出旋转滚动模式时完整恢复原始遮罩，普通左右键模式沿用 App 原样。
@interface UUWheelArtworkMask : NSObject
@property (nonatomic, strong) CALayer *original;
@property (nonatomic, strong) CALayer *empty;
@end
@implementation UUWheelArtworkMask
@end

static void UUSetWheelArtworkHidden(UIView *view, BOOL hidden) {
    if (!view) return;
    UUWheelArtworkMask *state = objc_getAssociatedObject(view, &kAssocWheelArtworkMask);
    if (hidden) {
        if (!state) {
            state = [UUWheelArtworkMask new];
            state.original = view.layer.mask;
            state.empty = [CALayer layer]; // 无内容的透明遮罩
            objc_setAssociatedObject(view, &kAssocWheelArtworkMask, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.layer.mask = state.empty;
    } else if (state) {
        if (view.layer.mask == state.empty) view.layer.mask = state.original;
        objc_setAssociatedObject(view, &kAssocWheelArtworkMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UUWheelDialView *UUEnsureDialForView(UIView *view) {
    UIView *mode = UUObjectIvar(view, "$__lazy_storage_$_mouseScrollModeView");
    UIView *button = UUObjectIvar(view, "$__lazy_storage_$_mouseScrollButton");
    UUWheelDialView *dial = objc_getAssociatedObject(view, &kAssocWheelDial);
    BOOL enabled = NO, folded = NO;
    UURawIvar(view, "enableScrollScreen", &enabled, 1);
    UURawIvar(view, "isFold", &folded, 1);
    if (!enabled || folded || mode.hidden || !mode.superview || !button.superview) {
        UUSetWheelArtworkHidden(button, NO);
        UUSetWheelArtworkHidden(mode, NO);
        dial.hidden = YES;
        return dial;
    }

    CGFloat side = 2.0 * (kWheelRadius + 16.0);
    if (!dial) {
        dial = [[UUWheelDialView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
        dial.radius = kWheelRadius;
        objc_setAssociatedObject(view, &kAssocWheelDial, dial, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // 同一轮显示期间锁定圆心；原生 layout 会把 mode.center 跟随按钮重新定位。
    // 仅在重新进入滚动模式或屏幕尺寸变化时更新位置。
    BOOL place = dial.superview != view || dial.hidden || !CGSizeEqualToSize(dial.hostSize, view.bounds.size);
    [UIView performWithoutAnimation:^{
        dial.bounds = CGRectMake(0, 0, side, side);
        if (place) dial.center = [mode.superview convertPoint:mode.center toView:view];
    }];
    dial.hostSize = view.bounds.size;
    if (dial.superview != view) [view addSubview:dial];
    [view bringSubviewToFront:dial];
    UIView *close = UUObjectIvar(view, "$__lazy_storage_$_closeButton");
    if (close.superview == view) [view bringSubviewToFront:close];
    UUWheelState *state = objc_getAssociatedObject(view, &kAssocWheelState);
    dial.rotating = state.active;
    dial.indicatorAngle = state.lastAngle;
    dial.hidden = NO;
    dial.alpha = 1.0; // 透明效果由 drawRect 的颜色控制，绝不从被遮罩的原按钮读取。
    UUSetWheelArtworkHidden(mode, YES);
    UUSetWheelArtworkHidden(button, YES);
    return dial;
}

static void UUWheelHandle(UIView *view, SEL cmd, UIGestureRecognizer *gesture, IMP original) {
    BOOL enabled = NO;
    if (!UURawIvar(view, "enableScrollScreen", &enabled, 1) || !enabled) {
        if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
        return;
    }

    UIView *mode = UUObjectIvar(view, "$__lazy_storage_$_mouseScrollModeView");
    UIView *button = UUObjectIvar(view, "$__lazy_storage_$_mouseScrollButton");
    if (!mode || !mode.superview || !button || !button.superview) {
        if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
        return;
    }

    UUWheelState *state = objc_getAssociatedObject(view, &kAssocWheelState);
    if (!state) {
        state = [UUWheelState new];
        state.feedback = [UISelectionFeedbackGenerator new];
        objc_setAssociatedObject(view, &kAssocWheelState, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 输入计算与绘制共用固定圆心，不再借原生按钮的位置驱动黄色指示点。
    UUWheelDialView *dial = UUEnsureDialForView(view);
    CGPoint center = dial && !dial.hidden
        ? [view convertPoint:dial.center toView:button.superview]
        : [mode.superview convertPoint:mode.center toView:button.superview];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        id timer = UUObjectIvar(view, "sendScrollEventTimer");
        if ([timer respondsToSelector:@selector(invalidate)]) [timer invalidate];

        state.active = YES;
        state.accumulated = 0;
        state.lastDirection = 0;
        state.lastTime = CACurrentMediaTime();

        CGPoint p = [gesture locationInView:button.superview];
        state.lastAngle = atan2(p.y - center.y, p.x - center.x);

        UUEnsureDialForView(view);
        [state.feedback prepare];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (!state.active) {
            if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
            return;
        }

        CGPoint p = [gesture locationInView:button.superview];
        double dx = p.x - center.x;
        double dy = p.y - center.y;
        double radius = hypot(dx, dy);
        if (radius < kWheelDeadZone) {
            // 圆心死区：只刷新角度基准，避免离开死区时一次补上一个大角度。
            state.lastAngle = atan2(dy, dx);
            return;
        }

        double angle = atan2(dy, dx);
        double delta = atan2(sin(angle - state.lastAngle), cos(angle - state.lastAngle));
        state.lastAngle = angle;

        double now = CACurrentMediaTime();
        double dt = now - state.lastTime;
        if (dt < 0.001) dt = 0.001;
        state.lastTime = now;

        // 角速度超过 1 rad/s 后才开始加速，最高 2.0 倍：整体比上一版稍慢。
        double omega = fabs(delta) / dt;
        double gain = 1.0 + 1.0 * MIN(MAX(omega - 1.0, 0.0), 6.0) / 6.0;
        double effective = delta * gain;

        NSInteger direction = effective > 0 ? 1 : -1;
        if (state.lastDirection != 0 && direction != state.lastDirection) state.accumulated = 0;
        state.lastDirection = direction;
        state.accumulated += effective;

        NSInteger sent = 0;
        while (fabs(state.accumulated) >= kWheelStep && sent < 4) {
            double sign = state.accumulated > 0 ? 1.0 : -1.0;
            // App 的滚轮事件里 -120 = 向下滚，+120 = 向上滚（与原生滚轮按钮拖拽方向一致）。
            // UIKit 坐标下顺时针 = atan2 增大，所以顺时针发 -120、逆时针发 +120。
            UUWheelSend(sign > 0 ? -120 : 120);
            state.accumulated -= sign * kWheelStep;
            sent++;
            [state.feedback selectionChanged];
        }

        dial.indicatorAngle = angle;
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        state.active = NO;
        state.accumulated = 0;
        state.lastDirection = 0;

        UUWheelDialView *dial = objc_getAssociatedObject(view, &kAssocWheelDial);
        dial.rotating = NO;

        // 交回 App 原来的收尾逻辑（复位计时器、滚轮模式状态）
        if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
        UUEnsureDialForView(view);
        return;
    }

    if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
}

static void hook_wheel(UIView *self, SEL _cmd, UIGestureRecognizer *sender) {
    @try {
        UUWheelHandle(self, _cmd, sender, sOrigWheel);
    } @catch (NSException *e) {
        UULog(@"wheel exception: %@", e);
        if (sOrigWheel) ((void (*)(id, SEL, id))sOrigWheel)(self, _cmd, sender);
    }
}

// 每次 MouseView 布局后同步滚动模式、折叠状态以及转盘图层。
static void hook_mouse_layout(UIView *self, SEL _cmd) {
    if (sOrigMouseLayout) ((void (*)(id, SEL))sOrigMouseLayout)(self, _cmd);
    @try {
        if (UUIsSupportedAppVersion()) UUEnsureDialForView(self);
    } @catch (NSException *e) {
        UULog(@"mouse layout exception: %@", e);
    }
}

// 原 App 通过按下/释放中间滚轮显示和隐藏滚动模式，未必触发 layout。
// 紧跟原生状态更新绘制，避免普通左右键模式的滚轮被遮掉。
static void hook_mouse_press(UIView *self, SEL _cmd) {
    if (sOrigMousePress) ((void (*)(id, SEL))sOrigMousePress)(self, _cmd);
    UUEnsureDialForView(self);
}
static void hook_mouse_release(UIView *self, SEL _cmd) {
    if (sOrigMouseRelease) ((void (*)(id, SEL))sOrigMouseRelease)(self, _cmd);
    UUEnsureDialForView(self);
}

static BOOL UUIsSupportedAppVersion(void) {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    return version.length == 0 || [version hasPrefix:@"4.42."];
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
                return;   // 不再执行原来的「展开所有窗口 / 显示桌面」
            }
            break;
        }
    }
    if (sOrigDidClick) ((void (*)(id, SEL, id))sOrigDidClick)(self, _cmd, sender);
}

static BOOL UUHook(Class cls, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { UULog(@"method not found: %@", NSStringFromSelector(sel)); return NO; }
    // 只替换本类自己的实现，避免改到 UIView 基类
    BOOL own = NO;
    unsigned int c = 0;
    Method *list = class_copyMethodList(cls, &c);
    for (unsigned int i = 0; i < c; i++) if (list[i] == m) { own = YES; break; }
    free(list);
    if (!own) { UULog(@"%@ is not own method", NSStringFromSelector(sel)); return NO; }
    *orig = method_setImplementation(m, imp);
    return YES;
}

static void UUInstall(void) {
    static BOOL toolbarTried = NO, keyboardTried = NO, wheelTried = NO, contentTried = NO, renderTried = NO;

    Class tb = objc_getClass(kClsToolBar);
    if (!toolbarTried && tb) {
        toolbarTried = YES;
        BOOL a = UUHook(tb, @selector(layoutSubviews), (IMP)hook_layoutSubviews, &sOrigLayout);
        BOOL b = UUHook(tb, @selector(didClickButton:), (IMP)hook_didClickButton, &sOrigDidClick);
        UULog(@"toolbar hooks: layout=%d click=%d", a, b);
    }

    Class ck = objc_getClass(kClsCombineKey);
    if (!keyboardTried && ck) {
        keyboardTried = YES;
        BOOL l = UUHook(ck, @selector(viewWillLayoutSubviews), (IMP)hook_ck_layout, &sOrigCkLayout);
        SEL didLayout = @selector(viewDidLayoutSubviews);
        Method method = class_getInstanceMethod(ck, didLayout);
        sOrigCkDidLayout = method_getImplementation(method);
        // 此类继承 UIViewController 的 didLayout；只为目标类添加覆盖。
        BOOL d = class_addMethod(ck, didLayout, (IMP)hook_ck_didLayout, method_getTypeEncoding(method));
        if (!d) d = UUHook(ck, didLayout, (IMP)hook_ck_didLayout, &sOrigCkDidLayout);
        UULog(@"keyboard hook: will=%d did=%d", l, d);
    }

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

    Class mouse = objc_getClass(kClsMouse);
    if (!wheelTried && mouse) {
        wheelTried = YES;
        if (UUIsSupportedAppVersion()) {
            BOOL w = UUHook(mouse, @selector(mouseScrollActionWithSender:), (IMP)hook_wheel, &sOrigWheel);
            BOOL ml = UUHook(mouse, @selector(layoutSubviews), (IMP)hook_mouse_layout, &sOrigMouseLayout);
            BOOL p = UUHook(mouse, @selector(mouseScrollButtonPress), (IMP)hook_mouse_press, &sOrigMousePress);
            BOOL r = UUHook(mouse, @selector(mouseScrollButtonRelease), (IMP)hook_mouse_release, &sOrigMouseRelease);
            UULog(@"wheel hooks: gesture=%d layout=%d press=%d release=%d", w, ml, p, r);
        } else {
            UULog(@"unsupported app version, wheel dial disabled");
        }
    }

    if (!toolbarTried && !tb) UULog(@"RemoteToolBar not found");
    if (!keyboardTried && !ck) UULog(@"CombineKeyViewController not found");
    if (!wheelTried && !mouse) UULog(@"MouseView not found");

    if ((toolbarTried || keyboardTried || wheelTried) && !UUSwitchScreenFunction()) {
        UULog(@"switchScreen not resolved yet");
    }
    UULog(@"install pass: toolbar=%d keyboard=%d wheel=%d", toolbarTried, keyboardTried, wheelTried);
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
