@import Foundation;

@interface LCSharedUtils : NSObject
+ (NSString*) teamIdentifier;
+ (NSString *)appGroupID;
+ (NSURL*) appGroupPath;
+ (NSString *)certificatePassword;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode;
+ (BOOL)launchToGuestAppWithURL:(NSURL *)url;
+ (void)setWebPageUrlForNextLaunch:(NSString*)urlString;
+ (BOOL)isLCSchemeInUse:(NSString*)lc;
+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName;
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57;
+ (void)moveSharedAppFolderBack;
+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut;
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID;
+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId;
+ (NSArray<NSString*>*)lcUnorderedUrlSchemes;
+ (NSArray<NSString*>*)lcUrlSchemes;
+ (NSString * _Nullable)assignedContainerSchemeForApp:(NSString * _Nullable)bundlePathOrId;
+ (NSString * _Nullable)assignedAppForContainerScheme:(NSString * _Nullable)scheme;
+ (void)assignApp:(NSString * _Nullable)bundlePathOrId toContainerScheme:(NSString * _Nullable)targetScheme containerFolderName:(NSString * _Nullable)containerFolderName;
+ (void)returnToLiveContainerUI;
@end
