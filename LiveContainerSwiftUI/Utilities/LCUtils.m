@import Darwin;
@import MachO;
@import UIKit;
@import UniformTypeIdentifiers;
@import Security;
#import <IOKit/IOKitLib.h>

#import "LCUtils.h"
#import "../../LiveContainer/LCSharedUtils.h"
#import "LCAppInfo.h"
#import "../../MultitaskSupport/DecoratedAppSceneViewController.h"
#import "../../ZSign/zsigner.h"
#import "LiveContainerSwiftUI-Swift.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <poll.h>
#include <unistd.h>
#include <signal.h>

// make SFSafariView happy and open data: URLs
@implementation NSURL(hack)
- (BOOL)safari_isHTTPFamilyURL {
    // Screw it, Apple
    return YES;
}
@end

@implementation LCUtils
#pragma mark Certificate & password

+ (NSData *)certificateData {
    NSUserDefaults* nud = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    if(!nud) {
        nud = NSUserDefaults.standardUserDefaults;
    }
    return [nud objectForKey:@"LCCertificateData"];
}


+ (void)setCertificatePassword:(NSString *)certPassword {
    [NSUserDefaults.standardUserDefaults setObject:certPassword forKey:@"LCCertificatePassword"];
    [[[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]] setObject:certPassword forKey:@"LCCertificatePassword"];
}


#pragma mark Multitasking
+ (NSString *)liveProcessBundleIdentifier {
    // first check if we have LiveProcess extension in our own bundle
    NSBundle *liveProcessBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"]];
    if(liveProcessBundle) {
        return liveProcessBundle.bundleIdentifier;
    }
    
    // in LC2, attempt to guess LC1's LiveProcess extension
    NSString *bundleID = [NSString stringWithFormat:@"com.kdt.livecontainer.%@.LiveProcess", LCSharedUtils.teamIdentifier];
    if([NSExtension extensionWithIdentifier:bundleID error:nil]) {
        return bundleID;
    }
    
    return nil;
}

+ (void)launchMultitaskGuestApp:(NSString *)displayName completionHandler:(void (^)(NSNumber *pid, NSError *error))completionHandler {
    if(!self.liveProcessBundleIdentifier) {
        NSError *error = [NSError errorWithDomain:displayName code:2 userInfo:@{NSLocalizedDescriptionKey: @"LiveProcess extension not found. Please reinstall LiveContainer and select Keep Extensions"}];
        if (completionHandler) completionHandler(nil, error);
        return;
    }
    
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    NSString* bundleId = [lcUserDefaults stringForKey:@"selected"];
    NSString* dataUUID = [lcUserDefaults stringForKey:@"selectedContainer"];
    
    [lcUserDefaults removeObjectForKey:@"selected"];
    [lcUserDefaults removeObjectForKey:@"selectedContainer"];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 16.1, *)) {
            if(UIApplication.sharedApplication.supportsMultipleScenes && [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode"] == 1) {
                [MultitaskWindowManager openAppWindowWithDisplayName:displayName dataUUID:dataUUID bundleId:bundleId pidCallback:completionHandler];
                MultitaskDockManager *dock = [MultitaskDockManager shared];
                [dock addRunningApp:displayName appUUID:dataUUID view:nil];
                return;
            }
        }
        
        UIViewController *rootVC = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.rootViewController;
        DecoratedAppSceneViewController *launcherView = [[DecoratedAppSceneViewController alloc] initWindowName:displayName bundleId:bundleId dataUUID:dataUUID rootVC:rootVC];
        // Wire PID callback
        launcherView.pidAvailableHandler = completionHandler;
        launcherView.view.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        launcherView.view.center = rootVC.view.center;
    });
}

#pragma mark Code signing


+ (void)loadStoreFrameworksWithError2:(NSError **)error {
    // too lazy to use dispatch_once
    static BOOL loaded = NO;
    if (loaded) return;

    void* handle = dlopen("@executable_path/Frameworks/ZSign.dylib", RTLD_GLOBAL);
    const char* dlerr = dlerror();
    if (!handle || (uint64_t)handle > 0xf00000000000) {
        if (dlerr) {
            *error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load ZSign: %s", dlerr]}];
        } else {
            *error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load ZSign: An unknown error occurred."]}];
        }
        NSLog(@"[LC] %s", dlerr);
        return;
    }
    
    loaded = YES;
}

+ (NSURL *)storeBundlePath {
    if ([self store] == SideStore) {
        return [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.SideStore.SideStore/App.app"];
    } else {
        return [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.rileytestut.AltStore/App.app"];
    }
}

+ (NSString *)storeInstallURLScheme {
    if ([self store] == SideStore) {
        return @"sidestore://install?url=%@";
    } else {
        return @"altstore://install?url=%@";
    }
}

+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *error;

    // use zsign as our signer~
    // Load libraries from Documents, yeah
    [self loadStoreFrameworksWithError2:&error];

    if (error) {
        completionHandler(NO, error);
        return nil;
    }

    NSLog(@"[LC] starting signing...");
    
    NSProgress* ans = [NSClassFromString(@"ZSigner") signWithAppPath:[path path] bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData pass:LCSharedUtils.certificatePassword completionHandler:completionHandler];
    
    return ans;
}

+ (NSProgress *)signFilesWithZSignWithURLs:(NSArray<NSURL*>*)urls completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *error;
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        completionHandler(NO, error);
        return nil;
    }
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[urls count]];
    for (NSURL *url in urls) {
        [paths addObject:url.path];
    }
    
    return [NSClassFromString(@"ZSigner") signMachOPathArr:paths bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData
                                                      pass:LCSharedUtils.certificatePassword completionHandler:completionHandler];
}

+ (NSString*)getCertTeamIdWithKeyData:(NSData*)keyData password:(NSString*)password {
    NSError *error;
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        return nil;
    }
    NSString* ans = [NSClassFromString(@"ZSigner") getTeamIdWithCert:keyData pass:password];
    return ans;
}

+ (int)validateCertificateWithCompletionHandler:(void(^)(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error))completionHandler {
    NSError *error;
    NSData *certData = [LCUtils certificateData];
    if (error) {
        return -6;
    }
    [self loadStoreFrameworksWithError2:&error];
    int ans = [NSClassFromString(@"ZSigner") checkCert:certData pass:[LCSharedUtils certificatePassword] completionHandler:completionHandler];
    return ans;
}

#pragma mark JIT

+ (BOOL)isTXMScriptRequired {
    if (@available(iOS 19.0, *)) {
        // https://github.com/opa334/Dopamine/commit/e8438b4a64ead3997d2c70a575431cb1b4070fb9
        io_registry_entry_t memory_map = IORegistryEntryFromPath(0, "IODeviceTree:/chosen/memory-map");
        if (memory_map == IO_OBJECT_NULL)
            return NO;
        NSArray *keys = (__bridge NSArray *)IORegistryEntryCreateCFProperty(memory_map, CFSTR(kIORegistryEntryPropertyKeysKey), 0, 0);
        IOObjectRelease(memory_map);
        return keys && [keys containsObject:@"TXM"];
    }
    return NO;
}

+ (NSString *)base64EncodedUniversalJITScript {
    static dispatch_once_t onceToken;
    static NSString *script;
    dispatch_once(&onceToken, ^{
        NSData *data = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"universal" ofType:@"js"]];
        script = [data base64EncodedStringWithOptions:0];
    });
    return script;
}

#pragma mark Setup

+ (Store) store {
    static Store ans;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // use uttype to accurately detect store
        if([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.sidestore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = SideStore;
        } else if ([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.altstore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = AltStore;
        } else {
            ans = Unknown;
        }
        
        if(ans != Unknown) {
            return;
        }
        
        if([[LCSharedUtils appGroupID] containsString:@"AltStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.rileytestut.AltStore"]) {
            ans = AltStore;
        } else if ([[LCSharedUtils appGroupID] containsString:@"SideStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.SideStore.SideStore"]) {
            ans = SideStore;
        } else if (![[LCSharedUtils appGroupID] containsString:@"Unknown"] ) {
            ans = ADP;
        } else {
            ans = Unknown;
        }
    });
    return ans;
}

+ (NSString *)appUrlScheme {
    return NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
}

+ (BOOL)isAppGroupAltStoreLike {
    return [LCSharedUtils.appGroupID containsString:@"SideStore"] || [LCSharedUtils.appGroupID containsString:@"AltStore"];
}

+ (void)changeMainExecutableTo:(NSString *)exec error:(NSError **)error {
    NSURL *infoPath = [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.kdt.livecontainer/App.app/Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfURL:infoPath];
    if (!infoDict) return;

    infoDict[@"CFBundleExecutable"] = exec;
    [infoDict writeToURL:infoPath error:error];
}

+ (void)validateJITLessSetupWithCompletionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    // Verify that the certificate is usable
    // Create a test app bundle
    NSString *path = NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpLibPath = [path stringByAppendingPathComponent:@"TestJITLess.dylib"];
    [NSFileManager.defaultManager copyItemAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TestJITLess.dylib"] toPath:tmpLibPath error:nil];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block bool signSuccess = false;
    __block NSError* signError = nil;
    
    // Sign the test app bundle

    [LCUtils signFilesWithZSignWithURLs:@[[NSURL fileURLWithPath:tmpLibPath]]
                  completionHandler:^(BOOL success, NSError *_Nullable error) {
        signSuccess = success;
        signError = error;
        dispatch_semaphore_signal(sema);
    }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!signSuccess) {
            completionHandler(NO, signError);
        } else if (checkCodeSignature([tmpLibPath UTF8String])) {
            completionHandler(YES, signError);
        } else {
            completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:@{NSLocalizedDescriptionKey: @"lc.signer.latestCertificateInvalidErr"}]);
        }
        [NSFileManager.defaultManager removeItemAtPath:tmpLibPath error:nil];
    });
}

+ (NSURL *)archiveIPAWithBundleName:(NSString*)newBundleName includingExtraInfoDict:(NSDictionary *)extraInfoDict error:(NSError **)error {
    return [self archiveIPAWithBundleName:newBundleName
                       guestAppBundlePath:nil
                      guestAppDisplayName:nil
                   includingExtraInfoDict:extraInfoDict
                                    error:error];
}

+ (NSURL *)archiveIPAWithBundleName:(NSString*)newBundleName
                 guestAppBundlePath:(NSString*)guestAppBundlePath
                guestAppDisplayName:(NSString*)guestAppDisplayName
             includingExtraInfoDict:(NSDictionary *)extraInfoDict
                              error:(NSError **)error {
    if (error && *error) return nil;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *bundlePath = NSBundle.mainBundle.bundleURL;

    NSURL *tmpPath = manager.temporaryDirectory;

    NSURL *tmpPayloadPath = [tmpPath URLByAppendingPathComponent:[NSString stringWithFormat:@"%@/Payload", newBundleName]];
    [manager removeItemAtURL:tmpPayloadPath error:nil];
    [manager createDirectoryAtURL:tmpPayloadPath withIntermediateDirectories:YES attributes:nil error:error];
    if (error && *error) return nil;
    
    NSURL *tmpIPAPath = [tmpPath URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipa", newBundleName]];
    
    NSURL* appBundlePath = [tmpPayloadPath URLByAppendingPathComponent:@"App.app"];
    [manager copyItemAtURL:bundlePath toURL:appBundlePath error:error];
    if (error && *error) return nil;
    
    NSURL *infoPath = [appBundlePath URLByAppendingPathComponent:@"Info.plist"];
    NSData *infoData = [NSData dataWithContentsOfURL:infoPath];
    if (!infoData) {
        if (error) *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"Failed to read App Info.plist"}];
        return nil;
    }
    NSMutableDictionary *infoDict = [NSPropertyListSerialization propertyListWithData:infoData
                                                                              options:NSPropertyListMutableContainersAndLeaves
                                                                               format:nil
                                                                                error:error];
    if (!infoDict || (error && *error)) return nil;

    infoDict[@"CFBundleDisplayName"] = newBundleName;
    infoDict[@"CFBundleName"] = newBundleName;
    infoDict[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"com.kdt.%@", newBundleName];
    
    NSMutableArray *urlTypes = [NSMutableArray array];
    [urlTypes addObject:[@{
        @"CFBundleURLName": [NSString stringWithFormat:@"com.kdt.%@.urlscheme", [newBundleName lowercaseString]],
        @"CFBundleURLSchemes": [NSMutableArray arrayWithObject:[newBundleName lowercaseString]]
    } mutableCopy]];
    infoDict[@"CFBundleURLTypes"] = urlTypes;

    [infoDict removeObjectForKey:@"UTExportedTypeDeclarations"];
    infoDict[@"CFBundleIconName"] = @"AppIconGrey";
    infoDict[@"CFBundleIcons"] = [@{
        @"CFBundlePrimaryIcon": [@{
            @"CFBundleIconFiles": [NSMutableArray arrayWithObject:@"AppIconGrey60x60"],
            @"CFBundleIconName": @"AppIconGrey"
        } mutableCopy]
    } mutableCopy];
    infoDict[@"CFBundleIcons~ipad"] = [@{
        @"CFBundlePrimaryIcon": [@{
            @"CFBundleIconFiles": [NSMutableArray arrayWithObjects:@"AppIconGrey60x60", @"AppIconGrey76x76", nil],
            @"CFBundleIconName": @"AppIconGrey"
        } mutableCopy]
    } mutableCopy];
    
    // Dedicated guest app configuration
    if (guestAppBundlePath && guestAppBundlePath.length > 0) {
        NSString *displayName = guestAppDisplayName;
        NSDictionary *guestInfoPlist = [NSDictionary dictionaryWithContentsOfFile:[guestAppBundlePath stringByAppendingPathComponent:@"Info.plist"]];
        if (!guestInfoPlist) {
            NSData *pData = [NSData dataWithContentsOfFile:[guestAppBundlePath stringByAppendingPathComponent:@"Info.plist"]];
            if (pData) {
                guestInfoPlist = [NSPropertyListSerialization propertyListWithData:pData options:0 format:nil error:nil];
            }
        }
        NSDictionary *guestLCAppInfo = [NSDictionary dictionaryWithContentsOfFile:[guestAppBundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
        if (!displayName || displayName.length == 0) {
            displayName = guestInfoPlist[@"CFBundleDisplayName"] ?: guestInfoPlist[@"CFBundleName"] ?: newBundleName;
        }
        infoDict[@"CFBundleDisplayName"] = displayName;
        infoDict[@"CFBundleName"] = displayName;
        
        NSString *relativeBundlePath = [guestAppBundlePath lastPathComponent];
        infoDict[@"LCAutoLaunchBundleId"] = relativeBundlePath;
        NSString *guestBundleId = guestInfoPlist[@"CFBundleIdentifier"] ?: guestLCAppInfo[@"LCOrignalBundleIdentifier"];
        if (guestBundleId) {
            infoDict[@"LCAutoLaunchGuestBundleId"] = guestBundleId;
        }
        
        if (extraInfoDict[@"LCAutoLaunchContainer"]) {
            infoDict[@"LCAutoLaunchContainer"] = extraInfoDict[@"LCAutoLaunchContainer"];
        }
        
        // Save to shared defaults as well
        NSUserDefaults *sharedDefaults = [NSUserDefaults lcSharedDefaults];
        if (!sharedDefaults) {
            sharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
        }
        if (sharedDefaults) {
            NSString *scheme = [newBundleName lowercaseString];
            [sharedDefaults setObject:relativeBundlePath forKey:[NSString stringWithFormat:@"LCAutoLaunchBundleId_%@", scheme]];
            if (guestBundleId) {
                [sharedDefaults setObject:guestBundleId forKey:[NSString stringWithFormat:@"LCAutoLaunchGuestBundleId_%@", scheme]];
            }
            if (extraInfoDict[@"LCAutoLaunchContainer"]) {
                [sharedDefaults setObject:extraInfoDict[@"LCAutoLaunchContainer"] forKey:[NSString stringWithFormat:@"LCAutoLaunchContainer_%@", scheme]];
            }
        }
        
        // Copy guest URL schemes so the dedicated container can respond to deep links
        NSArray *guestURLTypes = guestInfoPlist[@"CFBundleURLTypes"];
        if ([guestURLTypes isKindOfClass:[NSArray class]]) {
            for (NSDictionary *urlType in guestURLTypes) {
                if ([urlType isKindOfClass:[NSDictionary class]]) {
                    NSArray *schemes = urlType[@"CFBundleURLSchemes"];
                    if ([schemes isKindOfClass:[NSArray class]]) {
                        NSMutableArray *filteredSchemes = [NSMutableArray array];
                        for (NSString *sch in schemes) {
                            if ([sch isKindOfClass:[NSString class]] && ![sch.lowercaseString hasPrefix:@"livecontainer"]) {
                                [filteredSchemes addObject:sch];
                            }
                        }
                        if (filteredSchemes.count > 0) {
                            [urlTypes addObject:[@{
                                @"CFBundleURLName": urlType[@"CFBundleURLName"] ?: [NSString stringWithFormat:@"com.kdt.%@.guest", newBundleName],
                                @"CFBundleURLSchemes": filteredSchemes
                            } mutableCopy]];
                        }
                    }
                }
            }
        }
        
        // Handle Icons:
        // 1. Copy any loose PNG icon files from guest bundle
        NSMutableSet<NSString *> *copiedIconBasenames = [NSMutableSet new];
        NSArray<NSString *> *guestFiles = [manager contentsOfDirectoryAtPath:guestAppBundlePath error:nil];
        for (NSString *file in guestFiles) {
            if ([file.pathExtension.lowercaseString isEqualToString:@"png"]) {
                NSString *nameLower = file.lowercaseString;
                if ([nameLower containsString:@"icon"] || [nameLower containsString:@"appicon"]) {
                    NSURL *src = [NSURL fileURLWithPath:[guestAppBundlePath stringByAppendingPathComponent:file]];
                    NSURL *dst = [appBundlePath URLByAppendingPathComponent:file];
                    [manager removeItemAtURL:dst error:nil];
                    [manager copyItemAtURL:src toURL:dst error:nil];
                    
                    NSString *base = [file stringByDeletingPathExtension];
                    base = [base stringByReplacingOccurrencesOfString:@"@2x" withString:@""];
                    base = [base stringByReplacingOccurrencesOfString:@"@3x" withString:@""];
                    base = [base stringByReplacingOccurrencesOfString:@"~ipad" withString:@""];
                    [copiedIconBasenames addObject:base];
                }
            }
        }
        
        // 2. Extract / generate rendered icon image
        UIImage *guestIcon = [UIImage generateIconForBundleURL:[NSURL fileURLWithPath:guestAppBundlePath] style:Original hasBorder:NO];
        if (!guestIcon) {
            NSString *lightPath = [guestAppBundlePath stringByAppendingPathComponent:@"LCAppIconLight.png"];
            if ([manager fileExistsAtPath:lightPath]) {
                guestIcon = [UIImage imageWithContentsOfFile:lightPath];
            }
        }
        if (!guestIcon) {
            NSString *darkPath = [guestAppBundlePath stringByAppendingPathComponent:@"LCAppIconDark.png"];
            if ([manager fileExistsAtPath:darkPath]) {
                guestIcon = [UIImage imageWithContentsOfFile:darkPath];
            }
        }
        if (!guestIcon) {
            for (NSString *file in guestFiles) {
                if ([file.pathExtension.lowercaseString isEqualToString:@"png"]) {
                    NSString *nameLower = file.lowercaseString;
                    if ([nameLower containsString:@"appicon"] || [nameLower containsString:@"icon"]) {
                        UIImage *candidate = [UIImage imageWithContentsOfFile:[guestAppBundlePath stringByAppendingPathComponent:file]];
                        if (candidate && candidate.size.width >= 60) {
                            guestIcon = candidate;
                            break;
                        }
                    }
                }
            }
        }
        
        void (^writeResized)(UIImage*, CGSize, NSString*) = ^(UIImage *img, CGSize size, NSString *filename) {
            if (!img) return;
            UIGraphicsBeginImageContextWithOptions(size, NO, 1.0);
            [img drawInRect:CGRectMake(0, 0, size.width, size.height)];
            UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (resized) {
                NSData *png = UIImagePNGRepresentation(resized);
                if (png) {
                    NSURL *dst = [appBundlePath URLByAppendingPathComponent:filename];
                    [manager removeItemAtURL:dst error:nil];
                    [png writeToURL:dst atomically:YES];
                }
            }
        };
        
        if (guestIcon) {
            // Write to all standard icon files and sizes
            writeResized(guestIcon, CGSizeMake(120, 120), @"AppIconGuest60x60@2x.png");
            writeResized(guestIcon, CGSizeMake(180, 180), @"AppIconGuest60x60@3x.png");
            writeResized(guestIcon, CGSizeMake(152, 152), @"AppIconGuest76x76@2x~ipad.png");
            writeResized(guestIcon, CGSizeMake(167, 167), @"AppIconGuest83.5x83.5@2x~ipad.png");
            writeResized(guestIcon, CGSizeMake(1024, 1024), @"AppIconGuest1024.png");
            
            // Overwrite default AppIconGrey files too so grey asset resolution gets guest icon
            writeResized(guestIcon, CGSizeMake(120, 120), @"AppIconGrey60x60@2x.png");
            writeResized(guestIcon, CGSizeMake(180, 180), @"AppIconGrey60x60@3x.png");
            writeResized(guestIcon, CGSizeMake(152, 152), @"AppIconGrey76x76@2x~ipad.png");
            writeResized(guestIcon, CGSizeMake(167, 167), @"AppIconGrey83.5x83.5@2x~ipad.png");
            writeResized(guestIcon, CGSizeMake(1024, 1024), @"AppIconGrey1024.png");
            
            // Overwrite AppIcon files too
            writeResized(guestIcon, CGSizeMake(120, 120), @"AppIcon60x60@2x.png");
            writeResized(guestIcon, CGSizeMake(180, 180), @"AppIcon60x60@3x.png");
            writeResized(guestIcon, CGSizeMake(152, 152), @"AppIcon76x76@2x~ipad.png");
            writeResized(guestIcon, CGSizeMake(167, 167), @"AppIcon83.5x83.5@2x~ipad.png");
            
            // Overwrite legacy Icon naming files
            writeResized(guestIcon, CGSizeMake(120, 120), @"Icon-60@2x.png");
            writeResized(guestIcon, CGSizeMake(180, 180), @"Icon-60@3x.png");
            writeResized(guestIcon, CGSizeMake(152, 152), @"Icon-76@2x.png");
            writeResized(guestIcon, CGSizeMake(167, 167), @"Icon-83.5@2x.png");
        }
        
        NSMutableArray *phoneIconFiles = [NSMutableArray arrayWithArray:@[@"AppIconGuest60x60", @"AppIcon60x60", @"Icon-60", @"AppIconGrey60x60"]];
        NSMutableArray *padIconFiles = [NSMutableArray arrayWithArray:@[@"AppIconGuest60x60", @"AppIconGuest76x76", @"AppIcon60x60", @"AppIcon76x76", @"Icon-76", @"Icon-60", @"AppIconGrey60x60", @"AppIconGrey76x76"]];
        for (NSString *base in copiedIconBasenames) {
            if (![phoneIconFiles containsObject:base]) [phoneIconFiles addObject:base];
            if (![padIconFiles containsObject:base]) [padIconFiles addObject:base];
        }
        
        // Check if guest app has an Assets.car
        NSString *guestAssetsCar = [guestAppBundlePath stringByAppendingPathComponent:@"Assets.car"];
        BOOL guestHasAssetsCar = [manager fileExistsAtPath:guestAssetsCar];
        
        if (guestHasAssetsCar && guestInfoPlist[@"CFBundleIcons"]) {
            // Copy guest app's compiled Assets.car containing its real native icon
            NSURL *dstCar = [appBundlePath URLByAppendingPathComponent:@"Assets.car"];
            [manager removeItemAtURL:dstCar error:nil];
            [manager copyItemAtURL:[NSURL fileURLWithPath:guestAssetsCar] toURL:dstCar error:nil];
            
            // Adopt guest app's CFBundleIcons configuration
            if (guestInfoPlist[@"CFBundleIcons"]) {
                infoDict[@"CFBundleIcons"] = [guestInfoPlist[@"CFBundleIcons"] mutableCopy];
            }
            if (guestInfoPlist[@"CFBundleIcons~ipad"]) {
                infoDict[@"CFBundleIcons~ipad"] = [guestInfoPlist[@"CFBundleIcons~ipad"] mutableCopy];
            }
            if (guestInfoPlist[@"CFBundleIconName"]) {
                infoDict[@"CFBundleIconName"] = guestInfoPlist[@"CFBundleIconName"];
            } else {
                [infoDict removeObjectForKey:@"CFBundleIconName"];
            }
            if (guestInfoPlist[@"CFBundleIconFiles"]) {
                infoDict[@"CFBundleIconFiles"] = [guestInfoPlist[@"CFBundleIconFiles"] mutableCopy];
            }
            if (guestInfoPlist[@"CFBundleIconFile"]) {
                infoDict[@"CFBundleIconFile"] = guestInfoPlist[@"CFBundleIconFile"];
            }
        } else {
            // Remove LiveContainer's Assets.car so it doesn't hijack the icon with AppIconGrey!
            [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Assets.car"] error:nil];
            [infoDict removeObjectForKey:@"CFBundleIconName"];
            
            infoDict[@"CFBundleIcons"] = [@{
                @"CFBundlePrimaryIcon": [@{
                    @"CFBundleIconFiles": phoneIconFiles
                } mutableCopy]
            } mutableCopy];
            infoDict[@"CFBundleIcons~ipad"] = [@{
                @"CFBundlePrimaryIcon": [@{
                    @"CFBundleIconFiles": padIconFiles
                } mutableCopy]
            } mutableCopy];
            infoDict[@"CFBundleIconFiles"] = phoneIconFiles;
            infoDict[@"CFBundleIconFile"] = phoneIconFiles.firstObject;
        }
        
        // Bump CFBundleVersion with timestamp so SpringBoard detects a new version and flushes icon cache
        long timestamp = (long)[[NSDate date] timeIntervalSince1970];
        infoDict[@"CFBundleVersion"] = [NSString stringWithFormat:@"%@.%ld", infoDict[@"CFBundleVersion"] ?: @"1", timestamp];
    }

    [infoDict addEntriesFromDictionary:extraInfoDict];
    
    // reset a executable name so they don't look the same on the log
    NSURL* execFromPath = [appBundlePath URLByAppendingPathComponent:infoDict[@"CFBundleExecutable"]];
    infoDict[@"CFBundleExecutable"] = newBundleName;
    NSURL* execToPath = [appBundlePath URLByAppendingPathComponent:infoDict[@"CFBundleExecutable"]];
    
    // MARK: patch main executable
    // we remove the teamId after app group id so it can be correctly signed by AltSign.
    NSString* entitlementXML = getExecutableEntitlementXML(NSBundle.mainBundle.executablePath);
    NSData *plistData = [entitlementXML dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSPropertyListSerialization propertyListWithData:plistData
                                                                          options:NSPropertyListMutableContainers
                                                                            format:nil
                                                                            error:error];
    if(error && *error) {
        return nil;
    }
    
    NSString* teamId = dict[@"com.apple.developer.team-identifier"];
    if(![teamId isKindOfClass:NSString.class]) {
        if(error) *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"com.apple.developer.team-identifier is not a string!"}];
        return nil;
    }
    infoDict[@"PrimaryLiveContainerTeamId"] = teamId;
    NSArray* appGroupsToFind = @[
        @"group.com.SideStore.SideStore",
        @"group.com.rileytestut.AltStore",
    ];
    
    // remove the team id prefix in app group id added by SideStore/AltStore
    for(NSString* appGroup in appGroupsToFind) {
        NSUInteger appGroupCount = [dict[@"com.apple.security.application-groups"] count];
        for(int i = 0; i < appGroupCount; ++i) {
            NSString* targetAppGroup = [NSString stringWithFormat:@"%@.%@", appGroup, teamId];
            if([dict[@"com.apple.security.application-groups"][i] isEqualToString:targetAppGroup]) {
                dict[@"com.apple.security.application-groups"][i] = appGroup;
            }
        }
    }
    
    // set correct application-identifier
    dict[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, infoDict[@"CFBundleIdentifier"]];
    
    // For TrollStore
    NSString* containerId = dict[@"com.apple.private.security.container-required"];
    if(containerId) {
        dict[@"com.apple.private.security.container-required"] = infoDict[@"CFBundleIdentifier"];
    }
    
    
    // We have to change executable's UUID so iOS won't consider 2 executables the same
    NSString* errorChangeUUID = LCParseMachO([execFromPath.path UTF8String], false, ^(const char *path, struct mach_header_64 *header, int fd, void* filePtr) {
        LCChangeMachOUUID(header);
    });
    if (errorChangeUUID) {
        NSMutableDictionary* details = [NSMutableDictionary dictionary];
        [details setValue:errorChangeUUID forKey:NSLocalizedDescriptionKey];
        // populate the error object with the details
        if(error) *error = [NSError errorWithDomain:@"world" code:200 userInfo:details];
        NSLog(@"[LC] %@", errorChangeUUID);
        return nil;
    }
    
    NSData* newEntitlementData = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    [LCUtils loadStoreFrameworksWithError2:error];
    BOOL adhocSignSuccess = [NSClassFromString(@"ZSigner") adhocSignMachOAtPath:execFromPath.path bundleId:infoDict[@"CFBundleIdentifier"] entitlementData:newEntitlementData];
    if (!adhocSignSuccess) {
        if(error) *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"Failed to adhoc sign main executable!"}];
        return nil;
    }
    
    // MARK: archive bundle
    
    [manager moveItemAtURL:execFromPath toURL:execToPath error:error];
    if (error && *error) {
        NSLog(@"[LC] %@", *error);
        return nil;
    }
    
    // we don't care about errors when removing unnecessary files. errors occur probably because the file does not exist
    // we remove the extension
    [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"PlugIns"] error:nil];
    // remove all sidestore stuff
    if([NSUserDefaults sideStoreExist]) {
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStoreSupport.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStore.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Intents.intentdefinition"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"ViewApp.intentdefinition"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Metadata.appintents"] error:nil];
        [infoDict removeObjectForKey:@"INIntentsSupported"];
        [infoDict removeObjectForKey:@"NSUserActivityTypes"];
    }
    
    [infoDict writeToURL:infoPath error:error];
    
    dlopen("/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore", RTLD_GLOBAL);
    NSData *zipData = [[NSClassFromString(@"PKZipArchiver") new] zippedDataForURL:tmpPayloadPath.URLByDeletingLastPathComponent];
    if (!zipData) return nil;

    [manager removeItemAtURL:tmpPayloadPath error:error];
    if (*error) return nil;
    
    if([manager fileExistsAtPath:tmpIPAPath.path]) {
        [manager removeItemAtURL:tmpIPAPath error:error];
        if (*error) return nil;
    }

    [zipData writeToURL:tmpIPAPath options:0 error:error];
    if (*error) return nil;

    return tmpIPAPath;
}

+ (NSString *)getVersionInfo {
    return [NSString stringWithFormat:@"Version %@-%@",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
            NSBundle.mainBundle.infoDictionary[@"LCVersionInfo"]];
}

+ (NSData*)bookmarkForURL:(NSURL*) url {
    return [url bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
}

+ (UIImage *)fullResolutionIconForBundlePath:(NSString *)guestAppBundlePath style:(GeneratedIconStyle)style {
    if (!guestAppBundlePath || guestAppBundlePath.length == 0) return nil;
    
    // 1. Try IconServices extraction (returns high-res SpringBoard icon)
    UIImage *icon = [UIImage generateIconForBundleURL:[NSURL fileURLWithPath:guestAppBundlePath] style:style hasBorder:NO];
    if (icon && icon.size.width > 0 && icon.size.height > 0) {
        return icon;
    }
    
    NSFileManager *manager = [NSFileManager defaultManager];
    
    // 2. Check for cached icons
    NSString *lightPath = [guestAppBundlePath stringByAppendingPathComponent:@"LCAppIconLight.png"];
    if ([manager fileExistsAtPath:lightPath]) {
        icon = [UIImage imageWithContentsOfFile:lightPath];
        if (icon) return icon;
    }
    NSString *darkPath = [guestAppBundlePath stringByAppendingPathComponent:@"LCAppIconDark.png"];
    if ([manager fileExistsAtPath:darkPath]) {
        icon = [UIImage imageWithContentsOfFile:darkPath];
        if (icon) return icon;
    }
    
    // 3. Inspect Info.plist CFBundleIcons
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:[guestAppBundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (!infoPlist) {
        NSData *pData = [NSData dataWithContentsOfFile:[guestAppBundlePath stringByAppendingPathComponent:@"Info.plist"]];
        if (pData) {
            infoPlist = [NSPropertyListSerialization propertyListWithData:pData options:0 format:nil error:nil];
        }
    }
    
    id primaryIcons = infoPlist[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
    if (!primaryIcons || ![primaryIcons isKindOfClass:[NSArray class]] || [primaryIcons count] == 0) {
        primaryIcons = infoPlist[@"CFBundleIconFiles"];
    }
    if ([primaryIcons isKindOfClass:[NSArray class]] && [primaryIcons count] > 0) {
        for (NSString *iconName in [primaryIcons reverseObjectEnumerator]) {
            NSString *candidate = [guestAppBundlePath stringByAppendingPathComponent:iconName];
            if ([manager fileExistsAtPath:candidate]) {
                icon = [UIImage imageWithContentsOfFile:candidate];
                if (icon) return icon;
            }
            for (NSString *ext in @[@"@3x.png", @"@2x.png", @".png", @"~ipad.png"]) {
                NSString *withExt = [candidate stringByAppendingString:ext];
                if ([manager fileExistsAtPath:withExt]) {
                    icon = [UIImage imageWithContentsOfFile:withExt];
                    if (icon) return icon;
                }
            }
        }
    }
    
    // 4. Fallback: search directory for icon PNGs
    NSArray<NSString *> *files = [manager contentsOfDirectoryAtPath:guestAppBundlePath error:nil];
    for (NSString *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"png"]) {
            NSString *lower = file.lowercaseString;
            if ([lower containsString:@"appicon"] || [lower containsString:@"icon"]) {
                icon = [UIImage imageWithContentsOfFile:[guestAppBundlePath stringByAppendingPathComponent:file]];
                if (icon && icon.size.width >= 60) {
                    return icon;
                }
            }
        }
    }
    
    return icon;
}

+ (NSDictionary *)generateWebClipConfigWithBundlePath:(NSString *)bundlePath
                                          containerId:(NSString *)containerId
                                         targetScheme:(NSString *)targetScheme
                                            iconStyle:(GeneratedIconStyle)iconStyle {
    if (!bundlePath || bundlePath.length == 0) return nil;
    
    if (![bundlePath isAbsolutePath]) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docPath = paths.firstObject;
        NSString *absPath = [[docPath stringByAppendingPathComponent:@"Applications"] stringByAppendingPathComponent:bundlePath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:absPath]) {
            bundlePath = absPath;
        } else {
            NSURL *groupURL = [LCSharedUtils appGroupPath];
            if (groupURL) {
                absPath = [[groupURL.path stringByAppendingPathComponent:@"LiveContainer/Applications"] stringByAppendingPathComponent:bundlePath];
                if ([[NSFileManager defaultManager] fileExistsAtPath:absPath]) {
                    bundlePath = absPath;
                }
            }
        }
    }
    
    NSString *scheme = (targetScheme && targetScheme.length > 0) ? targetScheme : [LCSharedUtils assignedContainerSchemeForApp:bundlePath];
    if (!scheme || scheme.length == 0) {
        scheme = @"livecontainer";
    }
    scheme = scheme.lowercaseString;
    if ([scheme isEqualToString:@"livecontainer1"]) {
        scheme = @"livecontainer";
    }
    
    NSString *bundleName = bundlePath.lastPathComponent;
    
    NSDictionary *guestInfoPlist = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (!guestInfoPlist) {
        NSData *pData = [NSData dataWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        if (pData) {
            guestInfoPlist = [NSPropertyListSerialization propertyListWithData:pData options:0 format:nil error:nil];
        }
    }
    NSDictionary *guestLCAppInfo = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSString *displayName = guestLCAppInfo[@"displayName"]
        ?: guestInfoPlist[@"CFBundleDisplayName"]
        ?: guestInfoPlist[@"CFBundleName"]
        ?: bundleName.stringByDeletingPathExtension;
    
    NSString *bundleIdentifier = guestInfoPlist[@"CFBundleIdentifier"]
        ?: [NSString stringWithFormat:@"com.livecontainer.%@", bundleName.stringByDeletingPathExtension];
    
    NSString *appClipUrl;
    if (containerId && containerId.length > 0) {
        appClipUrl = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", scheme, bundleName, containerId];
    } else {
        appClipUrl = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@", scheme, bundleName];
    }
    
    UIImage *icon = [self fullResolutionIconForBundlePath:bundlePath style:iconStyle];
    NSData *iconData = icon ? UIImagePNGRepresentation(icon) : nil;
    
    NSString *payloadUUID = NSUUID.UUID.UUIDString;
    NSString *profileUUID = NSUUID.UUID.UUIDString;
    NSString *webClipId = [NSString stringWithFormat:@"%@.webclip.%@", bundleIdentifier, payloadUUID];
    
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"FullScreen": @YES,
        @"IgnoreManifestScope": @YES,
        @"IsRemovable": @YES,
        @"Label": displayName,
        @"PayloadDescription": [NSString stringWithFormat:@"Web Clip for launching %@ via %@", displayName, scheme],
        @"PayloadDisplayName": displayName,
        @"PayloadIdentifier": webClipId,
        @"PayloadType": @"com.apple.webClip.managed",
        @"PayloadUUID": payloadUUID,
        @"PayloadVersion": @(1),
        @"Precomposed": @YES,
        @"PayloadOrganization": @"LiveContainer",
        @"URL": appClipUrl
    }];
    if (iconData) {
        payload[@"Icon"] = iconData;
    }
    
    return @{
        @"ConsentText": @{
            @"default": [NSString stringWithFormat:@"This profile installs a Home Screen WebClip icon for %@ that launches directly via %@.", displayName, scheme]
        },
        @"PayloadContent": @[payload],
        @"PayloadDescription": payload[@"PayloadDescription"],
        @"PayloadDisplayName": displayName,
        @"PayloadIdentifier": [NSString stringWithFormat:@"%@.profile", webClipId],
        @"PayloadOrganization": @"LiveContainer",
        @"PayloadRemovalDisallowed": @NO,
        @"PayloadType": @"Configuration",
        @"PayloadUUID": profileUUID,
        @"PayloadVersion": @(1),
    };
}

+ (NSData *)generateWebClipProfileDataWithBundlePath:(NSString *)bundlePath
                                         containerId:(NSString *)containerId
                                        targetScheme:(NSString *)targetScheme
                                           iconStyle:(GeneratedIconStyle)iconStyle {
    NSDictionary *dict = [self generateWebClipConfigWithBundlePath:bundlePath
                                                       containerId:containerId
                                                      targetScheme:targetScheme
                                                         iconStyle:iconStyle];
    if (!dict) return nil;
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (error) {
        NSLog(@"[LCUtils] Error serializing webclip profile: %@", error);
        return nil;
    }
    return data;
}

@end

@interface LCMobileConfigServer () {
    int _serverFd;
    dispatch_queue_t _serverQueue;
    UIBackgroundTaskIdentifier _bgTask;
}
@property (nonatomic, copy) NSData *currentProfileData;
@property (nonatomic, copy) NSString *currentFileName;
@property (nonatomic, copy) NSString *currentDisplayName;
@property (nonatomic, copy) NSData *currentIconData;
@end

@implementation LCMobileConfigServer

+ (instancetype)sharedServer {
    static LCMobileConfigServer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LCMobileConfigServer alloc] init];
    });
    return shared;
}

+ (instancetype)shared {
    return [self sharedServer];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverFd = -1;
        _bgTask = UIBackgroundTaskInvalid;
        _serverQueue = dispatch_queue_create("com.livecontainer.mobileconfigserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)stop {
    if (_serverFd >= 0) {
        close(_serverFd);
        _serverFd = -1;
    }
    self.currentProfileData = nil;
    self.currentFileName = nil;
    self.currentDisplayName = nil;
    self.currentIconData = nil;
    if (_bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_bgTask];
        _bgTask = UIBackgroundTaskInvalid;
    }
}

static BOOL lc_send_all(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t n = send(fd, p, remaining, 0);
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
                usleep(5000);
                continue;
            }
            return NO;
        }
        p += n;
        remaining -= (size_t)n;
    }
    return YES;
}

- (NSData *)generateLandingPageHtml {
    NSString *rawName = self.currentDisplayName ?: @"App";
    NSMutableString *escapedName = [NSMutableString string];
    for (NSUInteger i = 0; i < rawName.length; i++) {
        unichar c = [rawName characterAtIndex:i];
        if (c == '&') [escapedName appendString:@"&amp;"];
        else if (c == '<') [escapedName appendString:@"&lt;"];
        else if (c == '>') [escapedName appendString:@"&gt;"];
        else if (c == '"') [escapedName appendString:@"&quot;"];
        else [escapedName appendFormat:@"%C", c];
    }
    
    NSString *iconImgTag = @"";
    if (self.currentIconData && self.currentIconData.length > 0) {
        NSString *b64 = [self.currentIconData base64EncodedStringWithOptions:0];
        iconImgTag = [NSString stringWithFormat:@"<img src=\"data:image/png;base64,%@\" class=\"app-icon\" alt=\"%@\" />", b64, escapedName];
    } else {
        iconImgTag = @"<div class=\"app-icon placeholder\">&#x1F4F1;</div>";
    }
    
    NSString *html = [NSString stringWithFormat:
        @"<!DOCTYPE html>\n"
        @"<html lang=\"en\">\n"
        @"<head>\n"
        @"<meta charset=\"utf-8\">\n"
        @"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no\">\n"
        @"<title>Install WebClip - %@</title>\n"
        @"<style>\n"
        @"* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }\n"
        @"body {\n"
        @"  margin: 0;\n"
        @"  padding: 32px 20px 48px;\n"
        @"  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif;\n"
        @"  background-color: #f2f2f7;\n"
        @"  color: #1c1c1e;\n"
        @"  display: flex;\n"
        @"  flex-direction: column;\n"
        @"  align-items: center;\n"
        @"  min-height: 100vh;\n"
        @"  text-align: center;\n"
        @"}\n"
        @"@media (prefers-color-scheme: dark) {\n"
        @"  body { background-color: #000000; color: #f2f2f7; }\n"
        @"  .card { background-color: #1c1c1e !important; box-shadow: 0 4px 24px rgba(0,0,0,0.6) !important; }\n"
        @"  .step { background-color: #2c2c2e !important; color: #f2f2f7 !important; }\n"
        @"  .secondary-btn { background-color: #2c2c2e !important; color: #0a84ff !important; }\n"
        @"}\n"
        @".card {\n"
        @"  background: #ffffff;\n"
        @"  border-radius: 26px;\n"
        @"  padding: 32px 24px;\n"
        @"  max-width: 380px;\n"
        @"  width: 100%%;\n"
        @"  box-shadow: 0 10px 35px rgba(0,0,0,0.08);\n"
        @"  display: flex;\n"
        @"  flex-direction: column;\n"
        @"  align-items: center;\n"
        @"}\n"
        @".app-icon {\n"
        @"  width: 96px;\n"
        @"  height: 96px;\n"
        @"  border-radius: 22px;\n"
        @"  box-shadow: 0 6px 20px rgba(0,0,0,0.18);\n"
        @"  margin-bottom: 16px;\n"
        @"  object-fit: cover;\n"
        @"}\n"
        @".placeholder {\n"
        @"  background: linear-gradient(135deg, #007aff, #5856d6);\n"
        @"  display: flex;\n"
        @"  align-items: center;\n"
        @"  justify-content: center;\n"
        @"  font-size: 42px;\n"
        @"  color: #fff;\n"
        @"}\n"
        @"h1 {\n"
        @"  font-size: 22px;\n"
        @"  font-weight: 700;\n"
        @"  margin: 0 0 6px;\n"
        @"}\n"
        @".badge {\n"
        @"  font-size: 13px;\n"
        @"  font-weight: 600;\n"
        @"  color: #007aff;\n"
        @"  background: rgba(0, 122, 255, 0.12);\n"
        @"  padding: 4px 12px;\n"
        @"  border-radius: 12px;\n"
        @"  margin-bottom: 22px;\n"
        @"  display: inline-block;\n"
        @"}\n"
        @".primary-btn {\n"
        @"  display: block;\n"
        @"  width: 100%%;\n"
        @"  padding: 16px 20px;\n"
        @"  background: #007aff;\n"
        @"  color: #ffffff !important;\n"
        @"  font-size: 17px;\n"
        @"  font-weight: 600;\n"
        @"  border-radius: 14px;\n"
        @"  text-decoration: none;\n"
        @"  margin-bottom: 12px;\n"
        @"  box-shadow: 0 4px 14px rgba(0, 122, 255, 0.35);\n"
        @"  transition: transform 0.1s, background-color 0.2s;\n"
        @"}\n"
        @".primary-btn:active { transform: scale(0.98); background-color: #0062cc; }\n"
        @".secondary-btn {\n"
        @"  display: block;\n"
        @"  width: 100%%;\n"
        @"  padding: 13px 20px;\n"
        @"  background: #e5e5ea;\n"
        @"  color: #007aff;\n"
        @"  font-size: 15px;\n"
        @"  font-weight: 600;\n"
        @"  border-radius: 14px;\n"
        @"  text-decoration: none;\n"
        @"  margin-bottom: 22px;\n"
        @"}\n"
        @".steps-box {\n"
        @"  width: 100%%;\n"
        @"  text-align: left;\n"
        @"  margin-top: 6px;\n"
        @"}\n"
        @".step {\n"
        @"  background: #f8f8fa;\n"
        @"  border-radius: 12px;\n"
        @"  padding: 12px 14px;\n"
        @"  margin-bottom: 8px;\n"
        @"  font-size: 13.5px;\n"
        @"  line-height: 1.45;\n"
        @"}\n"
        @".step strong { color: #007aff; }\n"
        @"</style>\n"
        @"</head>\n"
        @"<body>\n"
        @"<div class=\"card\">\n"
        @"  %@\n"
        @"  <h1>%@</h1>\n"
        @"  <div class=\"badge\">Instant WebClip Profile</div>\n"
        @"  <a id=\"install-btn\" href=\"/download\" class=\"primary-btn\">Install WebClip Profile</a>\n"
        @"  <a href=\"App-prefs:General&path=ManagedConfigurationList\" class=\"secondary-btn\">Open Settings App</a>\n"
        @"  <div class=\"steps-box\">\n"
        @"    <div class=\"step\"><strong>1. Tap 'Install WebClip Profile'</strong> above, then tap <strong>Allow</strong> on the system prompt.</div>\n"
        @"    <div class=\"step\"><strong>2. Open Settings</strong> &gt; <em>Profile Downloaded</em> at the top, then tap <strong>Install</strong>.</div>\n"
        @"  </div>\n"
        @"</div>\n"
        @"<script>\n"
        @"window.addEventListener('DOMContentLoaded', function() {\n"
        @"  setTimeout(function() {\n"
        @"    var btn = document.getElementById('install-btn');\n"
        @"    if (btn) btn.click();\n"
        @"  }, 350);\n"
        @"});\n"
        @"</script>\n"
        @"</body>\n"
        @"</html>\n",
        escapedName, iconImgTag, escapedName];
        
    return [html dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSURL *)serveProfileData:(NSData *)profileData
                   fileName:(NSString *)fileName
                displayName:(NSString *)displayName
                   iconData:(NSData *)iconData {
    [self stop];
    
    if (!profileData || profileData.length == 0) {
        return nil;
    }
    
    signal(SIGPIPE, SIG_IGN);
    
    _bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"LCMobileConfigServer" expirationHandler:^{
        [self stop];
    }];
    
    self.currentProfileData = profileData;
    self.currentFileName = fileName ?: @"profile.mobileconfig";
    self.currentDisplayName = displayName ?: @"App";
    self.currentIconData = iconData;
    
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[LCMobileConfigServer] socket() failed: %s", strerror(errno));
        [self stop];
        return nil;
    }
    
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
#endif
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(0);
    
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[LCMobileConfigServer] bind() failed: %s", strerror(errno));
        close(fd);
        [self stop];
        return nil;
    }
    
    socklen_t addrLen = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &addrLen) < 0) {
        NSLog(@"[LCMobileConfigServer] getsockname() failed: %s", strerror(errno));
        close(fd);
        [self stop];
        return nil;
    }
    
    uint16_t port = ntohs(addr.sin_port);
    if (listen(fd, 16) < 0) {
        NSLog(@"[LCMobileConfigServer] listen() failed: %s", strerror(errno));
        close(fd);
        [self stop];
        return nil;
    }
    
    _serverFd = fd;
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(_serverQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_serverFd < 0) return;
        
        int sfd = strongSelf->_serverFd;
        NSDate *expiry = [NSDate dateWithTimeIntervalSinceNow:120.0];
        while ([expiry timeIntervalSinceNow] > 0 && strongSelf && strongSelf->_serverFd >= 0) {
            struct pollfd pfd;
            pfd.fd = sfd;
            pfd.events = POLLIN;
            int ready = poll(&pfd, 1, 1000);
            if (ready <= 0 || !(pfd.revents & POLLIN)) {
                continue;
            }
            
            struct sockaddr_in clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            int clientFd = accept(sfd, (struct sockaddr *)&clientAddr, &clientLen);
            if (clientFd < 0) {
                continue;
            }
            
#ifdef SO_NOSIGPIPE
            int nosigpipe = 1;
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
#endif
            struct timeval tv;
            tv.tv_sec = 3;
            tv.tv_usec = 0;
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            
            char reqBuf[4096] = {0};
            ssize_t n = recv(clientFd, reqBuf, sizeof(reqBuf) - 1, 0);
            if (n <= 0) {
                close(clientFd);
                continue;
            }
            
            char method[16] = {0};
            char reqPath[512] = {0};
            sscanf(reqBuf, "%15s %511s", method, reqPath);
            BOOL isHead = (strcasecmp(method, "HEAD") == 0);
            
            NSString *pathStr = [NSString stringWithUTF8String:reqPath] ?: @"/";
            if ([pathStr containsString:@"?"]) {
                pathStr = [pathStr componentsSeparatedByString:@"?"].firstObject;
            }
            
            if ([pathStr isEqualToString:@"/favicon.ico"]) {
                const char *resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";
                lc_send_all(clientFd, resp, strlen(resp));
            } else if ([pathStr isEqualToString:@"/apple-touch-icon.png"] || [pathStr isEqualToString:@"/apple-touch-icon-precomposed.png"] || [pathStr isEqualToString:@"/icon.png"]) {
                if (strongSelf.currentIconData && strongSelf.currentIconData.length > 0) {
                    NSString *header = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: image/png\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Connection: close\r\n\r\n",
                        (unsigned long)strongSelf.currentIconData.length];
                    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
                    lc_send_all(clientFd, headerData.bytes, headerData.length);
                    if (!isHead) {
                        lc_send_all(clientFd, strongSelf.currentIconData.bytes, strongSelf.currentIconData.length);
                    }
                } else {
                    const char *resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    lc_send_all(clientFd, resp, strlen(resp));
                }
            } else if ([pathStr hasPrefix:@"/download"] || [pathStr hasSuffix:@".mobileconfig"]) {
                NSData *data = strongSelf.currentProfileData;
                NSString *rawName = strongSelf.currentFileName ?: @"profile.mobileconfig";
                
                NSMutableString *asciiSafe = [NSMutableString string];
                for (NSUInteger i = 0; i < rawName.length; i++) {
                    unichar c = [rawName characterAtIndex:i];
                    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
                        [asciiSafe appendFormat:@"%C", c];
                    } else {
                        [asciiSafe appendString:@"_"];
                    }
                }
                if (asciiSafe.length == 0 || [asciiSafe isEqualToString:@".mobileconfig"]) {
                    asciiSafe = [NSMutableString stringWithString:@"profile.mobileconfig"];
                }
                
                NSString *header = [NSString stringWithFormat:
                    @"HTTP/1.1 200 OK\r\n"
                    @"Content-Type: application/x-apple-aspen-config\r\n"
                    @"Content-Disposition: attachment; filename=\"%@\"\r\n"
                    @"Content-Length: %lu\r\n"
                    @"Cache-Control: no-cache, no-store, must-revalidate\r\n"
                    @"Pragma: no-cache\r\n"
                    @"Expires: 0\r\n"
                    @"Connection: close\r\n\r\n",
                    asciiSafe, (unsigned long)data.length];
                
                NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
                lc_send_all(clientFd, headerData.bytes, headerData.length);
                if (!isHead && data.length > 0) {
                    lc_send_all(clientFd, data.bytes, data.length);
                }
            } else {
                NSData *htmlData = [strongSelf generateLandingPageHtml];
                NSString *header = [NSString stringWithFormat:
                    @"HTTP/1.1 200 OK\r\n"
                    @"Content-Type: text/html; charset=utf-8\r\n"
                    @"Content-Length: %lu\r\n"
                    @"Cache-Control: no-cache, no-store, must-revalidate\r\n"
                    @"Connection: close\r\n\r\n",
                    (unsigned long)htmlData.length];
                
                NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
                lc_send_all(clientFd, headerData.bytes, headerData.length);
                if (!isHead && htmlData.length > 0) {
                    lc_send_all(clientFd, htmlData.bytes, htmlData.length);
                }
            }
            
            shutdown(clientFd, SHUT_WR);
            char drain[256];
            while (recv(clientFd, drain, sizeof(drain), 0) > 0) {}
            close(clientFd);
        }
        
        [strongSelf stop];
    });
    
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/", port]];
}

- (NSURL *)serveProfileData:(NSData *)profileData fileName:(NSString *)fileName {
    return [self serveProfileData:profileData fileName:fileName displayName:nil iconData:nil];
}

@end
