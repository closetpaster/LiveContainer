@import Foundation;

NS_ASSUME_NONNULL_BEGIN

@interface LCSharedUtils : NSObject
+ (nullable NSString *)teamIdentifier;
+ (NSString *)appGroupID;
+ (NSURL *)appGroupPath;
+ (nullable NSString *)certificatePassword;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode;
+ (BOOL)launchToGuestAppWithURL:(NSURL *)url;
+ (void)setWebPageUrlForNextLaunch:(nullable NSString *)urlString;
+ (BOOL)isLCSchemeInUse:(NSString *)lc;
+ (nullable NSString *)getContainerUsingLCSchemeWithFolderName:(NSString *)folderName;
+ (void)setContainerUsingByLC:(NSString *)lc folderName:(nullable NSString *)folderName auditToken:(uint64_t)val57;
+ (void)moveSharedAppFolderBack;
+ (nullable NSBundle *)findBundleWithBundleId:(NSString *)bundleId isSharedAppOut:(nullable bool *)isSharedAppOut;
+ (void)dumpPreferenceToPath:(NSString *)plistLocationTo dataUUID:(NSString *)dataUUID;
+ (nullable NSString *)findDefaultContainerWithBundleId:(NSString *)bundleId;
+ (NSArray<NSString *> *)lcUnorderedUrlSchemes;
+ (NSArray<NSString *> *)lcUrlSchemes;
+ (nullable NSString *)assignedContainerSchemeForApp:(nullable NSString *)bundlePathOrId;
+ (nullable NSString *)assignedAppForContainerScheme:(nullable NSString *)scheme;
+ (void)assignApp:(nullable NSString *)bundlePathOrId toContainerScheme:(nullable NSString *)targetScheme containerFolderName:(nullable NSString *)containerFolderName;
@end

NS_ASSUME_NONNULL_END
