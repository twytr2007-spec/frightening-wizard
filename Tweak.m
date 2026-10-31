// YTDownload - standalone dylib (no Substrate). Plain ObjC runtime swizzling.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static __weak UIViewController *gPlayerVC;
static UIAlertController *gProgress;
static BOOL gProgressReady;
static BOOL gCancel;
static NSString *gLastErr;
static UIBackgroundTaskIdentifier gBG = 0; // 0 == UIBackgroundTaskInvalid

#pragma mark - Overlay window (button + all alerts live here)

@interface YTDLWindow : UIWindow
@end
@implementation YTDLWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (self.rootViewController.presentedViewController) return v;
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

static YTDLWindow *gWin;
static UIButton *gBtn;

static UIWindowScene *ActiveScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback) fallback = (UIWindowScene *)s;
    }
    return fallback;
}

static void UpdateButton(void) {
    UIViewController *vc = gPlayerVC;
    UIView *pv = vc.viewIfLoaded;
    BOOL show = pv && pv.window && !pv.hidden && pv.alpha > 0.01 && pv.bounds.size.width > 150;
    gBtn.hidden = !show;
    if (!show) return;
    CGRect r = [pv convertRect:pv.bounds toView:nil];
    CGRect wb = gWin.bounds;
    CGFloat x = MAX(r.origin.x, 0) + 8;
    CGFloat y = MAX(r.origin.y, 0) + 8;
    if (wb.size.width > wb.size.height) {
        x += gWin.safeAreaInsets.left;
        y += 8;
    }
    gBtn.frame = CGRectMake(x, y, 34, 34);
}

static void EnsureWindow(void) {
    if (gWin) return;
    UIWindowScene *sc = ActiveScene();
    if (!sc) return;
    gWin = [[YTDLWindow alloc] initWithWindowScene:sc];
    gWin.windowLevel = UIWindowLevelAlert + 1;
    gWin.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    gWin.rootViewController = root;
    gWin.hidden = NO;

    gBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gBtn.frame = CGRectMake(8, 8, 34, 34);
    gBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    gBtn.layer.cornerRadius = 17;
    gBtn.tintColor = UIColor.whiteColor;
    gBtn.hidden = YES;
    [gBtn setImage:[UIImage systemImageNamed:@"arrow.down.circle"] forState:UIControlStateNormal];
    id target = [[NSClassFromString(@"YTDLTarget") alloc] init];
    [gBtn addTarget:target action:NSSelectorFromString(@"tapped") forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(gBtn, "ytdl_target", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [root.view addSubview:gBtn];

    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { UpdateButton(); }];
}

static UIViewController *TopVC(void) {
    EnsureWindow();
    UIViewController *v = gWin.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

#pragma mark - Alerts

static void ShowMsg(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"نسخ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            UIPasteboard.generalPasteboard.string = msg ?: @"";
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [TopVC() presentViewController:a animated:YES completion:nil];
    });
}

static void SetProgress(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCancel) return;
        if (!gProgress) {
            gProgressReady = NO;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"التنزيل" message:text preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
                gCancel = YES;
                gProgress = nil;
            }]];
            gProgress = a;
            [TopVC() presentViewController:a animated:YES completion:^{ gProgressReady = YES; }];
        } else {
            gProgress.message = text;
        }
    });
}

static void HideProgress(void (^after)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *p = gProgress;
        if (!p) { if (after) after(); return; }
        if (!gProgressReady) { // still animating in; wait a moment
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                HideProgress(after);
            });
            return;
        }
        gProgress = nil;
        [p dismissViewControllerAnimated:YES completion:after];
    });
}

static void EndBG(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gBG != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:gBG];
            gBG = UIBackgroundTaskInvalid;
        }
    });
}

static void Fail(NSString *msg) {
    EndBG();
    if (gCancel) { HideProgress(nil); return; }
    HideProgress(^{ ShowMsg(@"فشل", msg); });
}

#pragma mark - Clients

static NSArray<NSDictionary *> *Clients(void) {
    static NSArray *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *vrUA = @"com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
        NSString *iosUA = @"com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1 like Mac OS X;)";
        c = @[
            @{@"name": @"ANDROID_VR", @"id": @"28", @"ver": @"1.60.19", @"ua": vrUA,
              @"ctx": @{@"clientName": @"ANDROID_VR", @"clientVersion": @"1.60.19",
                        @"deviceMake": @"Oculus", @"deviceModel": @"Quest 3",
                        @"osName": @"Android", @"osVersion": @"12L", @"androidSdkVersion": @32,
                        @"userAgent": vrUA, @"hl": @"en", @"gl": @"US"}},
            @{@"name": @"IOS", @"id": @"5", @"ver": @"19.45.4", @"ua": iosUA,
              @"ctx": @{@"clientName": @"IOS", @"clientVersion": @"19.45.4",
                        @"deviceMake": @"Apple", @"deviceModel": @"iPhone16,2",
                        @"osName": @"iPhone", @"osVersion": @"18.1.0.22B83",
                        @"userAgent": iosUA, @"hl": @"en", @"gl": @"US"}}
        ];
    });
    return c;
}

#pragma mark - Networking

static long long SizeOf(NSDictionary *f, NSString *url) {
    long long n = [f[@"contentLength"] longLongValue];
    if (n > 0) return n;
    NSURLComponents *c = [NSURLComponents componentsWithString:url];
    for (NSURLQueryItem *i in c.queryItems) {
        if ([i.name isEqualToString:@"clen"]) return i.value.longLongValue;
    }
    return 0;
}

static BOOL HasUsableURLs(NSDictionary *sd) {
    for (NSString *k in @[@"adaptiveFormats", @"formats"]) {
        for (NSDictionary *f in sd[k]) {
            if ([f[@"url"] length]) return YES;
        }
    }
    return NO;
}

static void TryClient(NSString *vid, NSUInteger idx, NSMutableArray *errs,
                      void (^cb)(NSDictionary *sd, NSDictionary *client, NSString *err)) {
    NSArray *clients = Clients();
    if (idx >= clients.count) { cb(nil, nil, [errs componentsJoinedByString:@"\n"]); return; }
    if (gCancel) { cb(nil, nil, @"cancelled"); return; }
    NSDictionary *cl = clients[idx];

    NSURL *u = [NSURL URLWithString:@"https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false"];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.HTTPMethod = @"POST";
    r.timeoutInterval = 25;
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [r setValue:cl[@"ua"] forHTTPHeaderField:@"User-Agent"];
    [r setValue:cl[@"id"] forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [r setValue:cl[@"ver"] forHTTPHeaderField:@"X-YouTube-Client-Version"];
    NSDictionary *body = @{
        @"videoId": vid,
        @"contentCheckOk": @YES,
        @"racyCheckOk": @YES,
        @"playbackContext": @{@"contentPlaybackContext": @{@"html5Preference": @"HTML5_PREF_WANTS"}},
        @"context": @{@"client": cl[@"ctx"]}
    };
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSDictionary *sd = [j isKindOfClass:NSDictionary.class] ? j[@"streamingData"] : nil;
        if ([sd isKindOfClass:NSDictionary.class] && HasUsableURLs(sd)) {
            cb(sd, cl, nil);
            return;
        }
        NSString *status = j[@"playabilityStatus"][@"status"];
        NSString *reason = j[@"playabilityStatus"][@"reason"];
        NSString *apiErr = j[@"error"][@"message"];
        NSString *line = [NSString stringWithFormat:@"%@: HTTP %ld %@ %@ %@ %@", cl[@"name"], (long)code,
                          status ?: @"", reason ?: @"", apiErr ?: @"", e.localizedDescription ?: @""];
        if ([sd isKindOfClass:NSDictionary.class]) line = [line stringByAppendingString:@" (no direct URLs)"];
        [errs addObject:line];
        TryClient(vid, idx + 1, errs, cb);
    }] resume];
}

static void FetchStreams(NSString *vid, void (^cb)(NSDictionary *sd, NSDictionary *client, NSString *err)) {
    TryClient(vid, 0, [NSMutableArray array], cb);
}

static void FetchChunk(NSURL *url, NSString *ua, NSFileHandle *fh, long long off, long long total,
                       void (^prog)(long long), void (^done)(BOOL)) {
    if (gCancel) { done(NO); return; }
    if (off >= total) { done(YES); return; }
    long long end = MIN(off + 9999999LL, total - 1);
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 30;
    [r setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", off, end] forHTTPHeaderField:@"Range"];
    [r setValue:ua forHTTPHeaderField:@"User-Agent"];
    __block int attempt = 0;
    __block void (^go)(void);
    go = ^{
        [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            BOOL good = !e && d.length && (code == 200 || code == 206);
            if (!good) {
                if (attempt++ < 2 && !gCancel && code != 403) { // retry transient errors
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), go);
                    return;
                }
                gLastErr = [NSString stringWithFormat:@"HTTP %ld %@", (long)code, e.localizedDescription ?: @""];
                go = nil;
                done(NO);
                return;
            }
            [fh writeData:d];
            prog(off + (long long)d.length);
            go = nil;
            if (code == 200) { done(YES); return; } // server ignored Range: whole file received
            FetchChunk(url, ua, fh, off + (long long)d.length, total, prog, done);
        }] resume];
    };
    go();
}

static void DownloadFile(NSString *urlStr, NSString *ua, long long total, NSString *path,
                         void (^prog)(long long), void (^done)(BOOL)) {
    if (total <= 0) { gLastErr = @"حجم الملف غير معروف"; done(NO); return; }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    FetchChunk([NSURL URLWithString:urlStr], ua, fh, 0, total, prog, ^(BOOL ok) {
        [fh closeFile];
        done(ok);
    });
}

#pragma mark - Merge & finish

static void MergeAV(NSString *vp, NSString *ap, NSString *out, void (^done)(BOOL)) {
    AVURLAsset *v = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:vp] options:nil];
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ap] options:nil];
    AVAssetTrack *vt = [v tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *at = [a tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!vt || !at) { gLastErr = @"لم أجد مسار الفيديو/الصوت"; done(NO); return; }
    CMTime dur = CMTimeMinimum(v.duration, a.duration);
    AVMutableComposition *c = [AVMutableComposition composition];
    NSError *err = nil;
    AVMutableCompositionTrack *cv = [c addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [cv insertTimeRange:CMTimeRangeMake(kCMTimeZero, dur) ofTrack:vt atTime:kCMTimeZero error:&err];
    AVMutableCompositionTrack *ca = [c addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    [ca insertTimeRange:CMTimeRangeMake(kCMTimeZero, dur) ofTrack:at atTime:kCMTimeZero error:&err];
    if (err) { gLastErr = err.localizedDescription; done(NO); return; }
    cv.preferredTransform = vt.preferredTransform;
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:c presetName:AVAssetExportPresetPassthrough];
    if (!ex) { gLastErr = @"تعذّر إنشاء جلسة التصدير"; done(NO); return; }
    ex.outputURL = [NSURL fileURLWithPath:out];
    ex.outputFileType = AVFileTypeMPEG4;
    [ex exportAsynchronouslyWithCompletionHandler:^{
        if (ex.status != AVAssetExportSessionStatusCompleted) gLastErr = ex.error.localizedDescription;
        done(ex.status == AVAssetExportSessionStatusCompleted);
    }];
}

static void Finish(NSString *path) {
    EndBG();
    HideProgress(^{
        UIActivityViewController *s = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        UIViewController *top = TopVC();
        s.popoverPresentationController.sourceView = top.view;
        s.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2, top.view.bounds.size.height / 2, 1, 1);
        [top presentViewController:s animated:YES completion:nil];
    });
}

static void CleanTemp(void) {
    NSString *tmp = NSTemporaryDirectory();
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:tmp error:nil]) {
        if ([f hasPrefix:@"yt_"]) [[NSFileManager defaultManager] removeItemAtPath:[tmp stringByAppendingPathComponent:f] error:nil];
    }
}

static void StartDownload(NSDictionary *opt, NSString *vid) {
    gCancel = NO;
    CleanTemp();
    dispatch_async(dispatch_get_main_queue(), ^{
        gBG = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
            gCancel = YES;
            if (gBG != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:gBG]; gBG = UIBackgroundTaskInvalid; }
        }];
    });

    NSString *tmp = NSTemporaryDirectory();
    NSString *ext = opt[@"ext"] ?: @"mp4";
    NSString *ua = opt[@"ua"];
    NSString *out = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"yt_%@_%@.%@", vid, opt[@"tag"], ext]];
    NSString *vp = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"yt_%@_v.mp4", vid]];
    NSString *ap = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"yt_%@_a.m4a", vid]];
    NSDictionary *v = opt[@"video"], *a = opt[@"audio"];
    long long vt = [v[@"size"] longLongValue];
    long long at = [a[@"size"] longLongValue];
    NSString *firstPath = a ? vp : out;

    SetProgress(@"جاري التنزيل… 0%");
    DownloadFile(v[@"url"], ua, vt, firstPath, ^(long long n) {
        SetProgress([NSString stringWithFormat:@"جاري تنزيل %@… %lld%%", a ? @"الفيديو" : @"الملف", n * 100 / MAX(vt, 1)]);
    }, ^(BOOL ok) {
        if (!ok) { Fail([NSString stringWithFormat:@"تعذّر التنزيل.\n%@", gLastErr ?: @""]); return; }
        if (!a) { Finish(out); return; }
        DownloadFile(a[@"url"], ua, at, ap, ^(long long n) {
            SetProgress([NSString stringWithFormat:@"جاري تنزيل الصوت… %lld%%", n * 100 / MAX(at, 1)]);
        }, ^(BOOL ok2) {
            if (!ok2) { Fail([NSString stringWithFormat:@"تعذّر تنزيل الصوت.\n%@", gLastErr ?: @""]); return; }
            SetProgress(@"جاري دمج الصوت والفيديو…");
            MergeAV(vp, ap, out, ^(BOOL ok3) {
                [[NSFileManager defaultManager] removeItemAtPath:vp error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:ap error:nil];
                if (ok3) Finish(out);
                else Fail([NSString stringWithFormat:@"فشل دمج الصوت والفيديو.\n%@", gLastErr ?: @""]);
            });
        });
    });
}

#pragma mark - Options

static NSArray *BuildOptions(NSDictionary *sd, NSDictionary *client) {
    NSString *ua = client[@"ua"];
    NSDictionary *bestAudio = nil;
    NSMutableDictionary<NSNumber *, NSDictionary *> *byHeight = [NSMutableDictionary dictionary];

    for (NSDictionary *f in sd[@"adaptiveFormats"]) {
        NSString *mime = f[@"mimeType"], *url = f[@"url"];
        if (!url.length || !mime) continue;
        long long size = SizeOf(f, url);
        if (size <= 0) continue;
        NSDictionary *item = @{@"url": url, @"size": @(size), @"bitrate": f[@"bitrate"] ?: @0};
        if ([mime hasPrefix:@"audio/mp4"]) {
            if (!bestAudio || [item[@"bitrate"] longLongValue] > [bestAudio[@"bitrate"] longLongValue]) bestAudio = item;
        } else if ([mime hasPrefix:@"video/mp4"] && [mime containsString:@"avc1"]) {
            NSNumber *h = f[@"height"];
            if (!h) continue;
            NSDictionary *cur = byHeight[h];
            if (!cur || [item[@"bitrate"] longLongValue] > [cur[@"bitrate"] longLongValue]) byHeight[h] = item;
        }
    }

    NSMutableArray *opts = [NSMutableArray array];
    NSArray *heights = [byHeight.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) {
        return [y compare:x];
    }];
    if (bestAudio) {
        for (NSNumber *h in heights) {
            NSDictionary *v = byHeight[h];
            double mb = ([v[@"size"] longLongValue] + [bestAudio[@"size"] longLongValue]) / 1048576.0;
            [opts addObject:@{@"label": [NSString stringWithFormat:@"%@p  (%.0f MB)", h, mb],
                              @"tag": [NSString stringWithFormat:@"%@p", h], @"ext": @"mp4",
                              @"video": v, @"audio": bestAudio, @"ua": ua}];
        }
    }
    // Muxed (video+audio in one file)
    for (NSDictionary *f in sd[@"formats"]) {
        NSString *mime = f[@"mimeType"], *url = f[@"url"];
        NSNumber *h = f[@"height"];
        if (!url.length || ![mime hasPrefix:@"video/mp4"] || !h || (bestAudio && byHeight[h])) continue;
        long long size = SizeOf(f, url);
        if (size <= 0) continue;
        [opts addObject:@{@"label": [NSString stringWithFormat:@"%@p  (%.0f MB)", h, size / 1048576.0],
                          @"tag": [NSString stringWithFormat:@"%@p", h], @"ext": @"mp4",
                          @"video": @{@"url": url, @"size": @(size)}, @"ua": ua}];
    }
    if (bestAudio) {
        [opts addObject:@{@"label": [NSString stringWithFormat:@"🎵 صوت فقط  (%.0f MB)", [bestAudio[@"size"] longLongValue] / 1048576.0],
                          @"tag": @"audio", @"ext": @"m4a", @"video": bestAudio, @"ua": ua}];
    }
    return opts;
}

static void ShowQualityPicker(NSArray *opts, NSString *vid) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"اختر الجودة" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *o in opts) {
            [a addAction:[UIAlertAction actionWithTitle:o[@"label"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    StartDownload(o, vid);
                });
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = TopVC();
        a.popoverPresentationController.sourceView = top.view;
        a.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2, top.view.bounds.size.height / 2, 1, 1);
        [top presentViewController:a animated:YES completion:nil];
    });
}

#pragma mark - Button action

@interface YTDLTarget : NSObject
- (void)tapped;
@end

@implementation YTDLTarget
- (void)tapped {
    if (gProgress) return; // a download is already running
    gCancel = NO;
    NSString *vid = nil;
    UIViewController *vc = gPlayerVC;
    SEL sel = NSSelectorFromString(@"currentVideoID");
    if (vc && [vc respondsToSelector:sel]) {
        vid = ((NSString * (*)(id, SEL))objc_msgSend)(vc, sel);
    }
    if (![vid isKindOfClass:NSString.class] || !vid.length) {
        ShowMsg(@"خطأ", @"ما قدرت أجيب معرّف الفيديو. افتح فيديو وخلّه يشتغل أولًا.");
        return;
    }
    SetProgress(@"جاري جلب الجودات المتاحة…");
    FetchStreams(vid, ^(NSDictionary *sd, NSDictionary *client, NSString *err) {
        if (!sd) { Fail([NSString stringWithFormat:@"ما لقيت روابط بث.\n\n%@", err ?: @""]); return; }
        NSArray *opts = BuildOptions(sd, client);
        if (!opts.count) { Fail(@"ما لقيت جودات قابلة للتنزيل (غالبًا الصيغ غير مدعومة)."); return; }
        HideProgress(^{ ShowQualityPicker(opts, vid); });
    });
}
@end

#pragma mark - Swizzle

static void (*origAppear)(id, SEL, BOOL);

static void newAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    origAppear(self, _cmd, animated);
    gPlayerVC = self;
    EnsureWindow();
}

static BOOL Install(void) {
    Class c = NSClassFromString(@"YTPlayerViewController");
    if (!c) return NO;
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    IMP inherited = method_getImplementation(m);
    if (class_addMethod(c, sel, (IMP)newAppear, method_getTypeEncoding(m))) {
        origAppear = (void *)inherited;
    } else {
        origAppear = (void *)method_setImplementation(class_getInstanceMethod(c, sel), (IMP)newAppear);
    }
    return YES;
}

static void TryInstall(int n) {
    if (Install()) return;
    if (n < 6) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TryInstall(n + 1);
        });
    }
}

__attribute__((constructor)) static void YTDLInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ TryInstall(0); });
}
