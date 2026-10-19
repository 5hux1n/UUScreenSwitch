// UUScreenSwitch — UU远程多显示器快捷切换插件
//
// 把远控页底部工具栏的「展开所有窗口」「显示桌面」替换为「显示器1」「显示器2」，
// 点击直接切换被控端显示屏，等价于 操作 → 显示 → 多显示屏管理 里点选对应屏幕。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

#define UULog(fmt, ...) NSLog(@"[UUScreenSwitch] " fmt, ##__VA_ARGS__)

extern void uuss_call_swift_method(void *fn, void *swiftSelf, void *arg0);

// ---- 常量 -------------------------------------------------------------------

// RemoteToolBarItemType（Swift 无关联值枚举，按声明顺序编号）
static const uint8_t kItemTypeShowDesktop      = 3;
static const uint8_t kItemTypeExpandAllWindows = 4;

static const char *kClsToolBar   = "_TtC14nrd_ios_client13RemoteToolBar";
static const char *kClsItem      = "_TtC14nrd_ios_clientP33_7245C1225B2709A2490E4B814BBC544E17RemoteToolBarItem";
static const char *kClsViewModel = "_TtC14nrd_ios_client21ControlPanelViewModel";
static const char *kClsSession   = "_TtC14nrd_ios_client23RemoteConnectionSession";
static const char *kClsScreen    = "StreamerScreenSourceModel";

static char kAssocDisplayIndex;   // NSNumber: 0 / 1 / -1(不处理)
static char kAssocNormalColor;    // UIColor: 按钮原始文字/图标颜色
static char kAssocActiveIndex;    // NSNumber: session 当前选中的屏幕索引兜底
static char kAssocToolBarWatcher; // UUToolBarWatcher: 定时同步多屏菜单切换状态

static IMP sOrigLayout   = NULL;
static IMP sOrigDidClick = NULL;

static void UUUpdateToolBar(UIView *toolBar);

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
    objc_setAssociatedObject(session, &kAssocActiveIndex, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // vm / screen 在本作用域内被强引用持有，满足 Swift guaranteed 参数约定
    uuss_call_swift_method(fn, (__bridge void *)vm, (__bridge void *)screen);
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
