// UUScreenSwitch — UU远程 4.42.0 (build 193)
//
// 把远控页底部工具栏的「展开所有窗口」「显示桌面」替换为「显示器1」「显示器2」，
// 点击直接切换被控端显示屏，等价于 操作 → 显示 → 多显示屏管理 里点选对应屏幕。
//
// 逆向链路（4.42.0）：
//   ToolsScreenDisplayViewViewController 的多屏菜单点选回调
//     → controlViewModel.session.screenInfos[index]
//     → ControlPanelViewModel.switchScreen(_: StreamerScreenSourceModel)   @ 0x10081a1f0
//   本插件走完全相同的调用：self = ControlPanelViewModel（x20），x0 = 屏幕对象。
//   不直接调 RemoteConnectionSession 的内部方法，切屏后的状态/埋点都由 App 自己处理。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>

#define UULog(fmt, ...) NSLog(@"[UUScreenSwitch] " fmt, ##__VA_ARGS__)

extern void uuss_call_swift_method(void *fn, void *swiftSelf, void *arg0);

// ---- 4.42.0 常量 -------------------------------------------------------------

static NSString *const kTargetVersion = @"4.42.0";
// ControlPanelViewModel.switchScreen(_:) 相对 __TEXT（mach header）的偏移
static const uintptr_t kSwitchScreenOffset = 0x81a1f0;
// 入口前 8 字节：sub sp,sp,#0x110 ; stp x26,x25,[sp,#0xc0]
static const uint8_t kSwitchScreenPrologue[8] = {0xff, 0x43, 0x04, 0xd1, 0xfa, 0x67, 0x0c, 0xa9};

// RemoteToolBarItemType（Swift 无关联值枚举，按声明顺序编号）
static const uint8_t kItemTypeShowDesktop      = 3;
static const uint8_t kItemTypeExpandAllWindows = 4;

static const char *kClsToolBar   = "_TtC14nrd_ios_client13RemoteToolBar";
static const char *kClsItem      = "_TtC14nrd_ios_clientP33_7245C1225B2709A2490E4B814BBC544E17RemoteToolBarItem";
static const char *kClsViewModel = "_TtC14nrd_ios_client21ControlPanelViewModel";
static const char *kClsSession   = "_TtC14nrd_ios_client23RemoteConnectionSession";
static const char *kClsScreen    = "StreamerScreenSourceModel";

static char kAssocDisplayIndex;   // NSNumber: 0 / 1 / -1(不处理)

static IMP sOrigLayout   = NULL;
static IMP sOrigDidClick = NULL;

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

// ---- 切屏 ------------------------------------------------------------------

static void *UUSwitchScreenFunction(void) {
    static void *fn = NULL;
    static BOOL resolved = NO;
    if (resolved) return fn;
    resolved = YES;

    NSString *ver = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    if (![ver isEqualToString:kTargetVersion]) {
        UULog(@"version mismatch: %@", ver);
        return NULL;
    }
    const struct mach_header *mh = NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0;
        if (len >= 15 && strcmp(name + len - 15, "/nrd-ios-client") == 0) {
            mh = _dyld_get_image_header(i);
            break;
        }
    }
    if (!mh) { UULog(@"main image not found"); return NULL; }
    uint8_t *p = (uint8_t *)mh + kSwitchScreenOffset;
    if (memcmp(p, kSwitchScreenPrologue, sizeof(kSwitchScreenPrologue)) != 0) {
        UULog(@"prologue mismatch at %p", p);
        return NULL;
    }
    fn = p;
    return fn;
}

static void UUSwitchToDisplay(UIView *toolBar, NSInteger index) {
    void *fn = UUSwitchScreenFunction();
    if (!fn) {
        UUToast([NSString stringWithFormat:@"UUScreenSwitch 仅适配 UU远程 %@", kTargetVersion]);
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
        // 非 native 存储（桥接 NSArray），4.42.0 实际不会出现；为安全起见不处理
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
    // vm / screen 在本作用域内被强引用持有，满足 Swift guaranteed 参数约定
    uuss_call_swift_method(fn, (__bridge void *)vm, (__bridge void *)screen);

    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

// ---- 工具栏按钮改造 -----------------------------------------------------------

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
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
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
}

static void UUStyleItem(UIView *item, NSInteger index) {
    NSString *title = [NSString stringWithFormat:@"显示器%ld", (long)index + 1];
    UILabel *label = UUItemLabel(item);
    if (label && ![label.text isEqualToString:title]) label.text = title;

    UIImageView *icon = UUItemIcon(item);
    if (icon) {
        NSNumber *done = objc_getAssociatedObject(icon, &kAssocDisplayIndex);
        if (!done || done.integerValue != index || icon.image.accessibilityIdentifier == nil) {
            CGSize size = icon.image ? icon.image.size : icon.bounds.size;
            UIColor *color = label.textColor ?: UIColor.whiteColor;
            UIImage *img = UUDisplayIcon(index, size, color);
            img.accessibilityIdentifier = @"UUScreenSwitch";
            icon.image = img;
            objc_setAssociatedObject(icon, &kAssocDisplayIndex, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static void UUUpdateToolBar(UIView *toolBar) {
    Class itemCls = objc_getClass(kClsItem);
    if (!itemCls) return;
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    UUCollectItems(toolBar, itemCls, items, 0);

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
            UUStyleItem(item, i);
        }
    }
}

// ---- Hooks -------------------------------------------------------------------

static void hook_layoutSubviews(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))sOrigLayout)(self, _cmd);
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

    Class itemCls = objc_getClass(kClsItem);
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
    ((void (*)(id, SEL, id))sOrigDidClick)(self, _cmd, sender);
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
    static BOOL installed = NO;
    if (installed) return;
    Class tb = objc_getClass(kClsToolBar);
    if (!tb) { UULog(@"RemoteToolBar not found"); return; }
    BOOL a = UUHook(tb, @selector(layoutSubviews), (IMP)hook_layoutSubviews, &sOrigLayout);
    BOOL b = UUHook(tb, @selector(didClickButton:), (IMP)hook_didClickButton, &sOrigDidClick);
    installed = a && b;
    UULog(@"hooks installed: layout=%d click=%d, switchFn=%p", a, b, UUSwitchScreenFunction());
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
