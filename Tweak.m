// YTDownload - standalone dylib (no Substrate). Uses plain ObjC runtime swizzling.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kUA = @"com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1 like Mac OS X;)";
static NSString *const kClientVer = @"19.45.4";

static __weak UIViewController *gPlayerVC;
static UIAlertController *gProgress;

#pragma mark - UI helpers

static UIViewController *TopVC(void) {
    UIWindow *w = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *x in ((UIWindowScene *)s).windows) {
            if (x.isKeyWindow) { w = x; break; }
        }
        if (w) break;
    }
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

static void ShowMsg(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [TopVC() presentViewController:a animated:YES completion:nil];
    });
}

static void SetProgress(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gProgress) {
            gProgress = [UIAlertController alertControllerWithTitle:@"التنزيل" message:text preferredStyle:UIAlertControllerStyleAlert];
            [TopVC() presentViewController:gProgress animated:YES completion:nil];
        } else {
            gProgress.message = text;
        }
    });
}

static void HideProgress(void (^after)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *p = gProgress;
        gProgress = nil;
        if (p) [p dismissViewControllerAnimated:YES completion:after];
        else if (after) after();
    });
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

static void FetchStreams(NSString *vid, void (^cb)(NSDictionary *sd, NSString *err)) {
    NSURL *u = [NSURL URLWithString:@"https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false"];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [r setValue:kUA forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"5" forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [r setValue:kClientVer forHTTPHeaderField:@"X-YouTube-Client-Version"];
    NSDictionary *body = @{
        @"videoId": vid,
        @"contentCheckOk": @YES,
        @"racyCheckOk": @YES,
        @"context": @{@"client": @{
            @"clientName": @"IOS",
            @"clientVersion": kClientVer,
            @"deviceMake": @"Apple",
            @"deviceModel": @"iPhone16,2",
            @"osName": @"iPhone",
            @"osVersion": @"18.1.0.22B83",
            @"hl": @"en",
            @"gl": @"US"
        }}
    };
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        if (e || !d) { cb(nil, e.localizedDescription ?: @"no data"); return; }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSDictionary *sd = j[@"streamingData"];
        if (![sd isKindOfClass:NSDictionary.class]) {
            NSString *reason = j[@"playabilityStatus"][@"reason"] ?: @"لم يتم العثور على روابط البث";
            cb(nil, reason);
            return;
        }
        cb(sd, nil);
    }] resume];
}

static void FetchChunk(NSURL *url, NSFileHandle *fh, long long off, long long total,
                       void (^prog)(long long), void (^done)(BOOL)) {
    if (off >= total) { done(YES); return; }
    long long end = MIN(off + 9999999LL, total - 1);
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    [r setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", off, end] forHTTPHeaderField:@"Range"];
    [r setValue:kUA forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (e || !d.length || (code != 200 && code != 206)) { done(NO); return; }
        [fh writeData:d];
        prog(off + (long long)d.length);
        if (code == 200) { done(YES); return; } // server ignored Range, whole file received
        FetchChunk(url, fh, off + (long long)d.length, total, prog, done);
    }] resume];
}

static void DownloadFile(NSString *urlStr, long long total, NSString *path,
                         void (^prog)(long long), void (^done)(BOOL)) {
    if (total <= 0) { done(NO); return; }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    FetchChunk([NSURL URLWithString:urlStr], fh, 0, total, prog, ^(BOOL ok) {
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
    if (!vt || !at) { done(NO); return; }
    CMTime dur = CMTimeMinimum(v.duration, a.duration);
    AVMutableComposition *c = [AVMutableComposition composition];
    NSError *err = nil;
    AVMutableCompositionTrack *cv = [c addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [cv insertTimeRange:CMTimeRangeMake(kCMTimeZero, dur) ofTrack:vt atTime:kCMTimeZero error:&err];
    AVMutableCompositionTrack *ca = [c addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    [ca insertTimeRange:CMTimeRangeMake(kCMTimeZero, dur) ofTrack:at atTime:kCMTimeZero error:&err];
    if (err) { done(NO); return; }
    cv.preferredTransform = vt.preferredTransform;
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:c presetName:AVAssetExportPresetPassthrough];
    ex.outputURL = [NSURL fileURLWithPath:out];
    ex.outputFileType = AVFileTypeMPEG4;
    [ex exportAsynchronouslyWithCompletionHandler:^{
        done(ex.status == AVAssetExportSessionStatusCompleted);
    }];
}

static void Finish(NSString *path) {
    HideProgress(^{
        UIActivityViewController *s = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        UIViewController *top = TopVC();
        s.popoverPresentationController.sourceView = top.view;
        s.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2, top.view.bounds.size.height / 2, 1, 1);
        [top presentViewController:s animated:YES completion:nil];
    });
}

static void Fail(NSString *msg) {
    HideProgress(^{ ShowMsg(@"فشل", msg); });
}

static void StartDownload(NSDictionary *opt, NSString *vid) {
    NSString *tmp = NSTemporaryDirectory();
    NSString *vp = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"yt_%@_v.mp4", vid]];
    NSString *ap = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"yt_%@_a.m4a", vid]];
    NSString *out = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"yt_%@_%@.mp4", vid, opt[@"height"]]];
    NSDictionary *v = opt[@"video"], *a = opt[@"audio"];
    long long vt = [v[@"size"] longLongValue];
    long long at = [a[@"size"] longLongValue];

    SetProgress(@"جاري تنزيل الفيديو… 0%");
    DownloadFile(v[@"url"], vt, vp, ^(long long n) {
        SetProgress([NSString stringWithFormat:@"جاري تنزيل الفيديو… %lld%%", n * 100 / MAX(vt, 1)]);
    }, ^(BOOL ok) {
        if (!ok) { Fail(@"تعذّر تنزيل الفيديو. قد تكون الروابط انتهت أو تغيّرت."); return; }
        if (!a) { Finish(vp); return; }
        DownloadFile(a[@"url"], at, ap, ^(long long n) {
            SetProgress([NSString stringWithFormat:@"جاري تنزيل الصوت… %lld%%", n * 100 / MAX(at, 1)]);
        }, ^(BOOL ok2) {
            if (!ok2) { Fail(@"تعذّر تنزيل الصوت."); return; }
            SetProgress(@"جاري دمج الصوت والفيديو…");
            MergeAV(vp, ap, out, ^(BOOL ok3) {
                [[NSFileManager defaultManager] removeItemAtPath:vp error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:ap error:nil];
                if (ok3) Finish(out); else Fail(@"فشل دمج الصوت والفيديو.");
            });
        });
    });
}

#pragma mark - Options

static NSArray *BuildOptions(NSDictionary *sd) {
    NSMutableDictionary *bestAudio = nil;
    NSMutableDictionary<NSNumber *, NSDictionary *> *byHeight = [NSMutableDictionary dictionary];

    for (NSDictionary *f in sd[@"adaptiveFormats"]) {
        NSString *mime = f[@"mimeType"], *url = f[@"url"];
        if (!url.length || !mime) continue;
        long long size = SizeOf(f, url);
        if (size <= 0) continue;
        NSDictionary *item = @{@"url": url, @"size": @(size), @"bitrate": f[@"bitrate"] ?: @0};
        if ([mime hasPrefix:@"audio/mp4"]) {
            if (!bestAudio || [item[@"bitrate"] longLongValue] > [bestAudio[@"bitrate"] longLongValue])
                bestAudio = [item mutableCopy];
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
                              @"height": h, @"video": v, @"audio": bestAudio}];
        }
    }
    // Muxed formats (video+audio in one file), usually 360p/720p
    for (NSDictionary *f in sd[@"formats"]) {
        NSString *mime = f[@"mimeType"], *url = f[@"url"];
        NSNumber *h = f[@"height"];
        if (!url.length || ![mime hasPrefix:@"video/mp4"] || !h || byHeight[h]) continue;
        long long size = SizeOf(f, url);
        if (size <= 0) continue;
        [opts addObject:@{@"label": [NSString stringWithFormat:@"%@p  (%.0f MB)", h, size / 1048576.0],
                          @"height": h, @"video": @{@"url": url, @"size": @(size)}}];
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

#pragma mark - Button

@interface YTDLTarget : NSObject
+ (void)tapped;
@end

@implementation YTDLTarget
+ (void)tapped {
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
    FetchStreams(vid, ^(NSDictionary *sd, NSString *err) {
        if (!sd) { Fail(err); return; }
        NSArray *opts = BuildOptions(sd);
        if (!opts.count) { Fail(@"ما لقيت جودات قابلة للتنزيل لهذا الفيديو."); return; }
        HideProgress(^{ ShowQualityPicker(opts, vid); });
    });
}
@end

#pragma mark - Swizzle

static void (*origAppear)(id, SEL, BOOL);

static void newAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    origAppear(self, _cmd, animated);
    gPlayerVC = self;
    if ([self.view viewWithTag:9911]) return;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = 9911;
    b.frame = CGRectMake(8, 8, 34, 34);
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    b.layer.cornerRadius = 17;
    b.tintColor = UIColor.whiteColor;
    [b setImage:[UIImage systemImageNamed:@"arrow.down.circle"] forState:UIControlStateNormal];
    [b addTarget:YTDLTarget.class action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
}

static BOOL Install(void) {
    Class c = NSClassFromString(@"YTPlayerViewController");
    if (!c) return NO;
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    IMP inherited = method_getImplementation(m);
    if (class_addMethod(c, sel, (IMP)newAppear, method_getTypeEncoding(m))) {
        origAppear = (void *)inherited;       // class had no own implementation
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
