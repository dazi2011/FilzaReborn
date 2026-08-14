#import "MHADeviceCatalog.h"
#import "MCMFilzaIntegration.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// Minimal declarations from jkcoxson/idevice's MIT-licensed C FFI. The linked
// archive is vendored under vendor/idevice; no StikDebug application code is
// copied into this project.
typedef void *plist_t;
typedef struct AdapterHandle AdapterHandle;
typedef struct RsdHandshakeHandle RsdHandshakeHandle;
typedef struct RpPairingFileHandle RpPairingFileHandle;
typedef struct IdevicePairingFile IdevicePairingFile;
typedef struct IdeviceProviderHandle IdeviceProviderHandle;
typedef struct InstallationProxyClientHandle InstallationProxyClientHandle;
typedef struct SpringBoardServicesClientHandle SpringBoardServicesClientHandle;
typedef struct IdeviceFfiError {
    int32_t code;
    int32_t sub_code;
    const char *message;
} IdeviceFfiError;

extern IdeviceFfiError *rp_pairing_file_read(const char *,
    RpPairingFileHandle **);
extern void rp_pairing_file_free(RpPairingFileHandle *);
extern IdeviceFfiError *idevice_pairing_file_read(const char *,
    IdevicePairingFile **);
extern void idevice_pairing_file_free(IdevicePairingFile *);
extern IdeviceFfiError *idevice_tcp_provider_new(const struct sockaddr *,
    IdevicePairingFile *, const char *, IdeviceProviderHandle **);
extern void idevice_provider_free(IdeviceProviderHandle *);
extern IdeviceFfiError *tunnel_create_rppairing(const struct sockaddr *,
    socklen_t, const char *, RpPairingFileHandle *, const char *(*)(void *),
    void *, AdapterHandle **, RsdHandshakeHandle **);
extern void adapter_free(AdapterHandle *);
extern void rsd_handshake_free(RsdHandshakeHandle *);
extern IdeviceFfiError *installation_proxy_connect_rsd(AdapterHandle *,
    RsdHandshakeHandle *, InstallationProxyClientHandle **);
extern IdeviceFfiError *installation_proxy_connect(IdeviceProviderHandle *,
    InstallationProxyClientHandle **);
extern IdeviceFfiError *installation_proxy_get_apps(
    InstallationProxyClientHandle *, const char *, const char *const *, size_t,
    void **, size_t *);
extern IdeviceFfiError *installation_proxy_browse(
    InstallationProxyClientHandle *, plist_t, plist_t **, size_t *);
extern void installation_proxy_client_free(InstallationProxyClientHandle *);
extern IdeviceFfiError *springboard_services_connect_rsd(AdapterHandle *,
    RsdHandshakeHandle *, SpringBoardServicesClientHandle **);
extern IdeviceFfiError *springboard_services_connect(IdeviceProviderHandle *,
    SpringBoardServicesClientHandle **);
extern IdeviceFfiError *springboard_services_get_icon(
    SpringBoardServicesClientHandle *, const char *, void **, size_t *);
extern void springboard_services_free(SpringBoardServicesClientHandle *);
extern void idevice_error_free(IdeviceFfiError *);
extern void idevice_data_free(uint8_t *, uintptr_t);
extern plist_t plist_new_dict(void);
extern plist_t plist_new_array(void);
extern plist_t plist_new_string(const char *);
extern void plist_array_append_item(plist_t, plist_t);
extern void plist_dict_set_item(plist_t, const char *, plist_t);
extern int plist_to_bin(plist_t, char **, uint32_t *);
extern void plist_mem_free(void *);
extern void plist_free(plist_t);

NSNotificationName const MHADeviceCatalogDidRefreshNotification =
    @"MHADeviceCatalogDidRefreshNotification";
NSNotificationName const MHADeviceCatalogDidChangeNotification =
    @"MHADeviceCatalogDidChangeNotification";

static NSString * const kTargetIPAddress = @"10.7.0.1";
static const uint16_t kRemotePairingPort = 49152;
static const uint16_t kLockdownPort = 62078;
static const NSTimeInterval kRetryCooldown = 3.0;
static uint16_t gDiagnosticTargetPort = 49152;
static NSString *gDiagnosticTransport = @"RemotePairing/RSD";

static NSObject *catalogLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static dispatch_queue_t catalogQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("local.research.mcm.rsd-catalog",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSDictionary<NSString *, NSDictionary *> *gCatalogRecords = nil;
static NSString *gCatalogStatus = @"cache not loaded";
static BOOL gCatalogRefreshing = NO;
static NSDate *gLastCatalogAttempt = nil;

static NSString *documentsRoot(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
        NSUserDomainMask, YES).firstObject;
}

static NSString *cacheDirectory(void) {
    return [documentsRoot() stringByAppendingPathComponent:
        @"App Manager Cache"];
}

static NSString *iconsDirectory(void) {
    return [cacheDirectory() stringByAppendingPathComponent:@"Icons"];
}

static NSString *catalogPath(void) {
    return [cacheDirectory() stringByAppendingPathComponent:
        @"Applications.plist"];
}

static NSString *safeIconFileName(NSString *bundleIdentifier) {
    NSMutableCharacterSet *allowed =
        NSCharacterSet.alphanumericCharacterSet.mutableCopy;
    [allowed addCharactersInString:@".-_"];
    NSString *safe = [[bundleIdentifier
        componentsSeparatedByCharactersInSet:allowed.invertedSet]
        componentsJoinedByString:@"_"];
    return safe.length > 0 ? [safe stringByAppendingPathExtension:@"png"] : nil;
}

static void ensureCacheDirectories(void) {
    NSDictionary *attributes = @{NSFilePosixPermissions: @0700};
    [NSFileManager.defaultManager createDirectoryAtPath:iconsDirectory()
        withIntermediateDirectories:YES attributes:attributes error:nil];
    [NSFileManager.defaultManager setAttributes:attributes
        ofItemAtPath:cacheDirectory() error:nil];
    [NSFileManager.defaultManager setAttributes:attributes
        ofItemAtPath:iconsDirectory() error:nil];
}

static NSArray<NSURL *> *pairingFileCandidates(void) {
    NSString *documents = documentsRoot();
    NSArray<NSString *> *preferredNames = @[
        @"pairingFile.plist", @"rp_pairing_file.plist"
    ];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^appendCandidate)(NSURL *) = ^(NSURL *candidate) {
        if (!candidate || [seen containsObject:candidate.path]) return;
        BOOL isDirectory = NO;
        if (![manager fileExistsAtPath:candidate.path
                           isDirectory:&isDirectory] || isDirectory)
            return;
        [seen addObject:candidate.path];
        [candidates addObject:candidate];
    };
    for (NSString *name in preferredNames) {
        NSString *path = [documents stringByAppendingPathComponent:name];
        appendCandidate([NSURL fileURLWithPath:path]);
    }

    NSArray<NSURL *> *contents = [manager contentsOfDirectoryAtURL:
        [NSURL fileURLWithPath:documents] includingPropertiesForKeys:nil
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for (NSURL *candidate in contents) {
        NSString *extension = candidate.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"mobiledevicepairing"] ||
            [extension isEqualToString:@"mobiledevicepair"])
            appendCandidate(candidate);
    }
    // Users frequently retain the UDID-based filename produced by their
    // pairing utility. If no preferred name matches, let the FFI parser decide
    // which Documents-root plist is a real remote-pairing record.
    for (NSURL *candidate in contents) {
        if ([candidate.pathExtension.lowercaseString isEqualToString:@"plist"])
            appendCandidate(candidate);
    }
    return candidates.copy;
}

static NSString *pairingCandidateSummary(void) {
    NSArray<NSURL *> *candidates = pairingFileCandidates();
    if (candidates.count == 0) return @"(none)";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSURL *candidate in candidates) {
        NSDictionary *attributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:candidate.path error:nil];
        [lines addObject:[NSString stringWithFormat:@"%@ (%@ bytes, readable=%@)",
            candidate.lastPathComponent,
            attributes[NSFileSize] ?: @0,
            [NSFileManager.defaultManager isReadableFileAtPath:candidate.path]
                ? @"yes" : @"no"]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *firstString(NSDictionary *dictionary,
                             NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *string = [(NSString *)value
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (string.length > 0) return string;
    }
    return nil;
}

static NSNumber *nonnegativeDiskUsage(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if ([(NSNumber *)value longLongValue] < 0) return nil;
    return @([(NSNumber *)value unsignedLongLongValue]);
}

static NSDictionary *sanitizedRecord(NSDictionary *dictionary) {
    NSString *identifier = firstString(dictionary,
        @[@"CFBundleIdentifier", @"BundleIdentifier"]);
    if (identifier.length == 0) return nil;
    NSString *name = firstString(dictionary,
        @[@"CFBundleDisplayName", @"CFBundleName", @"DisplayName", @"Name"]);
    NSString *shortVersion = firstString(dictionary,
        @[@"CFBundleShortVersionString", @"ShortVersionString"]);
    NSString *bundleVersion = firstString(dictionary,
        @[@"CFBundleVersion", @"BundleVersion"]);
    NSString *applicationType = firstString(dictionary,
        @[@"ApplicationType"]);
    NSNumber *staticDiskUsage = nonnegativeDiskUsage(
        dictionary[@"StaticDiskUsage"]);
    NSNumber *dynamicDiskUsage = nonnegativeDiskUsage(
        dictionary[@"DynamicDiskUsage"]);

    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObject:
        identifier forKey:@"BundleIdentifier"];
    if (name.length > 0) record[@"Name"] = name;
    if (shortVersion.length > 0) record[@"ShortVersion"] = shortVersion;
    if (bundleVersion.length > 0) record[@"BundleVersion"] = bundleVersion;
    if (applicationType.length > 0)
        record[@"ApplicationType"] = applicationType;
    if (staticDiskUsage) record[@"StaticDiskUsage"] = staticDiskUsage;
    if (dynamicDiskUsage) record[@"DynamicDiskUsage"] = dynamicDiskUsage;
    return record;
}

static NSString *consumeError(IdeviceFfiError *error, NSString *fallback) {
    if (!error) return nil;
    NSString *message = error->message
        ? [NSString stringWithUTF8String:error->message] : nil;
    NSString *result = [NSString stringWithFormat:@"%@ (code=%d sub=%d)",
        message.length > 0 ? message : fallback, error->code, error->sub_code];
    idevice_error_free(error);
    return result;
}

static NSDictionary *foundationDictionaryFromPlist(plist_t plist) {
    if (!plist) return nil;
    char *bytes = NULL;
    uint32_t length = 0;
    if (plist_to_bin(plist, &bytes, &length) != 0 || !bytes || length == 0) {
        if (bytes) plist_mem_free(bytes);
        return nil;
    }
    NSData *data = [NSData dataWithBytes:bytes length:length];
    plist_mem_free(bytes);
    id value = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void writeDiagnostics(NSString *status, NSURL *pairingURL,
                             NSUInteger records, NSUInteger iconsWritten,
                             NSUInteger iconsCached, NSUInteger iconFailures) {
    NSString *report = [NSString stringWithFormat:
        @"App Manager RSD catalogue diagnostics\n\n"
         "Build marker: AppManager-CachedDiskUsage-NoFreeze-v20\n"
         "Updated: %@\n"
         "Target: %@:%u\n"
         "Transport: %@\n"
         "Documents root: %@\n"
         "Selected pairing file: %@\n"
         "Pairing candidates:\n%@\n"
         "Status: %@\n"
         "Application records: %lu\n"
         "Icons written: %lu\n"
         "Icons reused from cache: %lu\n"
         "Icon failures: %lu\n"
         "Cache: %@\n\n"
         "Names, bundle identifiers, versions, disk usage, and icons come from the device's "
         "installation_proxy and SpringBoardServices through the selected transport. "
         "No .app directory is scanned.\n",
        [NSDate date], kTargetIPAddress, gDiagnosticTargetPort,
        gDiagnosticTransport, documentsRoot(),
        pairingURL.lastPathComponent ?: @"(not selected)",
        pairingCandidateSummary(),
        status ?: @"unknown", (unsigned long)records,
        (unsigned long)iconsWritten, (unsigned long)iconsCached,
        (unsigned long)iconFailures, catalogPath()];
    NSArray<NSString *> *paths = @[
        [documentsRoot() stringByAppendingPathComponent:
            @"App Manager RSD Diagnostics.txt"],
        [MCMFilzaVirtualRoot() stringByAppendingPathComponent:
            @"App Manager RSD Diagnostics.txt"]
    ];
    for (NSString *path in paths)
        [report writeToFile:path atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
}

static void updateStage(NSString *status, NSURL *pairingURL,
                        NSUInteger records, NSUInteger iconsWritten,
                        NSUInteger iconsCached, NSUInteger iconFailures) {
    @synchronized (catalogLock()) { gCatalogStatus = status.copy; }
    writeDiagnostics(status, pairingURL, records, iconsWritten, iconsCached,
        iconFailures);
    NSLog(@"[MHA-APPMGR-RSD] %@", status);
}

void MHADeviceCatalogLoadCache(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ensureCacheDirectories();
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:
            catalogPath()];
        NSDictionary *records = [root[@"Applications"]
            isKindOfClass:NSDictionary.class] ? root[@"Applications"] : @{};
        @synchronized (catalogLock()) {
            gCatalogRecords = records.copy;
            gCatalogStatus = records.count > 0
                ? [NSString stringWithFormat:@"loaded %lu cached records",
                    (unsigned long)records.count]
                : @"no cached catalogue";
        }
    });
}

NSArray<NSString *> *MHADeviceCatalogIdentifiers(void) {
    MHADeviceCatalogLoadCache();
    @synchronized (catalogLock()) {
        return [gCatalogRecords.allKeys
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    }
}

NSDictionary *MHADeviceCatalogMetadata(NSString *bundleIdentifier) {
    MHADeviceCatalogLoadCache();
    @synchronized (catalogLock()) {
        return gCatalogRecords[bundleIdentifier];
    }
}

NSString *MHADeviceCatalogDisplayName(NSString *bundleIdentifier) {
    return MHADeviceCatalogMetadata(bundleIdentifier)[@"Name"];
}

NSString *MHADeviceCatalogVersion(NSString *bundleIdentifier) {
    NSDictionary *record = MHADeviceCatalogMetadata(bundleIdentifier);
    return record[@"ShortVersion"] ?: record[@"BundleVersion"];
}

NSString *MHADeviceCatalogApplicationType(NSString *bundleIdentifier) {
    return MHADeviceCatalogMetadata(bundleIdentifier)[@"ApplicationType"];
}

NSNumber *MHADeviceCatalogStaticDiskUsage(NSString *bundleIdentifier) {
    return nonnegativeDiskUsage(
        MHADeviceCatalogMetadata(bundleIdentifier)[@"StaticDiskUsage"]);
}

NSNumber *MHADeviceCatalogDynamicDiskUsage(NSString *bundleIdentifier) {
    return nonnegativeDiskUsage(
        MHADeviceCatalogMetadata(bundleIdentifier)[@"DynamicDiskUsage"]);
}

NSNumber *MHADeviceCatalogTotalDiskUsage(NSString *bundleIdentifier) {
    NSNumber *staticUsage = MHADeviceCatalogStaticDiskUsage(bundleIdentifier);
    NSNumber *dynamicUsage = MHADeviceCatalogDynamicDiskUsage(bundleIdentifier);
    if (!staticUsage || !dynamicUsage) return nil;
    unsigned long long staticBytes = staticUsage.unsignedLongLongValue;
    unsigned long long dynamicBytes = dynamicUsage.unsignedLongLongValue;
    if (ULLONG_MAX - staticBytes < dynamicBytes) return nil;
    return @(staticBytes + dynamicBytes);
}

NSString *MHADeviceCatalogIconPath(NSString *bundleIdentifier) {
    NSString *fileName = safeIconFileName(bundleIdentifier);
    if (fileName.length == 0) return nil;
    NSString *path = [iconsDirectory() stringByAppendingPathComponent:fileName];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}

NSString *MHADeviceCatalogStatus(void) {
    MHADeviceCatalogLoadCache();
    @synchronized (catalogLock()) { return gCatalogStatus.copy; }
}

static NSString *diskUsageValue(NSNumber *value) {
    return value ? value.stringValue : @"unavailable";
}

static void writeDiskUsageDiagnostics(NSString *status,
                                      NSDictionary *records,
                                      NSDictionary<NSString *, NSString *> *states) {
    NSArray<NSString *> *identifiers = [records.allKeys
        sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSUInteger complete = 0, preserved = 0, unavailable = 0;
    NSMutableString *details = [NSMutableString string];
    for (NSString *identifier in identifiers) {
        NSDictionary *record = [records[identifier]
            isKindOfClass:NSDictionary.class] ? records[identifier] : @{};
        NSNumber *staticUsage = nonnegativeDiskUsage(record[@"StaticDiskUsage"]);
        NSNumber *dynamicUsage = nonnegativeDiskUsage(record[@"DynamicDiskUsage"]);
        NSNumber *totalUsage = nil;
        if (staticUsage && dynamicUsage) {
            unsigned long long staticBytes = staticUsage.unsignedLongLongValue;
            unsigned long long dynamicBytes = dynamicUsage.unsignedLongLongValue;
            if (ULLONG_MAX - staticBytes >= dynamicBytes)
                totalUsage = @(staticBytes + dynamicBytes);
        }
        NSString *state = states[identifier];
        if (state.length == 0)
            state = totalUsage ? @"cached after refresh failure" : @"unavailable";
        if ([state hasPrefix:@"fresh"])
            complete++;
        else if ([state containsString:@"preserved"] ||
                 [state hasPrefix:@"cached"])
            preserved++;
        else
            unavailable++;
        [details appendFormat:
            @"%@\tstatus=%@\tstatic=%@\tdynamic=%@\ttotal=%@\n",
            identifier, state, diskUsageValue(staticUsage),
            diskUsageValue(dynamicUsage), diskUsageValue(totalUsage)];
    }

    NSString *report = [NSString stringWithFormat:
        @"App Manager disk usage diagnostics\n\n"
         "Build marker: AppManager-CachedDiskUsage-NoFreeze-v20\n"
         "Updated: %@\n"
         "Target: %@:%u\n"
         "Transport: %@\n"
         "Status: %@\n"
         "Applications: %lu\n"
         "Fresh complete sizes: %lu\n"
         "Preserved cached sizes: %lu\n"
         "Unavailable or incomplete sizes: %lu\n"
         "Cache: %@\n\n"
         "Each total is StaticDiskUsage + DynamicDiskUsage. Missing fields are never replaced with guessed values.\n\n%@",
        [NSDate date], kTargetIPAddress, gDiagnosticTargetPort,
        gDiagnosticTransport, status ?: @"unknown",
        (unsigned long)identifiers.count, (unsigned long)complete,
        (unsigned long)preserved, (unsigned long)unavailable,
        catalogPath(), details];
    NSString *path = [MCMFilzaVirtualRoot() stringByAppendingPathComponent:
        @"App Manager Disk Usage Diagnostics.txt"];
    [report writeToFile:path atomically:YES
        encoding:NSUTF8StringEncoding error:nil];
}

static NSString *loadFirstValidPairingFile(
        NSArray<NSURL *> *candidates, RpPairingFileHandle **outRemotePairing,
        IdevicePairingFile **outLockdownPairing,
        NSURL * __autoreleasing *outURL, BOOL *outUsesLockdown) {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (NSURL *candidate in candidates) {
        RpPairingFileHandle *remoteHandle = NULL;
        IdeviceFfiError *remoteError = rp_pairing_file_read(
            candidate.fileSystemRepresentation, &remoteHandle);
        if (!remoteError && remoteHandle) {
            *outRemotePairing = remoteHandle;
            *outURL = candidate;
            *outUsesLockdown = NO;
            return nil;
        }
        NSString *remoteDetail = remoteError
            ? consumeError(remoteError, @"RemotePairing parser rejected file")
            : @"RemotePairing parser returned no handle";
        if (remoteHandle) rp_pairing_file_free(remoteHandle);

        IdevicePairingFile *lockdownHandle = NULL;
        IdeviceFfiError *lockdownError = idevice_pairing_file_read(
            candidate.fileSystemRepresentation, &lockdownHandle);
        if (!lockdownError && lockdownHandle) {
            *outLockdownPairing = lockdownHandle;
            *outURL = candidate;
            *outUsesLockdown = YES;
            return nil;
        }
        NSString *lockdownDetail = lockdownError
            ? consumeError(lockdownError, @"Lockdown parser rejected file")
            : @"Lockdown parser returned no handle";
        if (lockdownHandle) idevice_pairing_file_free(lockdownHandle);
        [errors addObject:[NSString stringWithFormat:
            @"%@: RemotePairing={%@}; Lockdown={%@}",
            candidate.lastPathComponent, remoteDetail, lockdownDetail]];
    }
    return [NSString stringWithFormat:
        @"no Documents-root pairing candidate was accepted by either parser: %@",
        errors.count > 0 ? [errors componentsJoinedByString:@" | "]
                         : @"no candidate files"];
}

static NSString *socketError(NSString *prefix, int errorNumber) {
    const char *message = strerror(errorNumber);
    return [NSString stringWithFormat:@"%@: %s (errno=%d)", prefix,
        message ?: "unknown", errorNumber];
}

static NSString *preflightLocalDevVPNEndpoint(uint16_t targetPort) {
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) return socketError(@"socket failed", errno);

    NSString *failure = nil;
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        failure = socketError(@"failed to configure nonblocking socket", errno);
        goto cleanup;
    }

    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(targetPort);
    if (inet_pton(AF_INET, kTargetIPAddress.UTF8String,
                  &address.sin_addr) != 1) {
        failure = @"invalid LocalDevVPN target address";
        goto cleanup;
    }

    if (connect(descriptor, (const struct sockaddr *)&address,
                (socklen_t)sizeof(address)) != 0) {
        int connectError = errno;
        if (connectError != EINPROGRESS) {
            failure = socketError(@"LocalDevVPN endpoint connect failed",
                connectError);
            goto cleanup;
        }
        struct pollfd pollDescriptor = {
            .fd = descriptor,
            .events = POLLOUT,
            .revents = 0
        };
        int pollResult = poll(&pollDescriptor, 1, 5000);
        if (pollResult == 0) {
            failure = @"LocalDevVPN endpoint timed out after 5 seconds";
            goto cleanup;
        }
        if (pollResult < 0) {
            failure = socketError(@"LocalDevVPN endpoint poll failed", errno);
            goto cleanup;
        }
        int socketStatus = 0;
        socklen_t statusLength = sizeof(socketStatus);
        if (getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketStatus,
                       &statusLength) != 0) {
            failure = socketError(@"LocalDevVPN endpoint status failed", errno);
            goto cleanup;
        }
        if (socketStatus != 0) {
            failure = socketError(@"LocalDevVPN endpoint rejected connection",
                socketStatus);
            goto cleanup;
        }
    }

cleanup:
    close(descriptor);
    return failure;
}

static BOOL writeCatalog(NSDictionary *records, NSURL *pairingURL,
                         NSString **failure) {
    ensureCacheDirectories();
    NSDictionary *root = @{
        @"FormatVersion": @2,
        @"RefreshedAt": [NSDate date],
        @"Target": [NSString stringWithFormat:@"%@:%u", kTargetIPAddress,
            gDiagnosticTargetPort],
        @"Transport": gDiagnosticTransport,
        @"PairingFile": pairingURL.lastPathComponent ?: @"(unknown)",
        @"Applications": records
    };
    if (![root writeToFile:catalogPath() atomically:YES]) {
        if (failure) *failure = @"failed to write Applications.plist cache";
        return NO;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600}
        ofItemAtPath:catalogPath() error:nil];
    @synchronized (catalogLock()) { gCatalogRecords = records.copy; }
    return YES;
}

static NSString *performRefresh(NSArray<NSURL *> *pairingCandidates,
                                NSURL * __autoreleasing *selectedPairingURL,
                                NSUInteger *recordCount,
                                NSUInteger *writtenCount,
                                NSUInteger *cachedCount,
                                NSUInteger *failureCount,
                                BOOL *catalogChanged,
                                NSString * __autoreleasing *warning) {
    RpPairingFileHandle *remotePairing = NULL;
    IdevicePairingFile *lockdownPairing = NULL;
    IdeviceProviderHandle *provider = NULL;
    AdapterHandle *adapter = NULL;
    RsdHandshakeHandle *handshake = NULL;
    InstallationProxyClientHandle *installation = NULL;
    SpringBoardServicesClientHandle *springBoard = NULL;
    void *rawApps = NULL;
    size_t rawAppCount = 0;
    NSString *failure = nil;
    NSString *diskQueryFailure = nil;
    NSURL *pairingURL = nil;
    BOOL usesLockdown = NO;
    NSDictionary *oldRecords = nil;
    NSMutableDictionary<NSString *, NSDictionary *> *newRecords =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *diskStates =
        [NSMutableDictionary dictionary];

    @synchronized (catalogLock()) {
        oldRecords = gCatalogRecords.copy ?: @{};
    }

    updateStage(@"stage 1/6: reading pairing file", nil, 0, 0, 0, 0);
    failure = loadFirstValidPairingFile(pairingCandidates, &remotePairing,
        &lockdownPairing, &pairingURL, &usesLockdown);
    if (failure.length > 0) {
        goto cleanup;
    }
    *selectedPairingURL = pairingURL;
    gDiagnosticTargetPort = usesLockdown
        ? kLockdownPort : kRemotePairingPort;
    gDiagnosticTransport = usesLockdown
        ? @"Lockdown TCP provider" : @"RemotePairing/RSD";
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600}
        ofItemAtPath:pairingURL.path error:nil];

    updateStage(@"stage 2/6: testing LocalDevVPN endpoint", pairingURL,
        0, 0, 0, 0);
    failure = preflightLocalDevVPNEndpoint(gDiagnosticTargetPort);
    if (failure.length > 0) goto cleanup;

    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(gDiagnosticTargetPort);
    if (inet_pton(AF_INET, kTargetIPAddress.UTF8String,
                  &address.sin_addr) != 1) {
        failure = @"invalid LocalDevVPN target address";
        goto cleanup;
    }

    updateStage(usesLockdown
        ? @"stage 3/6: creating Lockdown TCP provider"
        : @"stage 3/6: creating RSD pairing tunnel", pairingURL,
        0, 0, 0, 0);
    IdeviceFfiError *error = usesLockdown
        ? idevice_tcp_provider_new((const struct sockaddr *)&address,
            lockdownPairing, "Filza", &provider)
        : tunnel_create_rppairing((const struct sockaddr *)&address,
            (socklen_t)sizeof(address), "Filza", remotePairing, NULL, NULL,
            &adapter, &handshake);
    if (error) {
        failure = consumeError(error, usesLockdown
            ? @"failed to create Lockdown TCP provider"
            : @"failed to create RSD tunnel");
        goto cleanup;
    }
    if (usesLockdown) lockdownPairing = NULL; // consumed by provider

    updateStage(@"stage 4/6: connecting installation_proxy", pairingURL,
        0, 0, 0, 0);
    error = usesLockdown
        ? installation_proxy_connect(provider, &installation)
        : installation_proxy_connect_rsd(adapter, handshake, &installation);
    if (error) {
        failure = consumeError(error, @"failed to connect installation_proxy");
        goto cleanup;
    }
    static const char *const requestedAttributes[] = {
        "CFBundleIdentifier",
        "CFBundleDisplayName",
        "CFBundleName",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "ApplicationType",
        "StaticDiskUsage",
        "DynamicDiskUsage"
    };
    plist_t browseOptions = plist_new_dict();
    plist_t returnAttributes = plist_new_array();
    if (browseOptions && returnAttributes) {
        plist_dict_set_item(browseOptions, "ApplicationType",
            plist_new_string("Any"));
        for (size_t index = 0;
             index < sizeof(requestedAttributes) /
                 sizeof(requestedAttributes[0]); index++) {
            plist_array_append_item(returnAttributes,
                plist_new_string(requestedAttributes[index]));
        }
        plist_dict_set_item(browseOptions, "ReturnAttributes",
            returnAttributes);
        returnAttributes = NULL; // owned by browseOptions
        error = installation_proxy_browse(installation, browseOptions,
            (plist_t **)&rawApps, &rawAppCount);
    } else {
        error = NULL;
        diskQueryFailure = @"failed to allocate installation_proxy Browse options";
    }
    if (returnAttributes) plist_free(returnAttributes);
    if (browseOptions) plist_free(browseOptions);

    if (error || diskQueryFailure.length > 0 || rawAppCount == 0) {
        if (error) {
            diskQueryFailure = consumeError(error,
                @"disk-usage Browse query failed");
        } else if (diskQueryFailure.length == 0) {
            diskQueryFailure = @"disk-usage Browse query returned no applications";
        }
        if (rawApps) {
            plist_t *appsToFree = (plist_t *)rawApps;
            for (size_t index = 0; index < rawAppCount; index++)
                plist_free(appsToFree[index]);
            idevice_data_free((uint8_t *)rawApps,
                rawAppCount * sizeof(plist_t));
        }
        rawApps = NULL;
        rawAppCount = 0;
        error = installation_proxy_get_apps(installation, NULL, NULL, 0,
            &rawApps, &rawAppCount);
        if (error) {
            NSString *fallbackFailure = consumeError(error,
                @"fallback application enumeration failed");
            failure = [NSString stringWithFormat:@"%@; %@",
                diskQueryFailure, fallbackFailure];
            goto cleanup;
        }
    }

    plist_t *apps = (plist_t *)rawApps;
    for (size_t index = 0; index < rawAppCount; index++) {
        NSDictionary *dictionary = foundationDictionaryFromPlist(apps[index]);
        NSDictionary *record = sanitizedRecord(dictionary);
        NSString *identifier = record[@"BundleIdentifier"];
        if (identifier.length > 0) newRecords[identifier] = record;
    }
    if (newRecords.count == 0) {
        failure = @"installation_proxy returned no usable application records";
        goto cleanup;
    }

    for (NSString *identifier in newRecords.allKeys.copy) {
        NSDictionary *freshRecord = newRecords[identifier];
        NSDictionary *oldRecord = [oldRecords[identifier]
            isKindOfClass:NSDictionary.class] ? oldRecords[identifier] : @{};
        BOOL hasFreshStatic = [freshRecord[@"StaticDiskUsage"]
            isKindOfClass:NSNumber.class];
        BOOL hasFreshDynamic = [freshRecord[@"DynamicDiskUsage"]
            isKindOfClass:NSNumber.class];
        NSMutableDictionary *mergedRecord = freshRecord.mutableCopy;
        BOOL preservedStatic = NO, preservedDynamic = NO;
        if (!hasFreshStatic && [oldRecord[@"StaticDiskUsage"]
                isKindOfClass:NSNumber.class]) {
            mergedRecord[@"StaticDiskUsage"] = oldRecord[@"StaticDiskUsage"];
            preservedStatic = YES;
        }
        if (!hasFreshDynamic && [oldRecord[@"DynamicDiskUsage"]
                isKindOfClass:NSNumber.class]) {
            mergedRecord[@"DynamicDiskUsage"] = oldRecord[@"DynamicDiskUsage"];
            preservedDynamic = YES;
        }
        newRecords[identifier] = mergedRecord.copy;

        BOOL hasCompleteSize = [mergedRecord[@"StaticDiskUsage"]
                isKindOfClass:NSNumber.class] &&
            [mergedRecord[@"DynamicDiskUsage"] isKindOfClass:NSNumber.class];
        if (hasFreshStatic && hasFreshDynamic) {
            diskStates[identifier] = @"fresh";
        } else if (hasCompleteSize && (preservedStatic || preservedDynamic)) {
            diskStates[identifier] = @"preserved missing response field(s)";
        } else {
            NSMutableArray<NSString *> *missing = [NSMutableArray array];
            if (![mergedRecord[@"StaticDiskUsage"] isKindOfClass:NSNumber.class])
                [missing addObject:@"StaticDiskUsage"];
            if (![mergedRecord[@"DynamicDiskUsage"] isKindOfClass:NSNumber.class])
                [missing addObject:@"DynamicDiskUsage"];
            diskStates[identifier] = [NSString stringWithFormat:
                @"unavailable missing %@", [missing componentsJoinedByString:@","]];
        }
    }

    *recordCount = newRecords.count;
    *catalogChanged = ![oldRecords isEqualToDictionary:newRecords];
    if (*catalogChanged) {
        if (!writeCatalog(newRecords, pairingURL, &failure)) goto cleanup;
        NSSet *currentIdentifiers = [NSSet setWithArray:newRecords.allKeys];
        for (NSString *removedIdentifier in oldRecords) {
            if ([currentIdentifiers containsObject:removedIdentifier]) continue;
            NSString *fileName = safeIconFileName(removedIdentifier);
            if (fileName.length > 0)
                [NSFileManager.defaultManager removeItemAtPath:
                    [iconsDirectory() stringByAppendingPathComponent:fileName]
                    error:nil];
        }
        updateStage([NSString stringWithFormat:
            @"stage 5/6: metadata cache updated (%lu applications)",
            (unsigned long)newRecords.count], pairingURL, newRecords.count,
            0, 0, 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:
                MHADeviceCatalogDidChangeNotification object:nil];
        });
    } else {
        updateStage([NSString stringWithFormat:
            @"stage 5/6: catalogue unchanged; preserved existing cache (%lu applications)",
            (unsigned long)newRecords.count], pairingURL, newRecords.count,
            0, 0, 0);
    }

    writeDiskUsageDiagnostics(diskQueryFailure.length > 0
        ? [@"catalogue fallback succeeded; disk query failed: "
            stringByAppendingString:diskQueryFailure]
        : @"complete: installation_proxy application and disk-usage query",
        newRecords, diskStates);

    BOOL needsIconRefresh = NO;
    for (NSString *identifier in newRecords) {
        NSString *iconPath = MHADeviceCatalogIconPath(identifier);
        NSString *oldVersion = oldRecords[identifier][@"BundleVersion"];
        NSString *newVersion = newRecords[identifier][@"BundleVersion"];
        if (iconPath.length == 0 || oldVersion.length == 0 ||
            ![oldVersion isEqualToString:newVersion]) {
            needsIconRefresh = YES;
            break;
        }
    }
    if (!needsIconRefresh) {
        *cachedCount = newRecords.count;
        goto cleanup;
    }

    error = usesLockdown
        ? springboard_services_connect(provider, &springBoard)
        : springboard_services_connect_rsd(adapter, handshake, &springBoard);
    if (error) {
        // Metadata is still useful if the icon service is unavailable.
        NSString *iconFailure = consumeError(error,
            @"failed to connect SpringBoardServices");
        if (warning) *warning = iconFailure;
        springBoard = NULL;
    }

    NSUInteger processedIcons = 0;
    for (NSString *identifier in newRecords) {
        processedIcons++;
        NSString *iconPath = MHADeviceCatalogIconPath(identifier);
        NSString *oldVersion = oldRecords[identifier][@"BundleVersion"];
        NSString *newVersion = newRecords[identifier][@"BundleVersion"];
        BOOL versionUnchanged = oldVersion.length > 0 &&
            [oldVersion isEqualToString:newVersion];
        if (iconPath.length > 0 && versionUnchanged) {
            (*cachedCount)++;
            continue;
        }
        if (!springBoard) {
            (*failureCount)++;
            continue;
        }

        void *iconBytes = NULL;
        size_t iconLength = 0;
        error = springboard_services_get_icon(springBoard,
            identifier.UTF8String, &iconBytes, &iconLength);
        if (error) {
            consumeError(error, @"icon request failed");
            (*failureCount)++;
            continue;
        }
        NSData *iconData = iconBytes && iconLength > 0
            ? [NSData dataWithBytes:iconBytes length:iconLength] : nil;
        if (iconBytes) free(iconBytes);
        NSString *fileName = safeIconFileName(identifier);
        NSString *destination = fileName.length > 0
            ? [iconsDirectory() stringByAppendingPathComponent:fileName] : nil;
        if (iconData.length > 0 && destination.length > 0 &&
            [iconData writeToFile:destination options:NSDataWritingAtomic
                error:nil]) {
            (*writtenCount)++;
        } else {
            (*failureCount)++;
        }
        if (processedIcons % 25 == 0) {
            updateStage([NSString stringWithFormat:
                @"stage 6/6: fetching icons (%lu/%lu)",
                (unsigned long)processedIcons,
                (unsigned long)newRecords.count], pairingURL,
                newRecords.count, *writtenCount, *cachedCount,
                *failureCount);
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:
                    MHADeviceCatalogDidRefreshNotification object:nil];
            });
        }
    }

cleanup:
    if (failure.length > 0) {
        writeDiskUsageDiagnostics(
            [@"failed; preserved previous cache: " stringByAppendingString:
                failure], oldRecords ?: @{}, nil);
    }
    if (springBoard) springboard_services_free(springBoard);
    if (rawApps) {
        plist_t *appsToFree = (plist_t *)rawApps;
        for (size_t index = 0; index < rawAppCount; index++)
            plist_free(appsToFree[index]);
        idevice_data_free((uint8_t *)rawApps,
            rawAppCount * sizeof(plist_t));
    }
    if (installation) installation_proxy_client_free(installation);
    if (handshake) rsd_handshake_free(handshake);
    if (adapter) adapter_free(adapter);
    if (provider) idevice_provider_free(provider);
    if (remotePairing) rp_pairing_file_free(remotePairing);
    if (lockdownPairing) idevice_pairing_file_free(lockdownPairing);
    return failure;
}

void MHADeviceCatalogScheduleRefresh(void) {
    MHADeviceCatalogLoadCache();
    NSArray<NSURL *> *pairingCandidates = pairingFileCandidates();
    if (pairingCandidates.count == 0) {
        updateStage(@"waiting: no pairing candidate found in Documents",
            nil, MHADeviceCatalogIdentifiers().count, 0, 0, 0);
        return;
    }

    @synchronized (catalogLock()) {
        if (gCatalogRefreshing) return;
        if (gLastCatalogAttempt &&
            -gLastCatalogAttempt.timeIntervalSinceNow < kRetryCooldown)
            return;
        gLastCatalogAttempt = [NSDate date];
        gCatalogRefreshing = YES;
        gCatalogStatus = @"queued: LocalDevVPN application catalogue refresh";
    }
    writeDiagnostics(@"queued: LocalDevVPN application catalogue refresh",
        pairingCandidates.firstObject, MHADeviceCatalogIdentifiers().count,
        0, 0, 0);

    dispatch_async(catalogQueue(), ^{
        NSUInteger records = 0, written = 0, cached = 0, failures = 0;
        NSURL *selectedPairingURL = nil;
        BOOL catalogChanged = NO;
        NSString *warning = nil;
        NSString *error = performRefresh(pairingCandidates,
            &selectedPairingURL, &records, &written, &cached, &failures,
            &catalogChanged, &warning);
        NSString *status = error.length > 0
            ? [@"failed: " stringByAppendingString:error]
            : [NSString stringWithFormat:@"complete: %lu applications (%@)",
                (unsigned long)records,
                catalogChanged ? @"catalogue updated" : @"catalogue unchanged"];
        if (!error && warning.length > 0)
            status = [status stringByAppendingFormat:@"; icon service: %@",
                warning];
        @synchronized (catalogLock()) {
            gCatalogRefreshing = NO;
            gCatalogStatus = status;
        }
        writeDiagnostics(status, selectedPairingURL, records, written, cached,
            failures);
        NSLog(@"[MHA-APPMGR-RSD] %@ icons-written=%lu cached=%lu failed=%lu",
            status, (unsigned long)written, (unsigned long)cached,
            (unsigned long)failures);
        if (written > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:
                    MHADeviceCatalogDidRefreshNotification object:nil];
            });
        }
    });
}
