#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MHADeviceCatalogDidRefreshNotification;
FOUNDATION_EXPORT NSNotificationName const MHADeviceCatalogDidChangeNotification;

// Loads the last successful RSD catalogue from the app's Documents directory.
// These accessors never connect to the device and are safe on Filza's UI thread.
FOUNDATION_EXPORT void MHADeviceCatalogLoadCache(void);
FOUNDATION_EXPORT NSArray<NSString *> *MHADeviceCatalogIdentifiers(void);
FOUNDATION_EXPORT NSDictionary * _Nullable MHADeviceCatalogMetadata(
    NSString *bundleIdentifier);
FOUNDATION_EXPORT NSString * _Nullable MHADeviceCatalogDisplayName(
    NSString *bundleIdentifier);
FOUNDATION_EXPORT NSString * _Nullable MHADeviceCatalogVersion(
    NSString *bundleIdentifier);
FOUNDATION_EXPORT NSString * _Nullable MHADeviceCatalogApplicationType(
    NSString *bundleIdentifier);
FOUNDATION_EXPORT NSString * _Nullable MHADeviceCatalogIconPath(
    NSString *bundleIdentifier);
FOUNDATION_EXPORT NSString *MHADeviceCatalogStatus(void);

// If a supported pairing file is present at the Documents root, starts one
// serialized background refresh through LocalDevVPN (10.7.0.1:49152).
FOUNDATION_EXPORT void MHADeviceCatalogScheduleRefresh(void);

NS_ASSUME_NONNULL_END
