@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import <xpc/xpc.h>

#include <errno.h>
#include <dlfcn.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "MCMFilzaIntegration.h"
#include "MHADeviceCatalog.h"
#include "PosterBoardFeature.h"

#pragma mark - Root Helper Hooks

static BOOL hook_isRootHelperAvailable(id self, SEL _cmd) {
    return NO;
}

static int hook_spawnRootHelper(id self, SEL _cmd) { return 0; }
static int hook_spawnRootHelperIfNeeds(id self, SEL _cmd) { return 0; }
static int hook_respawnRootHelper(id self, SEL _cmd) { return 0; }
static void hook_tryLoadFilzaHelper(id self, SEL _cmd) {}
static void hook_createHelperConnectionIfNeeds(id self, SEL _cmd) {}

// A jailed Filza otherwise restores its usual /var/mobile start path, which is
// not listable by this container-scoped primitive. Start directly in the MCM
// virtual root after ensuring it has been populated.
static id hook_defaultPath(id self, SEL _cmd) {
    MCMFilzaStart();
    return MCMFilzaVirtualRoot();
}

static NSString *filzaDeviceStorageTrashPath(void) {
    NSString *deviceStorage = MCMFilzaVirtualRoot();
    if (!deviceStorage.length) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!documents.length)
            documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        deviceStorage = [documents stringByAppendingPathComponent:@"Device Storage"];
    }
    return [deviceStorage stringByAppendingPathComponent:@".Trash"];
}

static id hook_trashDir(id self, SEL _cmd) {
    return filzaDeviceStorageTrashPath();
}

static NSString *filzaPreviousDocumentsTrashPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length)
        documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [documents stringByAppendingPathComponent:@".Trash"];
}

static void migrateTrashDirectory(NSFileManager *manager, NSString *source,
                                  NSString *destination) {
    BOOL sourceIsDirectory = NO;
    if (![manager fileExistsAtPath:source isDirectory:&sourceIsDirectory] ||
        !sourceIsDirectory) return;

    BOOL destinationIsDirectory = NO;
    BOOL destinationExists = [manager fileExistsAtPath:destination
                                            isDirectory:&destinationIsDirectory];
    NSError *migrationError = nil;
    if (!destinationExists) {
        if ([manager moveItemAtPath:source toPath:destination
                              error:&migrationError]) {
            NSLog(@"[Trash] migrated %@ -> %@", source, destination);
            return;
        }
    } else if (destinationIsDirectory) {
        for (NSString *name in [manager contentsOfDirectoryAtPath:source
                                                             error:&migrationError] ?: @[]) {
            NSString *sourceItem = [source stringByAppendingPathComponent:name];
            NSString *destinationItem = [destination stringByAppendingPathComponent:name];
            if ([manager fileExistsAtPath:destinationItem]) {
                NSLog(@"[Trash] kept migration collision at %@", sourceItem);
                continue;
            }
            NSError *moveError = nil;
            if (![manager moveItemAtPath:sourceItem toPath:destinationItem
                                   error:&moveError])
                NSLog(@"[Trash] item migration failed %@: %@", sourceItem, moveError);
        }
        if ([manager contentsOfDirectoryAtPath:source error:nil].count == 0)
            [manager removeItemAtPath:source error:nil];
    }

    if (migrationError)
        NSLog(@"[Trash] migration failed %@ -> %@: %@",
              source, destination, migrationError);
}

static void prepareFilzaDeviceStorageTrash(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *destination = filzaDeviceStorageTrashPath();
        NSString *migrationKey = @"FilzaRebornMigratedTrashToDeviceStorageV2";

        NSError *parentError = nil;
        if (![manager createDirectoryAtPath:destination.stringByDeletingLastPathComponent
                withIntermediateDirectories:YES
                                 attributes:@{NSFilePosixPermissions: @0700}
                                      error:&parentError])
            NSLog(@"[Trash] could not prepare parent for %@: %@",
                  destination, parentError);

        if (![defaults boolForKey:migrationKey]) {
            migrateTrashDirectory(manager, filzaPreviousDocumentsTrashPath(), destination);
            migrateTrashDirectory(manager, @"/var/mobile/Library/Filza/.Trash", destination);
            [defaults setBool:YES forKey:migrationKey];
        }

        NSError *directoryError = nil;
        if (![manager createDirectoryAtPath:destination
                withIntermediateDirectories:YES
                                 attributes:@{NSFilePosixPermissions: @0700}
                                      error:&directoryError])
            NSLog(@"[Trash] could not prepare %@: %@", destination, directoryError);
        else
            NSLog(@"[Trash] using %@", destination);
    });
}

static IMP orig_preferencesFavoritedLinks = NULL;

static void redirectDefaultTrashFavorite(id preferences, id value) {
    if (![value isKindOfClass:NSMutableArray.class]) return;

    NSMutableArray *links = value;
    NSString *destination = filzaDeviceStorageTrashPath();
    NSString *previous = filzaPreviousDocumentsTrashPath();
    BOOL changed = NO;
    for (NSUInteger index = 0; index < links.count; index++) {
        NSDictionary *link = [links[index] isKindOfClass:NSDictionary.class]
            ? links[index] : nil;
        NSString *path = [link[@"path"] isKindOfClass:NSString.class]
            ? link[@"path"] : nil;
        BOOL isSystemTrash = [link[@"system"] boolValue] &&
            [link[@"icon"] isEqual:@"trash"];
        BOOL usesOldTrashPath = [path isEqualToString:previous] ||
            [path isEqualToString:@"/var/mobile/Library/Filza/.Trash"];
        if ((!isSystemTrash && !usesOldTrashPath) ||
            [path isEqualToString:destination]) continue;

        NSMutableDictionary *updated = [link mutableCopy];
        updated[@"path"] = destination;
        links[index] = updated;
        changed = YES;
    }

    if (!changed) return;
    SEL saveSelector = NSSelectorFromString(@"saveFavoritedLinks");
    if ([preferences respondsToSelector:saveSelector])
        ((void(*)(id, SEL))objc_msgSend)(preferences, saveSelector);
    NSLog(@"[Trash] redirected default favorite to %@", destination);
}

static id hook_preferencesFavoritedLinks(id self, SEL _cmd) {
    id links = orig_preferencesFavoritedLinks
        ? ((id(*)(id, SEL))orig_preferencesFavoritedLinks)(self, _cmd) : nil;
    redirectDefaultTrashFavorite(self, links);
    return links;
}

static NSString *redirectedLegacyBrowserPath(id requestedPath) {
    NSString *path = [requestedPath isKindOfClass:NSString.class] ? requestedPath : nil;
    NSRange legacy = [path rangeOfString:@"/Documents/MCM Containers"];
    if (legacy.location != NSNotFound) {
        NSUInteger suffixStart = NSMaxRange(legacy);
        NSString *suffix = suffixStart < path.length ? [path substringFromIndex:suffixStart] : @"";
        path = [MCMFilzaVirtualRoot() stringByAppendingString:suffix];
    }
    return path;
}

static IMP orig_fileSystemSetCurrentPath = NULL;
static IMP orig_fileSystemUpdateEditableUI = NULL;
static void refreshWallpaperButton(id controller, id fallbackPath) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    SEL selector = NSSelectorFromString(@"currentPath");
    NSString *currentPath = [controller respondsToSelector:selector]
        ? ((id(*)(id, SEL))objc_msgSend)(controller, selector) : nil;
    PBWallpaperConfigureBrowser((UIViewController *)controller,
        currentPath ?: fallbackPath);
}

static void hook_fileSystemUpdateEditableUI(id self, SEL _cmd) {
    ((void(*)(id, SEL))orig_fileSystemUpdateEditableUI)(self, _cmd);
    // This is the exact Filza routine that restores the Edit item. Apply the
    // Wallpaper Lab action after Filza has completed that update.
    refreshWallpaperButton(self, nil);
}

static void hook_fileSystemSetCurrentPath(id self, SEL _cmd, id requestedPath) {
    NSString *path = redirectedLegacyBrowserPath(requestedPath);
    if (path && ![path isEqual:requestedPath])
        NSLog(@"[DeviceStorage] redirected legacy browser path to %@", path);
    ((void(*)(id, SEL, id))orig_fileSystemSetCurrentPath)(self, _cmd, path ?: requestedPath);
    refreshWallpaperButton(self, path ?: requestedPath);
    // Filza rebuilds its Edit item after loading a directory. Re-apply the
    // lab action after those deferred navigation updates have completed.
    for (NSNumber *delay in @[@100, @500]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            delay.unsignedLongLongValue * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                refreshWallpaperButton(self, path ?: requestedPath);
            });
    }
}

static IMP orig_fileSystemViewWillAppear = NULL;
static BOOL gNormalizedInitialBrowserPath = NO;
static void hook_fileSystemViewWillAppear(id self, SEL _cmd, BOOL animated) {
    NSString *currentPath = [self respondsToSelector:NSSelectorFromString(@"currentPath")]
        ? ((id(*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"currentPath")) : nil;
    NSString *redirected = redirectedLegacyBrowserPath(currentPath);
    NSString *root = MCMFilzaVirtualRoot();
    BOOL firstAppearance = !gNormalizedInitialBrowserPath;
    gNormalizedInitialBrowserPath = YES;
    BOOL insideRoot = [currentPath isEqualToString:root] ||
        [currentPath hasPrefix:[root stringByAppendingString:@"/"]];
    if (firstAppearance && currentPath.length > 0 && !insideRoot)
        redirected = root;
    if (redirected && ![redirected isEqual:currentPath]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setCurrentPath:"), redirected);
        NSLog(@"[DeviceStorage] repaired initial browser path from %@ to %@",
            currentPath, redirected);
    }
    ((void(*)(id, SEL, BOOL))orig_fileSystemViewWillAppear)(self, _cmd, animated);

    if (firstAppearance && currentPath.length == 0) {
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setCurrentPath:"), root);
        NSLog(@"[DeviceStorage] initialized empty browser path to %@", root);
    }

    // Older Filza state restoration can preserve the navigation title even
    // after the path has been repaired, so replace that presentation-only
    // residue as well.
    UINavigationItem *item = [self respondsToSelector:@selector(navigationItem)]
        ? ((id(*)(id, SEL))objc_msgSend)(self, @selector(navigationItem)) : nil;
    if ([item.title isEqualToString:@"MCM Containers"])
        item.title = @"Device Storage";

    SEL visiblePathSelector = NSSelectorFromString(@"currentPath");
    NSString *visiblePath = [self respondsToSelector:visiblePathSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(self, visiblePathSelector) : redirected;
    PBWallpaperConfigureBrowser(self, visiblePath);

    // State restoration can leave the browser's table model empty even after
    // its path is correct. Reload on the next main-loop turn, after the view
    // hierarchy and browser view have finished appearing.
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL currentSelector = NSSelectorFromString(@"currentPath");
        NSString *visiblePath = [self respondsToSelector:currentSelector]
            ? ((id(*)(id, SEL))objc_msgSend)(self, currentSelector) : nil;
        NSString *visibleRoot = MCMFilzaVirtualRoot();
        BOOL visibleInsideRoot = [visiblePath isEqualToString:visibleRoot] ||
            [visiblePath hasPrefix:[visibleRoot stringByAppendingString:@"/"]];
        SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
        if (visibleInsideRoot && [self respondsToSelector:loadSelector]) {
            ((void(*)(id, SEL))objc_msgSend)(self, loadSelector);
            NSLog(@"[DeviceStorage] reloaded visible browser path %@", visiblePath);
        }
    });
}

static int hook_spawnRoot_args_pid(id self, SEL _cmd, id path, id args, int *pid) {
    if (pid) *pid = 0;
    return -1;
}

static id hook_sendObjectWithReplySync(id self, SEL _cmd, id msg) {
    return (id)xpc_null_create();
}

static id hook_sendObjectWithReplySync_fd(id self, SEL _cmd, id msg, int *fd) {
    if (fd) *fd = -1;
    return (id)xpc_null_create();
}

static id hook_sendObjectWithReplySync_fd_logintty(id self, SEL _cmd, id msg, int *fd, BOOL logintty) {
    if (fd) *fd = -1;
    return (id)xpc_null_create();
}

static void hook_sendObjectNoReply(id self, SEL _cmd, id msg) {}

static void hook_sendObjectWithReplyAsync(id self, SEL _cmd, id msg, id queue, id completion) {
    if (completion) { void (^block)(id) = completion; block(nil); }
}

#pragma mark - In-process ZIP support

// The SDK ships libarchive as a public dylib but does not ship its headers.
// Keep the small ABI surface used here local instead of depending on a host
// package-manager header path.
struct archive;
struct archive_entry;
typedef int64_t filza_la_int64_t;
typedef ssize_t filza_la_ssize_t;

extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_add_passphrase(struct archive *, const char *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern filza_la_ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_data_block(struct archive *, const void **, size_t *,
    filza_la_int64_t *);
extern int archive_read_data_skip(struct archive *);
extern int archive_read_close(struct archive *);
extern int archive_read_free(struct archive *);

extern struct archive *archive_write_new(void);
extern int archive_write_add_filter_none(struct archive *);
extern int archive_write_set_format_zip(struct archive *);
extern int archive_write_open_filename(struct archive *, const char *);
extern int archive_write_header(struct archive *, struct archive_entry *);
extern filza_la_ssize_t archive_write_data(struct archive *, const void *,
    size_t);
extern filza_la_ssize_t archive_write_data_block(struct archive *, const void *,
    size_t, filza_la_int64_t);
extern int archive_write_finish_entry(struct archive *);
extern int archive_write_close(struct archive *);
extern int archive_write_free(struct archive *);
extern struct archive *archive_write_disk_new(void);
extern int archive_write_disk_set_options(struct archive *, int);
extern int archive_write_disk_set_standard_lookup(struct archive *);
extern const char *archive_error_string(struct archive *);

extern struct archive_entry *archive_entry_new(void);
extern void archive_entry_free(struct archive_entry *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern const char *archive_entry_hardlink_utf8(struct archive_entry *);
extern const char *archive_entry_symlink_utf8(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern void archive_entry_set_pathname_utf8(struct archive_entry *,
    const char *);
extern void archive_entry_set_filetype(struct archive_entry *, unsigned int);
extern void archive_entry_set_perm(struct archive_entry *, mode_t);
extern void archive_entry_set_size(struct archive_entry *, filza_la_int64_t);
extern void archive_entry_set_mtime(struct archive_entry *, time_t, long);
extern void archive_entry_set_symlink_utf8(struct archive_entry *,
    const char *);

enum {
    FILZA_ARCHIVE_EOF = 1,
    FILZA_ARCHIVE_OK = 0,
    FILZA_ARCHIVE_WARN = -20,
    FILZA_ARCHIVE_EXTRACT_PERM = 0x0002,
    FILZA_ARCHIVE_EXTRACT_TIME = 0x0004,
    FILZA_ARCHIVE_EXTRACT_SECURE_SYMLINKS = 0x0100,
    FILZA_ARCHIVE_EXTRACT_SECURE_NODOTDOT = 0x0200,
    FILZA_ARCHIVE_EXTRACT_SAFE_WRITES = 0x40000,
};

static IMP orig_ZipFiles = NULL;
static IMP orig_unZipFile = NULL;
static IMP orig_unZipFilePassword = NULL;
static IMP orig_dataInZipFilePath = NULL;
static IMP orig_dataInZipFile = NULL;

static NSString *filzaArchiveObjectPath(id object) {
    if ([object isKindOfClass:NSString.class]) return object;
    if ([object isKindOfClass:NSURL.class]) return [object path];
    for (NSString *name in @[@"filePath", @"path"]) {
        SEL selector = NSSelectorFromString(name);
        if ([object respondsToSelector:selector]) {
            id value = ((id(*)(id, SEL))objc_msgSend)(object, selector);
            if ([value isKindOfClass:NSString.class]) return value;
            if ([value isKindOfClass:NSURL.class]) return [value path];
        }
    }
    return nil;
}

static NSString *filzaArchiveResolvedPath(id object, id baseObject) {
    NSString *path = filzaArchiveObjectPath(object);
    if (path.length == 0) return nil;
    if (!path.isAbsolutePath) {
        NSString *base = filzaArchiveObjectPath(baseObject);
        if (base.length > 0)
            path = [base stringByAppendingPathComponent:path];
    }
    return path.stringByStandardizingPath;
}

static NSString *filzaArchiveError(struct archive *archive,
                                   NSString *fallback) {
    const char *message = archive ? archive_error_string(archive) : NULL;
    NSString *detail = message ? [NSString stringWithUTF8String:message] : nil;
    return detail.length > 0 ? detail : fallback;
}

static id filzaFileItemAtPath(NSString *path) {
    Class fileItemClass = NSClassFromString(@"FileItem");
    if (!fileItemClass || path.length == 0) return nil;
    id item = [[fileItemClass alloc] init];
    SEL setter = NSSelectorFromString(@"setFilePath:attribute:");
    if (![item respondsToSelector:setter]) return nil;
    ((void(*)(id, SEL, id, id))objc_msgSend)(item, setter, path, nil);
    return item;
}

static BOOL filzaWriteArchiveEntry(struct archive *writer,
                                   NSString *sourcePath,
                                   NSString *archivePath,
                                   NSString *outputPath,
                                   NSString **errorMessage) {
    if ([sourcePath isEqualToString:outputPath]) return YES;

    struct stat status;
    if (lstat(sourcePath.fileSystemRepresentation, &status) != 0) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:
            @"Cannot read %@: %s", sourcePath.lastPathComponent,
            strerror(errno)];
        return NO;
    }

    struct archive_entry *entry = archive_entry_new();
    if (!entry) {
        if (errorMessage) *errorMessage = @"Cannot allocate ZIP entry";
        return NO;
    }

    NSString *entryPath = archivePath;
    if (S_ISDIR(status.st_mode) && ![entryPath hasSuffix:@"/"])
        entryPath = [entryPath stringByAppendingString:@"/"];
    archive_entry_set_pathname_utf8(entry, entryPath.UTF8String);
    archive_entry_set_perm(entry, status.st_mode & 07777);
    archive_entry_set_mtime(entry, status.st_mtimespec.tv_sec,
        status.st_mtimespec.tv_nsec);

    BOOL supported = YES;
    if (S_ISREG(status.st_mode)) {
        archive_entry_set_filetype(entry, S_IFREG);
        archive_entry_set_size(entry, status.st_size);
    } else if (S_ISDIR(status.st_mode)) {
        archive_entry_set_filetype(entry, S_IFDIR);
        archive_entry_set_size(entry, 0);
    } else if (S_ISLNK(status.st_mode)) {
        char target[PATH_MAX + 1];
        ssize_t length = readlink(sourcePath.fileSystemRepresentation, target,
            PATH_MAX);
        if (length < 0 || length >= PATH_MAX) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:
                @"Cannot read symbolic link %@: %s", archivePath,
                strerror(errno)];
            archive_entry_free(entry);
            return NO;
        }
        target[length] = '\0';
        archive_entry_set_filetype(entry, S_IFLNK);
        archive_entry_set_size(entry, 0);
        archive_entry_set_symlink_utf8(entry, target);
    } else {
        supported = NO;
    }

    if (!supported) {
        archive_entry_free(entry);
        NSLog(@"[ZIP] skipped unsupported file type at %@", sourcePath);
        return YES;
    }

    int result = archive_write_header(writer, entry);
    if (result < FILZA_ARCHIVE_WARN) {
        if (errorMessage) *errorMessage = filzaArchiveError(writer,
            @"Cannot write ZIP entry");
        archive_entry_free(entry);
        return NO;
    }

    if (S_ISREG(status.st_mode)) {
        int descriptor = open(sourcePath.fileSystemRepresentation,
            O_RDONLY | O_NOFOLLOW);
        if (descriptor < 0) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:
                @"Cannot open %@: %s", archivePath, strerror(errno)];
            archive_entry_free(entry);
            return NO;
        }

        uint8_t buffer[64 * 1024];
        ssize_t count;
        BOOL writeSucceeded = YES;
        while ((count = read(descriptor, buffer, sizeof(buffer))) > 0) {
            size_t offset = 0;
            while (offset < (size_t)count) {
                filza_la_ssize_t written = archive_write_data(writer,
                    buffer + offset, (size_t)count - offset);
                if (written <= 0) {
                    if (errorMessage) *errorMessage = filzaArchiveError(writer,
                        @"Cannot write ZIP file data");
                    writeSucceeded = NO;
                    break;
                }
                offset += (size_t)written;
            }
            if (!writeSucceeded) break;
        }
        if (count < 0 && writeSucceeded) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:
                @"Cannot read %@: %s", archivePath, strerror(errno)];
            writeSucceeded = NO;
        }
        close(descriptor);
        if (!writeSucceeded) {
            archive_entry_free(entry);
            return NO;
        }
    }

    result = archive_write_finish_entry(writer);
    archive_entry_free(entry);
    if (result < FILZA_ARCHIVE_WARN) {
        if (errorMessage) *errorMessage = filzaArchiveError(writer,
            @"Cannot finish ZIP entry");
        return NO;
    }

    if (S_ISDIR(status.st_mode)) {
        NSError *directoryError = nil;
        NSArray<NSString *> *children = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:sourcePath error:&directoryError];
        if (!children) {
            if (errorMessage) *errorMessage = directoryError.localizedDescription;
            return NO;
        }
        for (NSString *child in children) {
            if (!filzaWriteArchiveEntry(writer,
                    [sourcePath stringByAppendingPathComponent:child],
                    [archivePath stringByAppendingPathComponent:child],
                    outputPath, errorMessage))
                return NO;
        }
    }
    return YES;
}

// Hook: -[Zipper ZipFiles:toFilePath:currentDirectory:]
static id hook_ZipFiles(id self, SEL _cmd, id files, id toFilePath,
                        id currentDirectory) {
    @try {
        NSString *outputPath = filzaArchiveResolvedPath(toFilePath,
            currentDirectory);
        NSString *basePath = filzaArchiveResolvedPath(currentDirectory, nil);
        if (outputPath.length == 0 || basePath.length == 0) return nil;

        NSString *temporaryPath = [[outputPath stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:[NSString stringWithFormat:
                @".%@.%@.tmp", outputPath.lastPathComponent,
                NSUUID.UUID.UUIDString]];
        struct archive *writer = archive_write_new();
        NSString *errorMessage = nil;
        BOOL succeeded = writer != NULL;
        if (!writer) errorMessage = @"Cannot initialize ZIP writer";
        if (succeeded && archive_write_set_format_zip(writer) <
                FILZA_ARCHIVE_WARN) {
            errorMessage = filzaArchiveError(writer,
                @"Cannot initialize ZIP format");
            succeeded = NO;
        }
        if (succeeded && archive_write_add_filter_none(writer) <
                FILZA_ARCHIVE_WARN) {
            errorMessage = filzaArchiveError(writer,
                @"Cannot initialize ZIP output");
            succeeded = NO;
        }
        if (succeeded && archive_write_open_filename(writer,
                temporaryPath.fileSystemRepresentation) < FILZA_ARCHIVE_WARN) {
            errorMessage = filzaArchiveError(writer,
                @"Cannot create ZIP archive");
            succeeded = NO;
        }

        if (succeeded) {
            for (id file in files) {
                NSString *fileName = nil;
                SEL selector = NSSelectorFromString(@"fileName");
                if ([file respondsToSelector:selector])
                    fileName = ((id(*)(id, SEL))objc_msgSend)(file, selector);
                if (fileName.length == 0)
                    fileName = filzaArchiveObjectPath(file).lastPathComponent;
                NSString *sourcePath = filzaArchiveResolvedPath(file,
                    currentDirectory);
                if (sourcePath.length == 0 && fileName.length > 0)
                    sourcePath = [basePath stringByAppendingPathComponent:fileName];
                if (sourcePath.length == 0 || fileName.length == 0 ||
                    !filzaWriteArchiveEntry(writer, sourcePath, fileName,
                        outputPath, &errorMessage)) {
                    if (!errorMessage) errorMessage = @"Invalid ZIP source path";
                    succeeded = NO;
                    break;
                }
            }
        }

        if (writer) {
            int closeResult = archive_write_close(writer);
            if (succeeded && closeResult < FILZA_ARCHIVE_WARN) {
                errorMessage = filzaArchiveError(writer,
                    @"Cannot finish ZIP archive");
                succeeded = NO;
            }
            archive_write_free(writer);
        }

        if (succeeded && rename(temporaryPath.fileSystemRepresentation,
                outputPath.fileSystemRepresentation) != 0) {
            errorMessage = [NSString stringWithFormat:
                @"Cannot save ZIP archive: %s", strerror(errno)];
            succeeded = NO;
        }
        if (!succeeded) {
            unlink(temporaryPath.fileSystemRepresentation);
            NSLog(@"[ZIP] create failed for %@: %@", outputPath,
                errorMessage ?: @"unknown error");
            return nil;
        }

        NSLog(@"[ZIP] created %@", outputPath);
        return filzaFileItemAtPath(outputPath);
    } @catch (NSException *exception) {
        NSLog(@"[ZIP] create exception: %@", exception);
        return nil;
    }
}

static NSString *filzaSafeArchiveRelativePath(const char *pathname) {
    if (!pathname) return nil;
    NSString *path = [NSString stringWithUTF8String:pathname];
    if (path.length == 0 || path.isAbsolutePath) return nil;
    while ([path hasPrefix:@"./"])
        path = [path substringFromIndex:2];
    if (path.length == 0 || [path isEqualToString:@"."]) return @"";
    for (NSString *component in path.pathComponents) {
        if ([component isEqualToString:@".."])
            return nil;
    }
    path = path.stringByStandardizingPath;
    return path.isAbsolutePath ? nil : path;
}

static BOOL filzaPathIsInsideRoot(NSString *path, NSString *root) {
    return [path isEqualToString:root] ||
        [path hasPrefix:[root stringByAppendingString:@"/"]];
}

static BOOL filzaCopyArchiveEntryData(struct archive *reader,
                                      struct archive *disk,
                                      NSString **errorMessage) {
    const void *buffer = NULL;
    size_t size = 0;
    filza_la_int64_t offset = 0;
    for (;;) {
        int result = archive_read_data_block(reader, &buffer, &size, &offset);
        if (result == FILZA_ARCHIVE_EOF) return YES;
        if (result < FILZA_ARCHIVE_OK) {
            if (errorMessage) *errorMessage = filzaArchiveError(reader,
                @"Cannot read ZIP entry data");
            return NO;
        }
        if (archive_write_data_block(disk, buffer, size, offset) <
                FILZA_ARCHIVE_WARN) {
            if (errorMessage) *errorMessage = filzaArchiveError(disk,
                @"Cannot write extracted file data");
            return NO;
        }
    }
}

static NSArray *filzaExtractZip(id zipObject, id toPath, id currentDirectory,
                                id password, id *outMessage) {
    NSString *zipPath = filzaArchiveResolvedPath(zipObject, currentDirectory);
    NSString *destination = filzaArchiveResolvedPath(toPath, currentDirectory);
    if (zipPath.length == 0 || destination.length == 0) {
        if (outMessage) *outMessage = @"Invalid ZIP path";
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL destinationExisted = [fileManager fileExistsAtPath:destination];
    NSError *directoryError = nil;
    if (![fileManager createDirectoryAtPath:destination
            withIntermediateDirectories:YES attributes:nil
            error:&directoryError]) {
        if (outMessage) *outMessage = directoryError.localizedDescription;
        return nil;
    }
    destination = destination.stringByStandardizingPath;

    // /var is itself a system symlink to /private/var on iOS. Passing the
    // display path to ARCHIVE_EXTRACT_SECURE_SYMLINKS rejects that legitimate
    // parent before it ever reaches an archive entry. Canonicalize the already
    // created extraction root, then keep the secure entry-level checks enabled.
    char canonicalPath[PATH_MAX];
    if (!realpath(destination.fileSystemRepresentation, canonicalPath)) {
        NSString *message = [NSString stringWithFormat:
            @"Cannot resolve extraction directory: %s", strerror(errno)];
        if (!destinationExisted)
            [fileManager removeItemAtPath:destination error:nil];
        if (outMessage) *outMessage = message;
        return nil;
    }
    NSString *destinationRoot = [fileManager
        stringWithFileSystemRepresentation:canonicalPath
        length:strlen(canonicalPath)];
    if (destinationRoot.length == 0) {
        if (!destinationExisted)
            [fileManager removeItemAtPath:destination error:nil];
        if (outMessage) *outMessage = @"Cannot resolve extraction directory";
        return nil;
    }

    struct archive *reader = archive_read_new();
    struct archive *disk = archive_write_disk_new();
    NSString *errorMessage = nil;
    BOOL succeeded = reader != NULL && disk != NULL;
    if (!succeeded) errorMessage = @"Cannot initialize ZIP extractor";
    if (succeeded) {
        archive_read_support_filter_all(reader);
        archive_read_support_format_zip(reader);
        if ([password isKindOfClass:NSString.class] &&
                [password length] > 0)
            archive_read_add_passphrase(reader,
                ((NSString *)password).UTF8String);
        archive_write_disk_set_options(disk,
            FILZA_ARCHIVE_EXTRACT_PERM |
            FILZA_ARCHIVE_EXTRACT_TIME |
            FILZA_ARCHIVE_EXTRACT_SECURE_SYMLINKS |
            FILZA_ARCHIVE_EXTRACT_SECURE_NODOTDOT |
            FILZA_ARCHIVE_EXTRACT_SAFE_WRITES);
        archive_write_disk_set_standard_lookup(disk);
        if (archive_read_open_filename(reader, zipPath.fileSystemRepresentation,
                64 * 1024) < FILZA_ARCHIVE_WARN) {
            errorMessage = filzaArchiveError(reader, @"Cannot open ZIP archive");
            succeeded = NO;
        }
    }

    struct archive_entry *entry = NULL;
    while (succeeded) {
        int result = archive_read_next_header(reader, &entry);
        if (result == FILZA_ARCHIVE_EOF) break;
        if (result < FILZA_ARCHIVE_WARN) {
            errorMessage = filzaArchiveError(reader,
                @"Cannot read ZIP entry");
            succeeded = NO;
            break;
        }

        const char *rawPath = archive_entry_pathname_utf8(entry);
        if (!rawPath) rawPath = archive_entry_pathname(entry);
        NSString *relativePath = filzaSafeArchiveRelativePath(rawPath);
        if (!relativePath) {
            errorMessage = @"ZIP contains an unsafe path";
            succeeded = NO;
            break;
        }
        if (relativePath.length == 0) {
            archive_read_data_skip(reader);
            continue;
        }
        if (archive_entry_hardlink_utf8(entry)) {
            errorMessage = @"ZIP contains an unsupported hard link";
            succeeded = NO;
            break;
        }

        NSString *outputPath = [[destinationRoot
            stringByAppendingPathComponent:relativePath]
            stringByStandardizingPath];
        if (!filzaPathIsInsideRoot(outputPath, destinationRoot)) {
            errorMessage = @"ZIP entry escapes the destination directory";
            succeeded = NO;
            break;
        }

        const char *symlink = archive_entry_symlink_utf8(entry);
        if (symlink) {
            NSString *target = [NSString stringWithUTF8String:symlink];
            if (target.length == 0 || target.isAbsolutePath) {
                errorMessage = @"ZIP contains an unsafe symbolic link";
                succeeded = NO;
                break;
            }
            NSString *resolvedTarget = [[[outputPath
                stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:target]
                stringByStandardizingPath];
            if (!filzaPathIsInsideRoot(resolvedTarget, destinationRoot)) {
                errorMessage = @"ZIP symbolic link escapes the destination";
                succeeded = NO;
                break;
            }
        }

        mode_t fileType = archive_entry_filetype(entry);
        if (fileType != S_IFREG && fileType != S_IFDIR &&
                fileType != S_IFLNK) {
            archive_read_data_skip(reader);
            continue;
        }

        archive_entry_set_pathname_utf8(entry, outputPath.UTF8String);
        result = archive_write_header(disk, entry);
        if (result < FILZA_ARCHIVE_WARN) {
            errorMessage = filzaArchiveError(disk,
                @"Cannot create extracted ZIP entry");
            succeeded = NO;
            break;
        }
        if (!filzaCopyArchiveEntryData(reader, disk, &errorMessage)) {
            succeeded = NO;
            break;
        }
        if (archive_write_finish_entry(disk) < FILZA_ARCHIVE_WARN) {
            errorMessage = filzaArchiveError(disk,
                @"Cannot finish extracted ZIP entry");
            succeeded = NO;
            break;
        }

    }

    if (reader) {
        archive_read_close(reader);
        archive_read_free(reader);
    }
    if (disk) {
        archive_write_close(disk);
        archive_write_free(disk);
    }

    if (!succeeded) {
        if (!destinationExisted) {
            NSError *cleanupError = nil;
            if (![fileManager removeItemAtPath:destination
                    error:&cleanupError] && cleanupError)
                NSLog(@"[ZIP] cleanup failed for %@: %@", destination,
                    cleanupError.localizedDescription);
        }
        if (outMessage) *outMessage = errorMessage ?: @"Cannot extract ZIP";
        NSLog(@"[ZIP] extract failed for %@: %@", zipPath,
            errorMessage ?: @"unknown error");
        return nil;
    }

    // Zipper's caller expects the extraction wrapper itself here. It then
    // applies Filza's extract-location preference, moves the wrapper's
    // children into the current directory when requested, and publishes the
    // resulting FileItems to the visible browser. Returning archive entries
    // instead leaves the wrapper unannounced and makes a one-item archive
    // appear as test/test.txt (or test/test) until the browser is reopened.
    id destinationItem = filzaFileItemAtPath(destination);
    if (!destinationItem) {
        if (outMessage) *outMessage = @"Cannot create extracted item";
        return nil;
    }
    if (outMessage) *outMessage = @"OK";
    NSLog(@"[ZIP] extracted %@ to %@", zipPath, destination);
    return @[destinationItem];
}

// Hook: -[Zipper unZipFile:toPath:currentDirectory:outMessage:]
static id hook_unZipFile(id self, SEL _cmd, id zipPath, id toPath,
                         id currentDirectory, id *outMessage) {
    @try {
        return filzaExtractZip(zipPath, toPath, currentDirectory, nil,
            outMessage);
    } @catch (NSException *exception) {
        if (outMessage) *outMessage = exception.reason;
        NSLog(@"[ZIP] extract exception: %@", exception);
        return nil;
    }
}

// Hook: -[Zipper unZipFile:toPath:currentDirectory:withPassword:outMessage:]
static id hook_unZipFilePassword(id self, SEL _cmd, id zipPath, id toPath,
                                 id currentDirectory, id password,
                                 id *outMessage) {
    @try {
        return filzaExtractZip(zipPath, toPath, currentDirectory, password,
            outMessage);
    } @catch (NSException *exception) {
        if (outMessage) *outMessage = exception.reason;
        NSLog(@"[ZIP] password extract exception: %@", exception);
        return nil;
    }
}

static NSData *filzaDataInZip(id zipObject, NSString *entryName) {
    NSString *zipPath = filzaArchiveResolvedPath(zipObject, nil);
    if (zipPath.length == 0 || entryName.length == 0) return nil;

    struct archive *reader = archive_read_new();
    if (!reader) return nil;
    archive_read_support_filter_all(reader);
    archive_read_support_format_zip(reader);
    if (archive_read_open_filename(reader, zipPath.fileSystemRepresentation,
            64 * 1024) < FILZA_ARCHIVE_WARN) {
        archive_read_free(reader);
        return nil;
    }

    NSMutableData *data = nil;
    struct archive_entry *entry = NULL;
    for (;;) {
        int result = archive_read_next_header(reader, &entry);
        if (result == FILZA_ARCHIVE_EOF) break;
        if (result < FILZA_ARCHIVE_WARN) break;
        const char *rawPath = archive_entry_pathname_utf8(entry);
        if (!rawPath) rawPath = archive_entry_pathname(entry);
        NSString *path = filzaSafeArchiveRelativePath(rawPath);
        if (![path isEqualToString:entryName]) {
            archive_read_data_skip(reader);
            continue;
        }

        data = [NSMutableData data];
        uint8_t buffer[64 * 1024];
        filza_la_ssize_t count;
        while ((count = archive_read_data(reader, buffer,
                sizeof(buffer))) > 0)
            [data appendBytes:buffer length:(NSUInteger)count];
        if (count < 0) data = nil;
        break;
    }
    archive_read_close(reader);
    archive_read_free(reader);
    return data;
}

static id hook_dataInZipFilePath(id self, SEL _cmd, id zipPath, id name) {
    NSData *data = filzaDataInZip(zipPath, name);
    if (data || !orig_dataInZipFilePath) return data;
    return ((id(*)(id, SEL, id, id))orig_dataInZipFilePath)(self, _cmd,
        zipPath, name);
}

static id hook_dataInZipFile(id self, SEL _cmd, id zipFile, id name) {
    NSData *data = filzaDataInZip(zipFile, name);
    if (data || !orig_dataInZipFile) return data;
    return ((id(*)(id, SEL, id, id))orig_dataInZipFile)(self, _cmd,
        zipFile, name);
}

#pragma mark - Apps Manager Fix

// Rebuild the Apps Manager without touching application bundle directories.
// LaunchServices supplies the installed-app catalogue and presentation metadata;
// the matching class-2 MCM lease supplies the navigable data-container path.

@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(NSString *)bundleId;
- (NSString *)applicationIdentifier;
- (NSURL *)bundleURL;
- (NSURL *)dataContainerURL;
- (NSString *)localizedName;
- (NSString *)localizedShortName;
- (NSString *)itemName;
- (id)correspondingApplicationRecord;
- (id)_infoDictionary;
- (NSData *)primaryIconDataForVariant:(NSInteger)variant;
- (NSData *)iconDataForVariant:(NSInteger)variant;
- (NSString *)bundleVersion;
- (NSString *)shortVersionString;
- (NSString *)applicationType;
- (NSDictionary *)iconsDictionary;
- (NSNumber *)staticDiskUsage;
- (NSNumber *)dynamicDiskUsage;
@end

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
@end

// When enumeration is filtered but the class-2 lookup succeeded, Filza still
// needs an object exposing applicationIdentifier. Forward optional presentation
// metadata to a direct LS proxy when one is available.
@interface MHAAppManagerProxy : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) id backingProxy;
- (instancetype)initWithIdentifier:(NSString *)identifier backingProxy:(id)proxy;
@end

@implementation MHAAppManagerProxy
- (instancetype)initWithIdentifier:(NSString *)identifier backingProxy:(id)proxy {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _backingProxy = proxy;
    }
    return self;
}
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] ||
        [self.backingProxy respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.backingProxy respondsToSelector:selector]
        ? self.backingProxy : [super forwardingTargetForSelector:selector];
}
- (NSString *)applicationIdentifier { return self.identifier; }
- (NSString *)bundleIdentifier { return self.identifier; }
- (NSString *)localizedName {
    NSString *cached = MHADeviceCatalogDisplayName(self.identifier);
    if (cached.length > 0) return cached;
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL))objc_msgSend)(self.backingProxy, _cmd) : nil;
}
- (NSString *)localizedShortName {
    NSString *cached = MHADeviceCatalogDisplayName(self.identifier);
    if (cached.length > 0) return cached;
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL))objc_msgSend)(self.backingProxy, _cmd) : nil;
}
- (NSString *)itemName {
    NSString *cached = MHADeviceCatalogDisplayName(self.identifier);
    if (cached.length > 0) return cached;
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL))objc_msgSend)(self.backingProxy, _cmd) : nil;
}
- (id)correspondingApplicationRecord {
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL))objc_msgSend)(self.backingProxy, _cmd) : nil;
}
- (id)_infoDictionary {
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL))objc_msgSend)(self.backingProxy, _cmd) : nil;
}
- (NSData *)primaryIconDataForVariant:(NSInteger)variant {
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL, NSInteger))objc_msgSend)(self.backingProxy,
            _cmd, variant) : nil;
}
- (NSData *)iconDataForVariant:(NSInteger)variant {
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL, NSInteger))objc_msgSend)(self.backingProxy,
            _cmd, variant) : nil;
}
- (NSString *)bundleVersion {
    NSString *cached = MHADeviceCatalogVersion(self.identifier);
    if (cached.length > 0) return cached;
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL))objc_msgSend)(self.backingProxy, _cmd) : nil;
}
- (NSString *)shortVersionString {
    NSString *cached = MHADeviceCatalogVersion(self.identifier);
    if (cached.length > 0) return cached;
    return [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL))objc_msgSend)(self.backingProxy, _cmd) : nil;
}
- (NSString *)applicationType {
    NSString *cached = MHADeviceCatalogApplicationType(self.identifier);
    if (cached.length > 0) return cached;
    NSString *type = [self.backingProxy respondsToSelector:_cmd]
        ? ((id(*)(id, SEL))objc_msgSend)(self.backingProxy, _cmd) : nil;
    if (type.length > 0) return type;
    return [self.identifier hasPrefix:@"com.apple."] ? @"System" : @"User";
}
- (NSNumber *)staticDiskUsage {
    return MHADeviceCatalogStaticDiskUsage(self.identifier) ?: @0;
}
- (NSNumber *)dynamicDiskUsage {
    return MHADeviceCatalogDynamicDiskUsage(self.identifier) ?: @0;
}
@end

// --- Helper: find data container path ---
static NSString *findDataContainer(NSString *bundleId) {
    // The catalogue is built from class-2 links that were already activated
    // and directory-open checked at launch. Reuse their targets here instead
    // of issuing hundreds of synchronous containermanagerd requests.
    return MCMFilzaAppDataPath(bundleId);
}

static BOOL isAppManagerPlaceholderName(id value) {
    if (![value isKindOfClass:NSString.class]) return YES;
    NSString *name = [(NSString *)value
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0) return YES;
    NSString *lowercase = name.lowercaseString;
    return [lowercase isEqualToString:@"(no path)"] ||
        [lowercase isEqualToString:@"no path"] ||
        [lowercase isEqualToString:@"(null)"] ||
        [lowercase isEqualToString:@"<null>"];
}

static NSString *nonIdentifierName(id value, NSString *bundleId) {
    if (isAppManagerPlaceholderName(value)) return nil;
    NSString *name = [(NSString *)value
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([name isEqualToString:bundleId]) return nil;
    return name;
}

static id appManagerObjectValue(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id(*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static __weak id gVisibleAppManagerBrowser = nil;
static void scheduleVisibleAppManagerReload(void);
static void scheduleVisibleAppManagerCatalogueReload(void);
static void scheduleCatalogC2Sync(void);

typedef id (*MHAEnumerateInstalledItemsFunction)(NSDictionary *,
    void (^)(id, NSDictionary *));

static NSDictionary<NSString *, NSDictionary *> *gMIMetadataByIdentifier = nil;
static NSString *gMIMetadataStatus = @"not started";
static NSString *gMIMetadataError = nil;

static NSDictionary *mobileInstallationMetadataForIdentifier(
        NSString *bundleId) {
    if (bundleId.length == 0) return nil;
    @synchronized (MHAAppManagerProxy.class) {
        return gMIMetadataByIdentifier[bundleId];
    }
}

static NSString *displayNameFromMetadataDictionary(id value,
                                                    NSString *bundleId) {
    id dictionary = value;
    if (![dictionary isKindOfClass:NSDictionary.class])
        dictionary = appManagerObjectValue(dictionary,
            NSSelectorFromString(@"propertyList"));
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;

    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName",
                             @"LocalizedName", @"DisplayName", @"Name"]) {
        NSString *name = nonIdentifierName(dictionary[key], bundleId);
        if (name) return name;
    }
    return nil;
}

static void writeMobileInstallationMetadataDiagnostics(void) {
    NSDictionary *metadata = nil;
    NSString *status = nil;
    NSString *error = nil;
    @synchronized (MHAAppManagerProxy.class) {
        metadata = gMIMetadataByIdentifier;
        status = gMIMetadataStatus;
        error = gMIMetadataError;
    }
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"App Manager metadata provider diagnostics\n\n"
         "Build marker: AppManager-CachedDiskUsage-NoFreeze-v20\n"
         "MobileInstallation status: %@\n"
         "MobileInstallation records: %lu\n"
         "MobileInstallation error: %@\n",
        status ?: @"unknown", (unsigned long)metadata.count,
        error ?: @"(none)"];
    for (NSString *bundleId in @[@"ai.x.GrokApp", @"com.google.chrome.ios",
                                  @"com.apple.shortcuts",
                                  @"com.apple.store.Jolly"]) {
        NSString *name = displayNameFromMetadataDictionary(
            metadata[bundleId], bundleId);
        [report appendFormat:@"%@ -> %@\n", bundleId, name ?: @"(none)"];
    }
    NSString *path = [MCMFilzaVirtualRoot() stringByAppendingPathComponent:
        @"App Manager Metadata Provider.txt"];
    [report writeToFile:path atomically:YES
        encoding:NSUTF8StringEncoding error:nil];
}

static void scheduleMobileInstallationMetadataLoad(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @synchronized (MHAAppManagerProxy.class) {
            gMIMetadataStatus = @"loading";
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            void *handle = dlopen(
                "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
                RTLD_LAZY | RTLD_LOCAL);
            MHAEnumerateInstalledItemsFunction enumerate = handle
                ? (MHAEnumerateInstalledItemsFunction)dlsym(handle,
                    "MobileInstallationEnumerateAllInstalledItemDictionaries")
                : NULL;
            NSMutableDictionary *records = [NSMutableDictionary dictionary];
            id returnedError = nil;
            if (enumerate) {
                returnedError = enumerate(@{}, ^(__unused id client,
                                                  NSDictionary *dictionary) {
                    if (![dictionary isKindOfClass:NSDictionary.class]) return;
                    NSString *identifier = dictionary[@"CFBundleIdentifier"];
                    if (![identifier isKindOfClass:NSString.class] ||
                        identifier.length == 0)
                        identifier = dictionary[@"BundleIdentifier"];
                    if ([identifier isKindOfClass:NSString.class] &&
                        identifier.length > 0)
                        records[identifier] = dictionary;
                });
            }
            @synchronized (MHAAppManagerProxy.class) {
                gMIMetadataByIdentifier = records.copy;
                gMIMetadataError = !enumerate
                    ? @"enumeration symbol unavailable"
                    : (returnedError ? [returnedError description] : nil);
                gMIMetadataStatus = !enumerate ? @"unavailable"
                    : (returnedError ? @"failed" : @"complete");
            }
            NSLog(@"[MHA-APPMGR] MobileInstallation status=%@ records=%lu error=%@",
                gMIMetadataStatus, (unsigned long)records.count,
                gMIMetadataError ?: @"none");
            writeMobileInstallationMetadataDiagnostics();
            scheduleVisibleAppManagerReload();
        });
    });
}

typedef CFStringRef (*MHASBSCopyLocalizedNameFunction)(CFStringRef);
typedef CFDataRef (*MHASBSCopyIconDataFunction)(CFStringRef);

static MHASBSCopyLocalizedNameFunction gSBSCopyLocalizedName = NULL;
static MHASBSCopyIconDataFunction gSBSCopyIconData = NULL;

static void resolveSpringBoardMetadataFunctions(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            RTLD_LAZY | RTLD_LOCAL);
        void *lookupHandle = handle ?: RTLD_DEFAULT;
        gSBSCopyLocalizedName =
            (MHASBSCopyLocalizedNameFunction)dlsym(lookupHandle,
                "SBSCopyLocalizedApplicationNameForDisplayIdentifier");
        gSBSCopyIconData =
            (MHASBSCopyIconDataFunction)dlsym(lookupHandle,
                "SBSCopyIconImagePNGDataForDisplayIdentifier");
        NSLog(@"[MHA-APPMGR] SpringBoardServices name=%d icon=%d",
            gSBSCopyLocalizedName != NULL, gSBSCopyIconData != NULL);
    });
}

static NSString *springBoardDisplayName(NSString *bundleId) {
    if (![bundleId isKindOfClass:NSString.class] || bundleId.length == 0)
        return nil;
    resolveSpringBoardMetadataFunctions();
    if (!gSBSCopyLocalizedName) return nil;
    CFStringRef copied = gSBSCopyLocalizedName(
        (__bridge CFStringRef)bundleId);
    NSString *name = copied ? CFBridgingRelease(copied) : nil;
    return nonIdentifierName(name, bundleId);
}

// Read the LS record's already-registered metadata. These selectors and the
// cached info dictionaries are backed by the LaunchServices database; this
// code never opens the application's bundle directory.
static NSString *launchServicesDisplayName(id proxy, NSString *bundleId) {
    NSString *name = nil;
    for (NSString *selectorName in @[@"localizedName", @"localizedShortName",
                                     @"itemName"]) {
        name = nonIdentifierName(appManagerObjectValue(proxy,
            NSSelectorFromString(selectorName)), bundleId);
        if (name) return name;
    }

    name = displayNameFromMetadataDictionary(appManagerObjectValue(proxy,
        NSSelectorFromString(@"_infoDictionary")), bundleId);
    if (name) return name;

    id record = appManagerObjectValue(proxy,
        NSSelectorFromString(@"correspondingApplicationRecord"));
    for (NSString *selectorName in @[@"localizedName", @"localizedShortName",
                                     @"_fallbackLocalizedName"]) {
        name = nonIdentifierName(appManagerObjectValue(record,
            NSSelectorFromString(selectorName)), bundleId);
        if (name) return name;
    }

    name = displayNameFromMetadataDictionary(appManagerObjectValue(record,
        NSSelectorFromString(@"infoDictionary")), bundleId);
    return name;
}

static NSString *systemApplicationDisplayName(id proxy, NSString *bundleId) {
    NSString *name = MHADeviceCatalogDisplayName(bundleId);
    if (!name) name = launchServicesDisplayName(proxy, bundleId);
    if (!name) name = springBoardDisplayName(bundleId);
    return name ?: bundleId;
}

// --- Hook: allApplications using safe LS results plus the RSD cache ---
static IMP orig_allApplications = NULL;
static __thread BOOL enumeratingInstalledApplications = NO;
static BOOL gLSWorkspaceHookInstalled = NO;
static BOOL gAppItemSetterHookInstalled = NO;
static BOOL gAppItemFileNameHookInstalled = NO;
static BOOL gAppItemIconHookInstalled = NO;
static BOOL gAppSizeHooksInstalled = NO;
static BOOL gAppBrowserCellHooksInstalled = NO;
static void installAppManagerHooks(void);

static void writeAppManagerDiagnostics(NSUInteger originalCount,
                                       NSUInteger installedCount,
                                       NSUInteger c2Count,
                                       NSUInteger rsdCount,
                                       NSUInteger directProxyCount,
                                       NSUInteger adapterCount,
                                       NSUInteger finalCount) {
    NSString *report = [NSString stringWithFormat:
        @"App Manager diagnostics\n\n"
         "Build marker: AppManager-CachedDiskUsage-NoFreeze-v20\n"
         "Source policy: cached RSD installation_proxy identifiers are authoritative when available; successful MHA-MCM class-2 identifiers are the offline fallback and data-path provider.\n"
         "Names and versions: cached RSD installation_proxy records, then safe zero-argument LaunchServices fields.\n"
         "Icons: persistent PNG cache populated by RSD SpringBoardServices.\n"
         "Bundle identifiers: displayed independently in each row's detail label.\n"
         "Disk usage: cached installation_proxy StaticDiskUsage + DynamicDiskUsage; Filza's blocking native size worker and jailed LaunchServices disk-usage getters are not called.\n"
         "No application bundle directory or .app/Info.plist was scanned.\n\n"
         "RSD catalogue status: %@\n"
         "RSD cached identifiers: %lu\n"
         "App Manager hook state: workspace=%d setter=%d fileName=%d iconPath=%d sizes=%d cells=%d\n\n"
         "allApplications: %lu\n"
         "allInstalledApplications: %lu\n"
         "successful C2 identifiers: %lu\n"
         "catalogue identifiers with direct LS proxy: %lu\n"
         "catalogue identifier-only adapters: %lu\n"
         "final App Manager proxies: %lu\n",
        MHADeviceCatalogStatus(), (unsigned long)rsdCount,
        gLSWorkspaceHookInstalled, gAppItemSetterHookInstalled,
        gAppItemFileNameHookInstalled, gAppItemIconHookInstalled,
        gAppSizeHooksInstalled, gAppBrowserCellHooksInstalled,
        (unsigned long)originalCount, (unsigned long)installedCount,
        (unsigned long)c2Count, (unsigned long)directProxyCount,
        (unsigned long)adapterCount, (unsigned long)finalCount];
    NSString *path = [MCMFilzaVirtualRoot()
        stringByAppendingPathComponent:@"App Manager Diagnostics.txt"];
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static id hook_allApplications(id self, SEL _cmd) {
    // Filza's own classes may be registered after this dylib's constructor.
    // This call runs before TGApplicationsViewController creates its items.
    installAppManagerHooks();
    MHADeviceCatalogLoadCache();
    MHADeviceCatalogScheduleRefresh();
    NSArray *origResult = ((id(*)(id,SEL))orig_allApplications)(self, _cmd);
    if (enumeratingInstalledApplications) return origResult ?: @[];

    NSArray *installed = nil;
    if ([self respondsToSelector:@selector(allInstalledApplications)]) {
        enumeratingInstalledApplications = YES;
        @try {
            installed = ((id(*)(id, SEL))objc_msgSend)(self,
                @selector(allInstalledApplications));
        } @catch (__unused NSException *exception) {
            installed = nil;
        }
        enumeratingInstalledApplications = NO;
    }

    NSArray<NSString *> *c2Identifiers = MCMFilzaAppDataIdentifiers();
    NSArray<NSString *> *rsdIdentifiers = MHADeviceCatalogIdentifiers();
    NSSet<NSString *> *authoritativeIdentifiers = rsdIdentifiers.count > 0
        ? [NSSet setWithArray:rsdIdentifiers] : nil;
    NSMutableArray *apps = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^appendProxies)(NSArray *) = ^(NSArray *proxies) {
        for (id proxy in [proxies isKindOfClass:NSArray.class] ? proxies : @[]) {
            NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)]
                ? ((id(*)(id, SEL))objc_msgSend)(proxy, @selector(applicationIdentifier)) : nil;
            if (![identifier isKindOfClass:NSString.class] || identifier.length == 0 ||
                (authoritativeIdentifiers &&
                 ![authoritativeIdentifiers containsObject:identifier]) ||
                [seen containsObject:identifier])
                continue;
            [seen addObject:identifier];
            [apps addObject:proxy];
        }
    };
    appendProxies(installed);
    appendProxies(origResult);

    NSMutableOrderedSet<NSString *> *catalogueIdentifiers =
        [NSMutableOrderedSet orderedSetWithArray:
            rsdIdentifiers.count > 0 ? rsdIdentifiers : (c2Identifiers ?: @[])];
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    NSUInteger directProxyCount = 0;
    NSUInteger adapterCount = 0;
    for (NSString *identifier in catalogueIdentifiers) {
        if ([seen containsObject:identifier]) continue;
        id directProxy = nil;
        @try {
            if ([proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)])
                directProxy = ((id(*)(id, SEL, id))objc_msgSend)(proxyClass,
                    @selector(applicationProxyForIdentifier:), identifier);
        } @catch (__unused NSException *exception) {
            directProxy = nil;
        }
        NSString *directIdentifier = [directProxy
            respondsToSelector:@selector(applicationIdentifier)]
            ? ((id(*)(id, SEL))objc_msgSend)(directProxy,
                @selector(applicationIdentifier)) : nil;
        id proxy = nil;
        if ([directIdentifier isEqualToString:identifier]) {
            proxy = directProxy;
            directProxyCount++;
        } else {
            proxy = [[MHAAppManagerProxy alloc]
                initWithIdentifier:identifier backingProxy:directProxy];
            adapterCount++;
        }
        [seen addObject:identifier];
        [apps addObject:proxy];
    }

    writeAppManagerDiagnostics(
        [origResult isKindOfClass:NSArray.class] ? origResult.count : 0,
        [installed isKindOfClass:NSArray.class] ? installed.count : 0,
        c2Identifiers.count, rsdIdentifiers.count, directProxyCount,
        adapterCount, apps.count);
    NSLog(@"[MHA-APPMGR] LS original=%lu installed=%lu C2=%lu RSD=%lu direct=%lu adapter=%lu final=%lu",
        (unsigned long)([origResult isKindOfClass:NSArray.class] ? origResult.count : 0),
        (unsigned long)([installed isKindOfClass:NSArray.class] ? installed.count : 0),
        (unsigned long)c2Identifiers.count, (unsigned long)rsdIdentifiers.count,
        (unsigned long)directProxyCount,
        (unsigned long)adapterCount, (unsigned long)apps.count);
    return apps.count > 0 ? apps : (origResult ?: @[]);
}

// --- Hook: setAppProxy: — cached RSD metadata + class-2 MCM path ---
static IMP orig_setAppProxy = NULL;
static IMP orig_appItemFileName = NULL;
static void hook_setAppProxy(id self, SEL _cmd, id proxy) {
    if (!proxy) return;

    NSString *bundleId = [proxy respondsToSelector:@selector(applicationIdentifier)]
        ? ((id(*)(id, SEL))objc_msgSend)(proxy, @selector(applicationIdentifier)) : nil;
    if (![bundleId isKindOfClass:NSString.class] || bundleId.length == 0)
        bundleId = [self respondsToSelector:NSSelectorFromString(@"bundleId")]
            ? ((id(*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"bundleId")) : nil;

    // The original setter scans bundleURL for icon files. Keep that path
    // bypassed, but wrap the proxy so Filza's own size worker and detail view
    // read only the installation_proxy cache instead of blocking LS getters.
    id safeProxy = proxy;
    if (bundleId.length > 0 &&
        ![proxy isKindOfClass:MHAAppManagerProxy.class])
        safeProxy = [[MHAAppManagerProxy alloc]
            initWithIdentifier:bundleId backingProxy:proxy];
    Ivar proxyIvar = class_getInstanceVariable(object_getClass(self), "_appProxy");
    if (!proxyIvar) proxyIvar = class_getInstanceVariable([self class], "_appProxy");
    if (proxyIvar) object_setIvar(self, proxyIvar, safeProxy);
    proxy = safeProxy;

    NSNumber *totalDiskUsage = bundleId.length > 0
        ? MHADeviceCatalogTotalDiskUsage(bundleId) : nil;
    if ([self respondsToSelector:NSSelectorFromString(@"setFileSize:")])
        ((void(*)(id, SEL, unsigned long long))objc_msgSend)(self,
            NSSelectorFromString(@"setFileSize:"),
            totalDiskUsage ? totalDiskUsage.unsignedLongLongValue : 0);
    if (totalDiskUsage && [self respondsToSelector:
            NSSelectorFromString(@"setAFileSizeString:")]) {
        NSString *formattedSize = [NSByteCountFormatter
            stringFromByteCount:totalDiskUsage.longLongValue
            countStyle:NSByteCountFormatterCountStyleFile];
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setAFileSizeString:"), formattedSize);
    }

    if (bundleId.length == 0) return;
    if ([self respondsToSelector:NSSelectorFromString(@"setBundleId:")])
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setBundleId:"), bundleId);

    NSString *name = systemApplicationDisplayName(proxy, bundleId);
    ((void(*)(id, SEL, id))objc_msgSend)(self,
        NSSelectorFromString(@"setAFileName:"), name);

    NSString *version = MHADeviceCatalogVersion(bundleId);
    if (version.length == 0 &&
        [proxy respondsToSelector:@selector(shortVersionString)])
        version = ((id(*)(id, SEL))objc_msgSend)(proxy,
            @selector(shortVersionString));
    if (version.length == 0 && [proxy respondsToSelector:@selector(bundleVersion)])
        version = ((id(*)(id, SEL))objc_msgSend)(proxy, @selector(bundleVersion));
    if (version.length > 0)
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setVersion:"), version);

    NSString *type = MHADeviceCatalogApplicationType(bundleId);
    if (type.length == 0 && [proxy respondsToSelector:@selector(applicationType)])
        type = ((id(*)(id, SEL))objc_msgSend)(proxy,
            @selector(applicationType));
    if ([self respondsToSelector:NSSelectorFromString(@"setSystem:")])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self,
            NSSelectorFromString(@"setSystem:"), ![type isEqualToString:@"User"]);

    NSString *dataPath = findDataContainer(bundleId);
    if (dataPath)
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setDocumentPath:"), dataPath);

    NSString *iconPath = MHADeviceCatalogIconPath(bundleId);
    if (iconPath.length > 0 &&
        [self respondsToSelector:NSSelectorFromString(@"setIconPath:")])
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setIconPath:"), iconPath);

}

static id hook_appItemFileName(id self, SEL _cmd) {
    id value = orig_appItemFileName
        ? ((id(*)(id, SEL))orig_appItemFileName)(self, _cmd) : nil;
    NSString *bundleId = appManagerObjectValue(self,
        NSSelectorFromString(@"bundleId"));
    id proxy = appManagerObjectValue(self,
        NSSelectorFromString(@"appProxy"));
    if (bundleId.length == 0 &&
        [proxy respondsToSelector:@selector(applicationIdentifier)])
        bundleId = ((id(*)(id, SEL))objc_msgSend)(proxy,
            @selector(applicationIdentifier));
    if (!isAppManagerPlaceholderName(value) &&
        ![value isEqualToString:bundleId])
        return value;
    if (bundleId.length == 0) return value;

    NSString *name = systemApplicationDisplayName(proxy, bundleId);
    if (name.length > 0 && ![name isEqualToString:bundleId] &&
        [self respondsToSelector:NSSelectorFromString(@"setAFileName:")])
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setAFileName:"), name);
    return name.length > 0 ? name : bundleId;
}

static IMP orig_appItemIconPath = NULL;
static IMP orig_appTableCell = NULL;
static IMP orig_appCollectionCell = NULL;
static BOOL gAppManagerReloadScheduled = NO;
static BOOL gAppManagerCatalogueReloadScheduled = NO;

static void scheduleVisibleAppManagerReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gAppManagerReloadScheduled) return;
        gAppManagerReloadScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.35 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                gAppManagerReloadScheduled = NO;
                id browser = gVisibleAppManagerBrowser;
                if ([browser respondsToSelector:@selector(reloadData)])
                    ((void(*)(id, SEL))objc_msgSend)(browser,
                        @selector(reloadData));
            });
    });
}

static void scheduleVisibleAppManagerCatalogueReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gAppManagerCatalogueReloadScheduled) return;
        gAppManagerCatalogueReloadScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.35 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                gAppManagerCatalogueReloadScheduled = NO;
                id browser = gVisibleAppManagerBrowser;
                id controller = appManagerObjectValue(browser,
                    NSSelectorFromString(@"viewController"));
                if (!controller)
                    controller = appManagerObjectValue(browser,
                        NSSelectorFromString(@"dataSource"));
                SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
                if ([controller respondsToSelector:loadSelector])
                    ((void(*)(id, SEL))objc_msgSend)(controller, loadSelector);
                else if ([browser respondsToSelector:@selector(reloadData)])
                    ((void(*)(id, SEL))objc_msgSend)(browser,
                        @selector(reloadData));
            });
    });
}

static dispatch_queue_t appManagerC2SyncQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("local.research.mha.appdata-sync",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void writeAppDataSyncDiagnostics(NSUInteger catalogCount,
                                        NSUInteger existingCount,
                                        NSArray<NSString *> *added,
                                        NSArray<NSString *> *removed,
                                        NSArray<NSString *> *failures,
                                        NSUInteger finalCount) {
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"App Manager AppData sync diagnostics\n\n"
         "Build marker: AppManager-CachedDiskUsage-NoFreeze-v20\n"
         "Updated: %@\n"
         "Catalogue identifiers: %lu\n"
         "Existing generated links before sync: %lu\n"
         "Links added or repaired: %lu\n"
         "Stale links removed: %lu\n"
         "Unavailable or failed lookups: %lu\n"
         "Generated links after sync: %lu\n\n",
        [NSDate date], (unsigned long)catalogCount,
        (unsigned long)existingCount, (unsigned long)added.count,
        (unsigned long)removed.count, (unsigned long)failures.count,
        (unsigned long)finalCount];
    for (NSString *identifier in added)
        [report appendFormat:@"ADDED\t%@\n", identifier];
    for (NSString *identifier in removed)
        [report appendFormat:@"REMOVED\t%@\n", identifier];
    for (NSString *failure in failures)
        [report appendFormat:@"FAILED\t%@\n", failure];
    NSString *path = [MCMFilzaVirtualRoot() stringByAppendingPathComponent:
        @"App Manager AppData Sync Diagnostics.txt"];
    [report writeToFile:path atomically:YES
        encoding:NSUTF8StringEncoding error:nil];
}

static void scheduleCatalogC2Sync(void) {
    NSArray<NSString *> *identifiers = MHADeviceCatalogIdentifiers();
    if (identifiers.count == 0) return;

    dispatch_async(appManagerC2SyncQueue(), ^{
        NSSet<NSString *> *validIdentifiers = [NSSet setWithArray:identifiers];
        NSArray<NSString *> *existingIdentifiers =
            MCMFilzaAppDataIdentifiers();
        NSMutableArray<NSString *> *added = [NSMutableArray array];
        NSMutableArray<NSString *> *removed = [NSMutableArray array];
        NSMutableArray<NSString *> *failures = [NSMutableArray array];

        for (NSString *identifier in existingIdentifiers) {
            if ([validIdentifiers containsObject:identifier] ||
                MCMFilzaAppDataPath(identifier).length > 0)
                continue;
            NSString *error = nil;
            if (MCMFilzaRemoveAppDataLink(identifier, &error)) {
                [removed addObject:identifier];
            } else {
                [failures addObject:[NSString stringWithFormat:
                    @"remove %@: %@", identifier, error ?: @"unknown"]];
            }
        }

        for (NSString *identifier in identifiers) {
            if (![(MHADeviceCatalogApplicationType(identifier) ?: @"")
                    isEqualToString:@"User"] ||
                MCMFilzaAppDataPath(identifier).length > 0)
                continue;
            NSString *error = nil;
            if (MCMFilzaEnsureAppDataLink(identifier, &error)) {
                [added addObject:identifier];
            } else {
                [failures addObject:[NSString stringWithFormat:
                    @"lookup %@: %@", identifier, error ?: @"unknown"]];
            }
        }

        NSUInteger finalCount = MCMFilzaAppDataIdentifiers().count;
        writeAppDataSyncDiagnostics(identifiers.count,
            existingIdentifiers.count, added, removed, failures, finalCount);
        NSLog(@"[MHA-APPMGR] RSD-to-C2 sync catalog=%lu before=%lu added=%lu removed=%lu failed=%lu after=%lu",
            (unsigned long)identifiers.count,
            (unsigned long)existingIdentifiers.count,
            (unsigned long)added.count, (unsigned long)removed.count,
            (unsigned long)failures.count, (unsigned long)finalCount);
        if (added.count > 0 || removed.count > 0)
            scheduleVisibleAppManagerCatalogueReload();
    });
}

static id hook_appItemIconPath(id self, SEL _cmd) {
    NSString *bundleId = appManagerObjectValue(self,
        NSSelectorFromString(@"bundleId"));
    NSString *cached = MHADeviceCatalogIconPath(bundleId);
    if (cached.length > 0) return cached;
    id path = ((id(*)(id, SEL))orig_appItemIconPath)(self, _cmd);
    if ([path isKindOfClass:NSString.class] && [path length] > 0) return path;
    return nil;
}

// Filza's native loadAppSize cancellation path waits synchronously for its
// worker. On this jailed build that worker can still block even when the
// ApplicationItem proxy exposes cached size getters, freezing the main thread
// when App Manager opens. hook_setAppProxy already writes the cached total to
// fileSize/aFileSizeString, so the native worker is unnecessary for display or
// sorting and both entry points must remain non-blocking.
static void hook_loadAppSize(id self, SEL _cmd) {
    NSLog(@"[MHA-APPMGR] using cached installation_proxy disk sizes; skipped native size worker");
}

static void hook_cancelAppSizeCalcSync(id self, SEL _cmd) {}

static id appManagerItemForIndexPath(id browser, id indexPath) {
    id dataSource = appManagerObjectValue(browser,
        NSSelectorFromString(@"dataSource"));
    SEL selector = NSSelectorFromString(
        @"browserView:itemForSectionAtIndexPath:");
    if (!dataSource || ![dataSource respondsToSelector:selector]) return nil;
    @try {
        return ((id(*)(id, SEL, id, id))objc_msgSend)(dataSource, selector,
            browser, indexPath);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *appManagerRenderedName(id item) {
    NSString *bundleId = appManagerObjectValue(item,
        NSSelectorFromString(@"bundleId"));
    id proxy = appManagerObjectValue(item,
        NSSelectorFromString(@"appProxy"));
    if (bundleId.length == 0 &&
        [proxy respondsToSelector:@selector(applicationIdentifier)])
        bundleId = ((id(*)(id, SEL))objc_msgSend)(proxy,
            @selector(applicationIdentifier));

    NSString *name = appManagerObjectValue(item,
        NSSelectorFromString(@"aFileName"));
    if (isAppManagerPlaceholderName(name) || [name isEqualToString:bundleId])
        name = systemApplicationDisplayName(proxy, bundleId);
    if (isAppManagerPlaceholderName(name)) name = nil;
    if (name.length > 0 && ![name isEqualToString:bundleId] &&
        [item respondsToSelector:NSSelectorFromString(@"setAFileName:")])
        ((void(*)(id, SEL, id))objc_msgSend)(item,
            NSSelectorFromString(@"setAFileName:"), name);
    return name.length > 0 ? name : bundleId;
}

static void applyAppManagerCellMetadata(id browser, id cell, id indexPath) {
    if (!cell) return;
    gVisibleAppManagerBrowser = browser;
    id item = appManagerItemForIndexPath(browser, indexPath);
    NSString *name = appManagerRenderedName(item);
    id nameLabel = appManagerObjectValue(cell,
        NSSelectorFromString(@"nameLabel"));
    if (name.length > 0 &&
        [nameLabel respondsToSelector:NSSelectorFromString(@"setText:")])
        ((void(*)(id, SEL, id))objc_msgSend)(nameLabel,
            NSSelectorFromString(@"setText:"), name);

    NSString *bundleId = appManagerObjectValue(item,
        NSSelectorFromString(@"bundleId"));
    id detailLabel = appManagerObjectValue(cell,
        NSSelectorFromString(@"detailLabel"));
    if (bundleId.length > 0 &&
        [detailLabel respondsToSelector:NSSelectorFromString(@"setText:")])
        ((void(*)(id, SEL, id))objc_msgSend)(detailLabel,
            NSSelectorFromString(@"setText:"), bundleId);

    NSString *iconPath = appManagerObjectValue(item,
        NSSelectorFromString(@"iconPath"));
    UIImage *icon = iconPath.length > 0
        ? [UIImage imageWithContentsOfFile:iconPath] : nil;
    id iconImageView = appManagerObjectValue(cell,
        NSSelectorFromString(@"iconImageView"));
    if ([iconImageView respondsToSelector:NSSelectorFromString(@"setImage:")])
        ((void(*)(id, SEL, id))objc_msgSend)(iconImageView,
            NSSelectorFromString(@"setImage:"), icon);

    static dispatch_once_t rowDiagnosticsOnce;
    dispatch_once(&rowDiagnosticsOnce, ^{
        NSString *aFileName = appManagerObjectValue(item,
            NSSelectorFromString(@"aFileName"));
        NSString *fileName = appManagerObjectValue(item,
            NSSelectorFromString(@"fileName"));
        NSString *documentPath = appManagerObjectValue(item,
            NSSelectorFromString(@"documentPath"));
        NSString *rsdName = MHADeviceCatalogDisplayName(bundleId);
        NSString *rsdIconPath = MHADeviceCatalogIconPath(bundleId);
        NSString *report = [NSString stringWithFormat:
            @"App Manager row diagnostics\n\n"
             "Build marker: AppManager-CachedDiskUsage-NoFreeze-v20\n"
             "browser class: %@\nitem class: %@\ncell class: %@\n"
             "bundleId: %@\naFileName: %@\nfileName: %@\n"
             "documentPath: %@\nRSD cached name: %@\n"
             "rendered name: %@\nitem iconPath: %@\nRSD iconPath: %@\n"
             "RSD status: %@\n",
            NSStringFromClass([browser class]), NSStringFromClass([item class]),
            NSStringFromClass([cell class]), bundleId ?: @"(nil)",
            aFileName ?: @"(nil)", fileName ?: @"(nil)",
            documentPath ?: @"(nil)", rsdName ?: @"(nil)",
            name ?: @"(nil)", iconPath ?: @"(nil)",
            rsdIconPath ?: @"(nil)", MHADeviceCatalogStatus()];
        NSString *path = [MCMFilzaVirtualRoot()
            stringByAppendingPathComponent:
                @"App Manager Row Diagnostics.txt"];
        [report writeToFile:path atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    });
}

static id hook_appTableCell(id self, SEL _cmd, id tableView,
                            id indexPath) {
    id cell = ((id(*)(id, SEL, id, id))orig_appTableCell)(self, _cmd,
        tableView, indexPath);
    applyAppManagerCellMetadata(self, cell, indexPath);
    return cell;
}

static id hook_appCollectionCell(id self, SEL _cmd, id collectionView,
                                 id indexPath) {
    id cell = ((id(*)(id, SEL, id, id))orig_appCollectionCell)(self, _cmd,
        collectionView, indexPath);
    applyAppManagerCellMetadata(self, cell, indexPath);
    id iconImageView = appManagerObjectValue(cell,
        NSSelectorFromString(@"iconImageView"));
    if ([iconImageView respondsToSelector:@selector(setContentMode:)])
        ((void(*)(id, SEL, UIViewContentMode))objc_msgSend)(iconImageView,
            @selector(setContentMode:), UIViewContentModeScaleAspectFit);
    if ([iconImageView respondsToSelector:@selector(setClipsToBounds:)])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(iconImageView,
            @selector(setClipsToBounds:), YES);
    return cell;
}

static char kAppManagerSearchItemsKey;
static char kAppManagerSearchMatchesKey;
static char kAppManagerSearchSourceBrowserKey;
static char kAppManagerSearchSourceControllerKey;
static IMP orig_appManagerSearchButton = NULL;
static IMP orig_appManagerSortMode = NULL;
static IMP orig_searchControllerTextDidChange = NULL;
static IMP orig_searchControllerViewDidLoad = NULL;
static IMP orig_searchControllerNumberOfItems = NULL;
static IMP orig_searchControllerItemAtIndexPath = NULL;
static IMP orig_searchControllerDidSelectItem = NULL;
static BOOL gAppManagerSearchHooksInstalled = NO;
static BOOL gAppManagerSortHookInstalled = NO;

static void hook_appManagerSortMode(id self, SEL _cmd, id toolbar,
                                    id sortInfo) {
    if (orig_appManagerSortMode)
        ((void(*)(id, SEL, id, id))orig_appManagerSortMode)(self, _cmd,
            toolbar, sortInfo);

    // TIGIBrowserView clears currentSortMode on the third tap but its empty
    // dictionary branch omits the same delegate callback and reload used by
    // ascending/descending. Complete that branch for ApplicationsBrowserView.
    if (![sortInfo isKindOfClass:NSDictionary.class] ||
            [(NSDictionary *)sortInfo count] != 0)
        return;

    id controller = appManagerObjectValue(self,
        NSSelectorFromString(@"viewController"));
    SEL loadSelector = NSSelectorFromString(@"loadFilesWithSortMode:");
    if (![controller respondsToSelector:loadSelector])
        controller = appManagerObjectValue(self,
            NSSelectorFromString(@"delegate"));
    if (![controller respondsToSelector:loadSelector])
        controller = appManagerObjectValue(self,
            NSSelectorFromString(@"dataSource"));

    if ([controller respondsToSelector:loadSelector]) {
        // sortWithMode:0 only compares the already-sorted array. Re-enumerate
        // the application catalogue so mode 0 gets its original source order,
        // which is the same effective operation as the successful pull refresh.
        ((void(*)(id, SEL, int))objc_msgSend)(controller, loadSelector, 0);
        NSLog(@"[MHA-APPMGR] reloaded catalogue for unsorted mode");
        return;
    }

    SEL callback = NSSelectorFromString(@"browserView:willSortWithSortMode:");
    if ([controller respondsToSelector:callback])
        ((void(*)(id, SEL, id, int))objc_msgSend)(controller, callback,
            self, 0);
    if ([self respondsToSelector:@selector(reloadData)])
        ((void(*)(id, SEL))objc_msgSend)(self, @selector(reloadData));
}

static dispatch_queue_t appManagerSearchDiagnosticsQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "local.research.mha.app-manager-search-diagnostics",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSArray *appManagerItemsSnapshot(id browser) {
    id controller = appManagerObjectValue(browser,
        NSSelectorFromString(@"dataSource"));
    if (!controller)
        controller = appManagerObjectValue(browser,
            NSSelectorFromString(@"viewController"));
    NSMutableArray *items = [NSMutableArray array];
    SEL sectionsSelector = NSSelectorFromString(
        @"numberOfSectionsInBrowserView:");
    SEL countSelector = NSSelectorFromString(
        @"browserView:numberOfItemsInSection:");
    NSInteger sections = [controller respondsToSelector:sectionsSelector]
        ? ((NSInteger(*)(id, SEL, id))objc_msgSend)(controller,
            sectionsSelector, browser) : 1;
    if ([controller respondsToSelector:countSelector]) {
        for (NSInteger section = 0; section < MAX(sections, 1); section++) {
            NSInteger count = ((NSInteger(*)(id, SEL, id, NSInteger))objc_msgSend)(
                controller, countSelector, browser, section);
            for (NSInteger index = 0; index < count; index++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForItem:index
                    inSection:section];
                id item = appManagerItemForIndexPath(browser, indexPath);
                if (item) [items addObject:item];
            }
        }
    }
    if (items.count == 0) {
        id fileList = appManagerObjectValue(controller,
            NSSelectorFromString(@"fileList"));
        NSUInteger count = [fileList respondsToSelector:@selector(count)]
            ? ((NSUInteger(*)(id, SEL))objc_msgSend)(fileList, @selector(count)) : 0;
        for (NSUInteger index = 0; index < count; index++) {
            id item = [fileList respondsToSelector:@selector(objectAtIndex:)]
                ? ((id(*)(id, SEL, NSUInteger))objc_msgSend)(fileList,
                    @selector(objectAtIndex:), index) : nil;
            if (item) [items addObject:item];
        }
    }
    return items.copy;
}

static void hook_appManagerSearchButton(id self, SEL _cmd, id toolbar,
                                        BOOL selected) {
    Class applicationsBrowser = NSClassFromString(@"ApplicationsBrowserView");
    Class searchClass = NSClassFromString(@"SearchController");
    if (!applicationsBrowser || ![self isKindOfClass:applicationsBrowser] ||
        !searchClass) {
        ((void(*)(id, SEL, id, BOOL))orig_appManagerSearchButton)(self, _cmd,
            toolbar, selected);
        return;
    }

    id controller = appManagerObjectValue(self,
        NSSelectorFromString(@"viewController"));
    id searchController = [[searchClass alloc] init];
    NSArray *items = appManagerItemsSnapshot(self);
    objc_setAssociatedObject(searchController, &kAppManagerSearchItemsKey,
        items, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id sourceController = appManagerObjectValue(self,
        NSSelectorFromString(@"dataSource")) ?: controller;
    objc_setAssociatedObject(searchController,
        &kAppManagerSearchSourceBrowserKey, self,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(searchController,
        &kAppManagerSearchSourceControllerKey, sourceController,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *currentPath = appManagerObjectValue(controller,
        NSSelectorFromString(@"currentPath"));
    if ([searchController respondsToSelector:NSSelectorFromString(
            @"setCurrentDirectory:")])
        ((void(*)(id, SEL, id))objc_msgSend)(searchController,
            NSSelectorFromString(@"setCurrentDirectory:"), currentPath);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(searchController,
        NSSelectorFromString(@"showSearchViewAnimated:"), YES);
    NSLog(@"[MHA-APPMGR] opened application-record search items=%lu",
        (unsigned long)items.count);
}

static void hook_searchControllerEditingChanged(id self, SEL _cmd,
                                                id textField) {
    if (!objc_getAssociatedObject(self, &kAppManagerSearchItemsKey)) return;
    id searchBar = appManagerObjectValue(self,
        NSSelectorFromString(@"searchBar"));
    NSString *text = appManagerObjectValue(textField,
        NSSelectorFromString(@"text"));
    ((void(*)(id, SEL, id, id))objc_msgSend)(self,
        NSSelectorFromString(@"searchBar:textDidChange:"), searchBar,
        text ?: @"");
}

static void hook_searchControllerViewDidLoad(id self, SEL _cmd) {
    ((void(*)(id, SEL))orig_searchControllerViewDidLoad)(self, _cmd);
    if (!objc_getAssociatedObject(self, &kAppManagerSearchItemsKey)) return;

    id searchBar = appManagerObjectValue(self,
        NSSelectorFromString(@"searchBar"));
    id textField = appManagerObjectValue(searchBar,
        NSSelectorFromString(@"searchTextField"));
    SEL action = NSSelectorFromString(@"mha_appManagerSearchEditingChanged:");
    if ([textField respondsToSelector:@selector(addTarget:action:forControlEvents:)])
        ((void(*)(id, SEL, id, SEL, UIControlEvents))objc_msgSend)(textField,
            @selector(addTarget:action:forControlEvents:), self, action,
            UIControlEventEditingChanged);
}

static void hook_searchControllerTextDidChange(id self, SEL _cmd,
                                               id searchBar, id value) {
    NSArray *items = objc_getAssociatedObject(self,
        &kAppManagerSearchItemsKey);
    if (!items) {
        ((void(*)(id, SEL, id, id))orig_searchControllerTextDidChange)(
            self, _cmd, searchBar, value);
        return;
    }

    NSString *callbackText = [value isKindOfClass:NSString.class]
        ? value : nil;
    NSString *barText = appManagerObjectValue(searchBar,
        NSSelectorFromString(@"text"));
    id searchTextField = appManagerObjectValue(searchBar,
        NSSelectorFromString(@"searchTextField"));
    NSString *fieldText = appManagerObjectValue(searchTextField,
        NSSelectorFromString(@"text"));
    NSString *effectiveText = callbackText.length > 0 ? callbackText :
        (fieldText.length > 0 ? fieldText : (barText ?: callbackText ?: @""));
    NSString *query = [effectiveText stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *matches = [NSMutableArray array];
    NSStringCompareOptions options = NSCaseInsensitiveSearch |
        NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    if (query.length > 0) {
        for (id item in items) {
            NSString *bundleId = appManagerObjectValue(item,
                NSSelectorFromString(@"bundleId"));
            NSString *name = appManagerRenderedName(item);
            BOOL nameMatches = name.length > 0 && [name rangeOfString:query
                options:options].location != NSNotFound;
            BOOL identifierMatches = bundleId.length > 0 &&
                [bundleId rangeOfString:query
                    options:options].location != NSNotFound;
            if (nameMatches || identifierMatches) [matches addObject:item];
        }
    }

    objc_setAssociatedObject(self, &kAppManagerSearchMatchesKey, matches.copy,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([self respondsToSelector:NSSelectorFromString(@"setText:")])
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setText:"), value);
    id foundProxies = appManagerObjectValue(self,
        NSSelectorFromString(@"foundProxiesList"));
    if ([foundProxies respondsToSelector:@selector(removeAllObjects)] &&
        [foundProxies respondsToSelector:@selector(addObjectsFromArray:)]) {
        ((void(*)(id, SEL))objc_msgSend)(foundProxies,
            @selector(removeAllObjects));
        ((void(*)(id, SEL, id))objc_msgSend)(foundProxies,
            @selector(addObjectsFromArray:), matches);
    } else if ([self respondsToSelector:NSSelectorFromString(
            @"setFoundProxiesList:")]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setFoundProxiesList:"), matches);
    }
    if ([self respondsToSelector:NSSelectorFromString(
            @"setIntCurrentProxyCount:")])
        ((void(*)(id, SEL, int))objc_msgSend)(self,
            NSSelectorFromString(@"setIntCurrentProxyCount:"),
            (int)MIN(matches.count, (NSUInteger)INT_MAX));
    id autocompleteList = appManagerObjectValue(self,
        NSSelectorFromString(@"autocompleteTextListView"));
    if ([autocompleteList respondsToSelector:@selector(setAlpha:)])
        ((void(*)(id, SEL, CGFloat))objc_msgSend)(autocompleteList,
            @selector(setAlpha:), query.length > 0 ? 0.0 : 1.0);
    id browser = appManagerObjectValue(self,
        NSSelectorFromString(@"browserView"));
    if ([browser respondsToSelector:@selector(reloadData)])
        ((void(*)(id, SEL))objc_msgSend)(browser, @selector(reloadData));

    id pageObject = appManagerObjectValue(self,
        NSSelectorFromString(@"pageObject"));
    id pageFileList = appManagerObjectValue(pageObject,
        NSSelectorFromString(@"fileList"));
    NSUInteger proxyCount = [foundProxies respondsToSelector:@selector(count)]
        ? ((NSUInteger(*)(id, SEL))objc_msgSend)(foundProxies,
            @selector(count)) : 0;
    NSUInteger pageCount = [pageFileList respondsToSelector:@selector(count)]
        ? ((NSUInteger(*)(id, SEL))objc_msgSend)(pageFileList,
            @selector(count)) : 0;
    id firstMatch = matches.firstObject;
    NSString *firstBundleId = appManagerObjectValue(firstMatch,
        NSSelectorFromString(@"bundleId"));
    NSString *firstName = firstMatch ? appManagerRenderedName(firstMatch) : nil;
    CGFloat autocompleteAlpha =
        [autocompleteList respondsToSelector:@selector(alpha)]
            ? ((CGFloat(*)(id, SEL))objc_msgSend)(autocompleteList,
                @selector(alpha)) : -1.0;
    NSString *report = [NSString stringWithFormat:
        @"App Manager search diagnostics\n\n"
         "Build marker: AppManager-CachedDiskUsage-NoFreeze-v20\n"
         "controller class: %@\ncallback value class: %@\n"
         "callback text: %@\nsearch bar text: %@\n"
         "search field text: %@\neffective query: %@\n"
         "source items: %lu\n"
         "matches: %lu\nfirst match class: %@\n"
         "first match name: %@\nfirst match bundleId: %@\n"
         "result proxy class: %@\nresult proxy count: %lu\n"
         "browser class: %@\nbrowser dataSource class: %@\n"
         "page class: %@\npage fileList class: %@\npage fileList count: %lu\n"
         "autocomplete list class: %@\nautocomplete alpha: %.1f\n"
         "search selection exits search session: enabled\n"
         "direct SearchController data source: enabled\n",
        NSStringFromClass([self class]),
        value ? NSStringFromClass([value class]) : @"(nil)",
        callbackText ?: @"(nil)", barText ?: @"(nil)",
        fieldText ?: @"(nil)", query ?: @"(nil)",
        (unsigned long)items.count, (unsigned long)matches.count,
        firstMatch ? NSStringFromClass([firstMatch class]) : @"(nil)",
        firstName ?: @"(nil)", firstBundleId ?: @"(nil)",
        foundProxies ? NSStringFromClass([foundProxies class]) : @"(nil)",
        (unsigned long)proxyCount,
        browser ? NSStringFromClass([browser class]) : @"(nil)",
        NSStringFromClass([[browser dataSource] class]) ?: @"(nil)",
        pageObject ? NSStringFromClass([pageObject class]) : @"(nil)",
        pageFileList ? NSStringFromClass([pageFileList class]) : @"(nil)",
        (unsigned long)pageCount,
        autocompleteList ? NSStringFromClass([autocompleteList class]) : @"(nil)",
        autocompleteAlpha];
    NSString *path = [MCMFilzaVirtualRoot() stringByAppendingPathComponent:
        @"App Manager Search Diagnostics.txt"];
    dispatch_async(appManagerSearchDiagnosticsQueue(), ^{
        [report writeToFile:path atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    });
}

static NSInteger hook_searchControllerNumberOfItems(id self, SEL _cmd,
                                                     id browser,
                                                     NSInteger section) {
    NSArray *items = objc_getAssociatedObject(self,
        &kAppManagerSearchItemsKey);
    if (items) {
        NSArray *matches = objc_getAssociatedObject(self,
            &kAppManagerSearchMatchesKey);
        return (NSInteger)matches.count;
    }
    return ((NSInteger(*)(id, SEL, id, NSInteger))
        orig_searchControllerNumberOfItems)(self, _cmd, browser, section);
}

static id hook_searchControllerItemAtIndexPath(id self, SEL _cmd,
                                               id browser,
                                               NSIndexPath *indexPath) {
    NSArray *items = objc_getAssociatedObject(self,
        &kAppManagerSearchItemsKey);
    if (items) {
        NSArray *matches = objc_getAssociatedObject(self,
            &kAppManagerSearchMatchesKey);
        NSInteger row = indexPath.row;
        return row >= 0 && (NSUInteger)row < matches.count
            ? matches[(NSUInteger)row] : nil;
    }
    return ((id(*)(id, SEL, id, id))orig_searchControllerItemAtIndexPath)(
        self, _cmd, browser, indexPath);
}

static NSUInteger appManagerSourceIndexForItem(id controller, id targetItem) {
    id fileList = appManagerObjectValue(controller,
        NSSelectorFromString(@"fileList"));
    NSUInteger count = [fileList respondsToSelector:@selector(count)]
        ? ((NSUInteger(*)(id, SEL))objc_msgSend)(fileList, @selector(count)) : 0;
    NSString *targetBundleId = appManagerObjectValue(targetItem,
        NSSelectorFromString(@"bundleId"));
    for (NSUInteger index = 0; index < count; index++) {
        id candidate = [fileList respondsToSelector:@selector(objectAtIndex:)]
            ? ((id(*)(id, SEL, NSUInteger))objc_msgSend)(fileList,
                @selector(objectAtIndex:), index) : nil;
        if (candidate == targetItem) return index;
        NSString *candidateBundleId = appManagerObjectValue(candidate,
            NSSelectorFromString(@"bundleId"));
        if (targetBundleId.length > 0 &&
            [candidateBundleId isEqualToString:targetBundleId])
            return index;
    }
    return NSNotFound;
}

static void hook_searchControllerDidSelectItem(id self, SEL _cmd, id browser,
                                               NSIndexPath *indexPath) {
    NSArray *items = objc_getAssociatedObject(self,
        &kAppManagerSearchItemsKey);
    if (!items) {
        ((void(*)(id, SEL, id, id))orig_searchControllerDidSelectItem)(
            self, _cmd, browser, indexPath);
        return;
    }

    NSArray *matches = objc_getAssociatedObject(self,
        &kAppManagerSearchMatchesKey);
    NSInteger row = indexPath.row;
    id selectedItem = row >= 0 && (NSUInteger)row < matches.count
        ? matches[(NSUInteger)row] : nil;
    id sourceBrowser = objc_getAssociatedObject(self,
        &kAppManagerSearchSourceBrowserKey);
    id sourceController = objc_getAssociatedObject(self,
        &kAppManagerSearchSourceControllerKey);
    NSUInteger sourceIndex = selectedItem
        ? appManagerSourceIndexForItem(sourceController, selectedItem)
        : NSNotFound;
    SEL sourceSelection = NSSelectorFromString(
        @"browserView:didSelectItemAtIndexPath:");
    if (!sourceBrowser || ![sourceController respondsToSelector:sourceSelection] ||
        sourceIndex == NSNotFound) {
        ((void(*)(id, SEL, id, id))orig_searchControllerDidSelectItem)(
            self, _cmd, browser, indexPath);
        return;
    }

    NSString *bundleId = appManagerObjectValue(selectedItem,
        NSSelectorFromString(@"bundleId"));
    NSIndexPath *sourceIndexPath = [NSIndexPath indexPathForRow:
        (NSInteger)sourceIndex inSection:0];
    if ([self respondsToSelector:NSSelectorFromString(@"cancelAnimated:")])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self,
            NSSelectorFromString(@"cancelAnimated:"), NO);
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void(*)(id, SEL, id, id))objc_msgSend)(sourceController,
            sourceSelection, sourceBrowser, sourceIndexPath);
        NSLog(@"[MHA-APPMGR] routed search result %@ into main session",
            bundleId ?: @"(unknown)");
    });
}

static void installAppManagerHooks(void) {
    Class lsWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (lsWorkspace) {
        Method method = class_getInstanceMethod(lsWorkspace,
            NSSelectorFromString(@"allApplications"));
        if (method) {
            IMP current = method_getImplementation(method);
            if (current != (IMP)hook_allApplications) {
                if (!orig_allApplications) orig_allApplications = current;
                method_setImplementation(method, (IMP)hook_allApplications);
            }
            gLSWorkspaceHookInstalled =
                method_getImplementation(method) == (IMP)hook_allApplications;
        }
    }

    Class appItem = NSClassFromString(@"ApplicationItem");
    if (appItem) {
        SEL setterSelector = NSSelectorFromString(@"setAppProxy:");
        Method setter = class_getInstanceMethod(appItem, setterSelector);
        if (setter) {
            IMP current = method_getImplementation(setter);
            if (current != (IMP)hook_setAppProxy) {
                if (!orig_setAppProxy) orig_setAppProxy = current;
                method_setImplementation(setter, (IMP)hook_setAppProxy);
            }
            gAppItemSetterHookInstalled =
                method_getImplementation(setter) == (IMP)hook_setAppProxy;
        }

        SEL fileNameSelector = NSSelectorFromString(@"fileName");
        Method fileName = class_getInstanceMethod(appItem, fileNameSelector);
        if (fileName) {
            IMP current = class_getMethodImplementation(appItem,
                fileNameSelector);
            if (current != (IMP)hook_appItemFileName) {
                if (!orig_appItemFileName) orig_appItemFileName = current;
                const char *types = method_getTypeEncoding(fileName);
                if (!class_addMethod(appItem, fileNameSelector,
                        (IMP)hook_appItemFileName, types))
                    method_setImplementation(fileName,
                        (IMP)hook_appItemFileName);
            }
            gAppItemFileNameHookInstalled =
                class_getMethodImplementation(appItem, fileNameSelector) ==
                    (IMP)hook_appItemFileName;
        }

        SEL iconPathSelector = NSSelectorFromString(@"iconPath");
        Method iconPath = class_getInstanceMethod(appItem, iconPathSelector);
        if (iconPath) {
            IMP current = method_getImplementation(iconPath);
            if (current != (IMP)hook_appItemIconPath) {
                if (!orig_appItemIconPath) orig_appItemIconPath = current;
                method_setImplementation(iconPath, (IMP)hook_appItemIconPath);
            }
            gAppItemIconHookInstalled =
                method_getImplementation(iconPath) == (IMP)hook_appItemIconPath;
        }
    }

    Class applicationsController =
        NSClassFromString(@"TGApplicationsViewController");
    if (applicationsController) {
        Method loadSize = class_getInstanceMethod(applicationsController,
            NSSelectorFromString(@"loadAppSize"));
        Method cancelSize = class_getInstanceMethod(applicationsController,
            NSSelectorFromString(@"cancelAppSizeCalcSync"));
        if (loadSize && method_getImplementation(loadSize) !=
                (IMP)hook_loadAppSize)
            method_setImplementation(loadSize, (IMP)hook_loadAppSize);
        if (cancelSize && method_getImplementation(cancelSize) !=
                (IMP)hook_cancelAppSizeCalcSync)
            method_setImplementation(cancelSize,
                (IMP)hook_cancelAppSizeCalcSync);
        gAppSizeHooksInstalled = gAppItemSetterHookInstalled &&
            loadSize && cancelSize &&
            method_getImplementation(loadSize) == (IMP)hook_loadAppSize &&
            method_getImplementation(cancelSize) ==
                (IMP)hook_cancelAppSizeCalcSync;
    }

    Class browserClass = NSClassFromString(@"ApplicationsBrowserView");
    if (browserClass) {
        SEL sortSelector = NSSelectorFromString(
            @"TopToolbarView:didSelectSortMode:");
        Method sortMethod = class_getInstanceMethod(browserClass,
            sortSelector);
        IMP currentSort = class_getMethodImplementation(browserClass,
            sortSelector);
        if (sortMethod && currentSort != (IMP)hook_appManagerSortMode) {
            if (!orig_appManagerSortMode)
                orig_appManagerSortMode = currentSort;
            class_replaceMethod(browserClass, sortSelector,
                (IMP)hook_appManagerSortMode,
                method_getTypeEncoding(sortMethod));
        }
        gAppManagerSortHookInstalled = sortMethod &&
            class_getMethodImplementation(browserClass, sortSelector) ==
                (IMP)hook_appManagerSortMode;

        SEL tableSelector =
            NSSelectorFromString(@"tableView:cellForRowAtIndexPath:");
        Method tableMethod = class_getInstanceMethod(browserClass,
            tableSelector);
        if (tableMethod) {
            IMP current = method_getImplementation(tableMethod);
            if (current != (IMP)hook_appTableCell) {
                if (!orig_appTableCell) orig_appTableCell = current;
                method_setImplementation(tableMethod,
                    (IMP)hook_appTableCell);
            }
        }
        SEL collectionSelector = NSSelectorFromString(
            @"collectionView:cellForItemAtIndexPath:");
        Method collectionMethod = class_getInstanceMethod(browserClass,
            collectionSelector);
        if (collectionMethod) {
            IMP current = method_getImplementation(collectionMethod);
            if (current != (IMP)hook_appCollectionCell) {
                if (!orig_appCollectionCell) orig_appCollectionCell = current;
                method_setImplementation(collectionMethod,
                    (IMP)hook_appCollectionCell);
            }
        }
        gAppBrowserCellHooksInstalled = tableMethod && collectionMethod &&
            method_getImplementation(tableMethod) == (IMP)hook_appTableCell &&
            method_getImplementation(collectionMethod) ==
                (IMP)hook_appCollectionCell;

        SEL searchButtonSelector = NSSelectorFromString(
            @"TopToolbarView:didSelectSearchButton:");
        Method searchButtonMethod = class_getInstanceMethod(browserClass,
            searchButtonSelector);
        IMP currentSearchButton = class_getMethodImplementation(browserClass,
            searchButtonSelector);
        if (searchButtonMethod && currentSearchButton !=
                (IMP)hook_appManagerSearchButton) {
            if (!orig_appManagerSearchButton)
                orig_appManagerSearchButton = currentSearchButton;
            const char *types = method_getTypeEncoding(searchButtonMethod);
            if (!class_addMethod(browserClass, searchButtonSelector,
                    (IMP)hook_appManagerSearchButton, types))
                method_setImplementation(searchButtonMethod,
                    (IMP)hook_appManagerSearchButton);
        }
    }

    Class searchController = NSClassFromString(@"SearchController");
    SEL searchEditingSelector = NSSelectorFromString(
        @"mha_appManagerSearchEditingChanged:");
    if (searchController && !class_getInstanceMethod(searchController,
            searchEditingSelector))
        class_addMethod(searchController, searchEditingSelector,
            (IMP)hook_searchControllerEditingChanged, "v@:@");

    SEL searchViewDidLoadSelector = @selector(viewDidLoad);
    Method searchViewDidLoadMethod = class_getInstanceMethod(searchController,
        searchViewDidLoadSelector);
    if (searchViewDidLoadMethod &&
            method_getImplementation(searchViewDidLoadMethod) !=
                (IMP)hook_searchControllerViewDidLoad) {
        if (!orig_searchControllerViewDidLoad)
            orig_searchControllerViewDidLoad =
                method_getImplementation(searchViewDidLoadMethod);
        method_setImplementation(searchViewDidLoadMethod,
            (IMP)hook_searchControllerViewDidLoad);
    }

    SEL searchTextSelector = NSSelectorFromString(@"searchBar:textDidChange:");
    Method searchTextMethod = class_getInstanceMethod(searchController,
        searchTextSelector);
    if (searchTextMethod && method_getImplementation(searchTextMethod) !=
            (IMP)hook_searchControllerTextDidChange) {
        if (!orig_searchControllerTextDidChange)
            orig_searchControllerTextDidChange =
                method_getImplementation(searchTextMethod);
        method_setImplementation(searchTextMethod,
            (IMP)hook_searchControllerTextDidChange);
    }

    SEL searchCountSelector = NSSelectorFromString(
        @"browserView:numberOfItemsInSection:");
    Method searchCountMethod = class_getInstanceMethod(searchController,
        searchCountSelector);
    if (searchCountMethod && method_getImplementation(searchCountMethod) !=
            (IMP)hook_searchControllerNumberOfItems) {
        if (!orig_searchControllerNumberOfItems)
            orig_searchControllerNumberOfItems =
                method_getImplementation(searchCountMethod);
        method_setImplementation(searchCountMethod,
            (IMP)hook_searchControllerNumberOfItems);
    }

    SEL searchItemSelector = NSSelectorFromString(
        @"browserView:itemForSectionAtIndexPath:");
    Method searchItemMethod = class_getInstanceMethod(searchController,
        searchItemSelector);
    if (searchItemMethod && method_getImplementation(searchItemMethod) !=
            (IMP)hook_searchControllerItemAtIndexPath) {
        if (!orig_searchControllerItemAtIndexPath)
            orig_searchControllerItemAtIndexPath =
                method_getImplementation(searchItemMethod);
        method_setImplementation(searchItemMethod,
            (IMP)hook_searchControllerItemAtIndexPath);
    }
    SEL searchDidSelectSelector = NSSelectorFromString(
        @"browserView:didSelectItemAtIndexPath:");
    Method searchDidSelectMethod = class_getInstanceMethod(searchController,
        searchDidSelectSelector);
    if (searchDidSelectMethod &&
            method_getImplementation(searchDidSelectMethod) !=
                (IMP)hook_searchControllerDidSelectItem) {
        if (!orig_searchControllerDidSelectItem)
            orig_searchControllerDidSelectItem =
                method_getImplementation(searchDidSelectMethod);
        method_setImplementation(searchDidSelectMethod,
            (IMP)hook_searchControllerDidSelectItem);
    }
    gAppManagerSearchHooksInstalled = browserClass && searchController &&
        searchViewDidLoadMethod && searchTextMethod && searchCountMethod &&
        searchItemMethod && searchDidSelectMethod &&
        class_getMethodImplementation(browserClass,
            NSSelectorFromString(@"TopToolbarView:didSelectSearchButton:")) ==
                (IMP)hook_appManagerSearchButton &&
        class_getMethodImplementation(searchController,
            searchEditingSelector) ==
                (IMP)hook_searchControllerEditingChanged &&
        method_getImplementation(searchViewDidLoadMethod) ==
                (IMP)hook_searchControllerViewDidLoad &&
        method_getImplementation(searchTextMethod) ==
                (IMP)hook_searchControllerTextDidChange &&
        method_getImplementation(searchCountMethod) ==
                (IMP)hook_searchControllerNumberOfItems &&
        method_getImplementation(searchItemMethod) ==
                (IMP)hook_searchControllerItemAtIndexPath &&
        method_getImplementation(searchDidSelectMethod) ==
                (IMP)hook_searchControllerDidSelectItem;

    NSLog(@"[MHA-APPMGR] hooks workspace=%d appItem=%d setter=%d fileName=%d iconPath=%d controller=%d sizes=%d cells=%d search=%d sort=%d build=AppManager-CachedDiskUsage-NoFreeze-v20",
        gLSWorkspaceHookInstalled, appItem != Nil,
        gAppItemSetterHookInstalled, gAppItemFileNameHookInstalled,
        gAppItemIconHookInstalled, applicationsController != Nil,
        gAppSizeHooksInstalled, gAppBrowserCellHooksInstalled,
        gAppManagerSearchHooksInstalled, gAppManagerSortHookInstalled);
}

#pragma mark - License / Integrity Bypass

// Suppress "Main binary was modified" and "Not activated" alerts.
// +[TGAlertController showAlertWithTitle:text:cancelButton:otherButtons:completion:]
// checks the text parameter; if it's the integrity/activation alert, swallow it.
static IMP orig_showAlert = NULL;
static id hook_showAlertWithTitle(id self, SEL _cmd, id title, id text, id cancelButton, id otherButtons, id completion) {
    NSString *combined = [NSString stringWithFormat:@"%@ %@",
        [title isKindOfClass:NSString.class] ? title : @"",
        [text isKindOfClass:NSString.class] ? text : @""];
    NSString *lower = combined.lowercaseString;
    if ([lower containsString:@"binary was modified"] ||
        [lower containsString:@"reinstall filza"] ||
        [lower containsString:@"not activated"] ||
        [lower containsString:@"activate filza"]) {
        NSLog(@"[Tweak] Suppressed Filza integrity/activation alert");
        return nil;
    }
    // Pass through all other alerts
    return ((id(*)(id,SEL,id,id,id,id,id))orig_showAlert)(self, _cmd, title, text, cancelButton, otherButtons, completion);
}

static BOOL isFilzaActivationController(id controller) {
    Class activationClass = NSClassFromString(@"NewActivationViewController");
    if (!activationClass || !controller) return NO;
    if ([controller isKindOfClass:activationClass]) return YES;
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in
                ((UINavigationController *)controller).viewControllers)
            if ([child isKindOfClass:activationClass]) return YES;
    }
    return NO;
}

// Filza can either push NewActivationViewController or wrap it in its theme
// navigation controller and present that. Block those two exact objects before
// UIKit displays them; unrelated navigation and modal UI pass through.
static IMP orig_pushViewController = NULL;
static void hook_pushViewController(id self, SEL _cmd, id controller,
                                    BOOL animated) {
    if (isFilzaActivationController(controller)) {
        NSLog(@"[Tweak] Suppressed pushed Filza activation controller");
        return;
    }
    ((void(*)(id, SEL, id, BOOL))orig_pushViewController)(
        self, _cmd, controller, animated);
}

static IMP orig_presentViewController = NULL;
static void hook_presentViewController(id self, SEL _cmd, id controller,
                                       BOOL animated, id completion) {
    if (isFilzaActivationController(controller)) {
        NSLog(@"[Tweak] Suppressed presented Filza activation controller");
        if (completion) ((void(^)(void))completion)();
        return;
    }
    ((void(*)(id, SEL, id, BOOL, id))orig_presentViewController)(
        self, _cmd, controller, animated, completion);
}

// Suppress activation nag: -[NewActivationViewController viewDidLoad]
// This is a fallback for any caller that bypasses the normal push/present APIs.
static IMP orig_activationViewDidLoad = NULL;
static void hook_activationViewDidLoad(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_activationViewDidLoad)(self, _cmd);
    if ([self isKindOfClass:UIViewController.class])
        ((UIViewController *)self).view.hidden = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = self;
        UINavigationController *navigation = controller.navigationController;
        if (navigation.topViewController == controller) {
            if (navigation.presentingViewController)
                [navigation dismissViewControllerAnimated:NO completion:nil];
            else
                [navigation popViewControllerAnimated:NO];
        } else if (controller.presentingViewController) {
            [controller dismissViewControllerAnimated:NO completion:nil];
        }
    });
    NSLog(@"[Tweak] Removed fallback Filza activation controller");
}

#pragma mark - MCM-aware local file operations

static void setPastePOSIXError(NSError **error, int code,
                               NSString *operation, NSString *path) {
    if (!error) return;
    NSString *description = [NSString stringWithFormat:@"%@ failed for %@: %s",
        operation, path, strerror(code)];
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL directCopyItem(NSString *source, NSString *destination, NSError **error);

static BOOL directCopyRegularFile(NSString *source, NSString *destination,
                                  mode_t mode, NSError **error) {
    int input = open(source.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (input < 0) {
        setPastePOSIXError(error, errno, @"open source", source);
        return NO;
    }
    int output = open(destination.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode & 0777 ?: 0600);
    if (output < 0) {
        int saved = errno;
        close(input);
        setPastePOSIXError(error, saved, @"create destination", destination);
        return NO;
    }

    BOOL success = YES;
    uint8_t buffer[64 * 1024];
    while (success) {
        ssize_t count = read(input, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            setPastePOSIXError(error, errno, @"read", source);
            success = NO;
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(output, buffer + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                setPastePOSIXError(error, written < 0 ? errno : EIO,
                    @"write", destination);
                success = NO;
                break;
            }
            offset += written;
        }
    }
    if (success) fsync(output);
    close(output);
    close(input);
    if (!success) unlink(destination.fileSystemRepresentation);
    return success;
}

static BOOL directCopyDirectory(NSString *source, NSString *destination,
                                mode_t mode, NSError **error) {
    if (mkdir(destination.fileSystemRepresentation, mode & 0777 ?: 0700) != 0) {
        setPastePOSIXError(error, errno, @"create directory", destination);
        return NO;
    }
    DIR *directory = opendir(source.fileSystemRepresentation);
    if (!directory) {
        int saved = errno;
        rmdir(destination.fileSystemRepresentation);
        setPastePOSIXError(error, saved, @"open directory", source);
        return NO;
    }

    BOOL success = YES;
    struct dirent *entry = NULL;
    while (success && (entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name
            length:strlen(entry->d_name)];
        if (!name) {
            setPastePOSIXError(error, EILSEQ, @"decode filename", source);
            success = NO;
            break;
        }
        success = directCopyItem([source stringByAppendingPathComponent:name],
            [destination stringByAppendingPathComponent:name], error);
    }
    closedir(directory);
    if (!success)
        [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
    return success;
}

static BOOL directCopySymbolicLink(NSString *source, NSString *destination,
                                   NSError **error) {
    char target[PATH_MAX] = {0};
    ssize_t length = readlink(source.fileSystemRepresentation,
        target, sizeof(target) - 1);
    if (length < 0) {
        setPastePOSIXError(error, errno, @"read symbolic link", source);
        return NO;
    }
    target[length] = '\0';
    if (symlink(target, destination.fileSystemRepresentation) != 0) {
        setPastePOSIXError(error, errno, @"create symbolic link", destination);
        return NO;
    }
    return YES;
}

static BOOL directCopyItem(NSString *source, NSString *destination, NSError **error) {
    struct stat status = {0};
    if (lstat(source.fileSystemRepresentation, &status) != 0) {
        setPastePOSIXError(error, errno, @"inspect source", source);
        return NO;
    }
    if (S_ISREG(status.st_mode))
        return directCopyRegularFile(source, destination, status.st_mode, error);
    if (S_ISDIR(status.st_mode))
        return directCopyDirectory(source, destination, status.st_mode, error);
    if (S_ISLNK(status.st_mode))
        return directCopySymbolicLink(source, destination, error);
    setPastePOSIXError(error, ENOTSUP, @"copy unsupported item", source);
    return NO;
}

static NSString *localPathFromPasteboardValue(id value) {
    if ([value isKindOfClass:NSURL.class] && [(NSURL *)value isFileURL])
        return [(NSURL *)value path];
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *string = value;
    if (string.isAbsolutePath) return string;
    NSURL *URL = [NSURL URLWithString:string];
    if (URL.isFileURL) return URL.path;

    Class preferencesClass = NSClassFromString(@"TGPreferences");
    id preferences = [preferencesClass respondsToSelector:@selector(sharedInstance)]
        ? ((id(*)(id, SEL))objc_msgSend)(preferencesClass, @selector(sharedInstance)) : nil;
    SEL selector = NSSelectorFromString(@"urlFromString:");
    id parsed = [preferences respondsToSelector:selector]
        ? ((id(*)(id, SEL, id))objc_msgSend)(preferences, selector, string) : nil;
    return [parsed isKindOfClass:NSURL.class] && [(NSURL *)parsed isFileURL]
        ? [(NSURL *)parsed path] : nil;
}

static NSString *uniquePasteDestination(NSString *directory, NSString *name) {
    if (name.length == 0 || [name isEqualToString:@"."] ||
        [name isEqualToString:@".."] || [name containsString:@"/"]) return nil;
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    struct stat status = {0};
    if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
        return candidate;

    NSString *extension = name.pathExtension;
    NSString *stem = extension.length ? name.stringByDeletingPathExtension : name;
    for (NSUInteger index = 1; index <= 999; index++) {
        NSString *suffix = index == 1 ? @" copy"
            : [NSString stringWithFormat:@" copy %lu", (unsigned long)index];
        NSString *copyName = [stem stringByAppendingString:suffix];
        if (extension.length) copyName = [copyName stringByAppendingPathExtension:extension];
        candidate = [directory stringByAppendingPathComponent:copyName];
        if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
            return candidate;
    }
    return nil;
}

static BOOL pasteDestinationIsInsideSource(NSString *source, NSString *destinationDirectory) {
    struct stat status = {0};
    if (lstat(source.fileSystemRepresentation, &status) != 0 || !S_ISDIR(status.st_mode))
        return NO;
    char sourceReal[PATH_MAX] = {0};
    char destinationReal[PATH_MAX] = {0};
    if (!realpath(source.fileSystemRepresentation, sourceReal) ||
        !realpath(destinationDirectory.fileSystemRepresentation, destinationReal)) return NO;
    NSString *sourcePath = [NSString stringWithUTF8String:sourceReal];
    NSString *destinationPath = [NSString stringWithUTF8String:destinationReal];
    return [destinationPath isEqualToString:sourcePath] ||
        [destinationPath hasPrefix:[sourcePath stringByAppendingString:@"/"]];
}

static void showPasteFailure(UIViewController *controller, NSArray<NSError *> *errors) {
    if (errors.count == 0) return;
    NSString *message = errors.firstObject.localizedDescription ?: @"Paste failed";
    if (errors.count > 1)
        message = [NSString stringWithFormat:@"%lu items failed.\n%@",
            (unsigned long)errors.count, message];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Paste failed"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static NSArray *selectedFileItems(id controller, NSArray *indexPaths) {
    SEL fileListSelector = NSSelectorFromString(@"fileList");
    NSArray *fileList = [controller respondsToSelector:fileListSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(controller, fileListSelector) : nil;
    if (![fileList isKindOfClass:NSArray.class] ||
        ![indexPaths isKindOfClass:NSArray.class]) return @[];

    NSMutableArray *items = [NSMutableArray array];
    for (id value in indexPaths) {
        if (![value isKindOfClass:NSIndexPath.class]) continue;
        NSInteger row = [(NSIndexPath *)value row];
        if (row >= 0 && (NSUInteger)row < fileList.count)
            [items addObject:fileList[(NSUInteger)row]];
    }
    return items;
}

static NSString *fileItemPath(id item) {
    SEL selector = NSSelectorFromString(@"filePath");
    id value = [item respondsToSelector:selector]
        ? ((id(*)(id, SEL))objc_msgSend)(item, selector) : nil;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

#pragma mark - Real system path menu action

typedef NS_ENUM(NSUInteger, FilzaRealPathLanguage) {
    FilzaRealPathLanguageEnglish,
    FilzaRealPathLanguageSimplifiedChinese,
    FilzaRealPathLanguageTraditionalChinese,
};

static FilzaRealPathLanguage filzaRealPathLanguage(void) {
    NSString *language = NSBundle.mainBundle.preferredLocalizations.firstObject;
    if (!language.length)
        language = NSLocale.preferredLanguages.firstObject;
    language = language.lowercaseString;
    if ([language hasPrefix:@"zh-hant"] || [language hasPrefix:@"zh-tw"] ||
        [language hasPrefix:@"zh-hk"] || [language hasPrefix:@"zh-mo"])
        return FilzaRealPathLanguageTraditionalChinese;
    if ([language hasPrefix:@"zh"])
        return FilzaRealPathLanguageSimplifiedChinese;
    return FilzaRealPathLanguageEnglish;
}

static NSString *filzaRealPathLocalizedText(NSString *english,
                                             NSString *simplifiedChinese,
                                             NSString *traditionalChinese) {
    switch (filzaRealPathLanguage()) {
        case FilzaRealPathLanguageSimplifiedChinese:
            return simplifiedChinese;
        case FilzaRealPathLanguageTraditionalChinese:
            return traditionalChinese;
        case FilzaRealPathLanguageEnglish:
        default:
            return english;
    }
}

static NSString *filzaResolvedRealSystemPath(NSString *path, NSError **error) {
    if (!path.length || !path.isAbsolutePath) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:EINVAL userInfo:nil];
        return nil;
    }

    char resolved[PATH_MAX] = {0};
    errno = 0;
    if (!realpath(path.fileSystemRepresentation, resolved)) {
        int savedError = errno ?: ENOENT;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:savedError userInfo:nil];
        return nil;
    }

    NSString *realPath = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    if (!realPath.length && error)
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:EILSEQ userInfo:nil];
    return realPath;
}

static void showRealSystemPath(NSString *path) {
    NSError *error = nil;
    NSString *realPath = filzaResolvedRealSystemPath(path, &error);
    NSString *title = filzaRealPathLocalizedText(
        realPath ? @"Real System Path" : @"Unable to Resolve Real Path",
        realPath ? @"真实系统路径" : @"无法解析真实路径",
        realPath ? @"真實系統路徑" : @"無法解析真實路徑");
    NSString *message = realPath ?: filzaRealPathLocalizedText(
        @"The item may no longer exist, its symbolic-link target may be broken, or the target cannot be accessed.",
        @"项目可能已不存在、符号链接目标已断开，或当前无法访问该目标。",
        @"項目可能已不存在、符號連結目標已斷開，或目前無法存取該目標。");

    NSString *closeTitle = filzaRealPathLocalizedText(
        @"Close", @"关闭", @"關閉");
    NSString *copyTitle = filzaRealPathLocalizedText(
        @"Copy", @"复制", @"複製");
    NSArray *otherButtons = realPath ? @[copyTitle] : @[];

    // Reuse Filza's own alert wrapper so presentation, button ordering, and
    // theme behavior stay identical to the rest of the app.
    Class alertController = NSClassFromString(@"TGAlertController");
    SEL selector = NSSelectorFromString(
        @"showAlertWithTitle:text:cancelButton:otherButtons:completion:");
    if ([alertController respondsToSelector:selector]) {
        void (^completion)(id, NSInteger) = ^(__unused id alert,
                                                NSInteger buttonIndex) {
            // Filza assigns index 0 to the cancel button and starts the
            // other-buttons array at index 1.
            if (realPath && buttonIndex == 1) {
                UIPasteboard.generalPasteboard.string = realPath;
                NSLog(@"[RealPath] copied %@", realPath);
            }
        };
        ((id(*)(id, SEL, id, id, id, id, id))objc_msgSend)(
            alertController, selector, title, message, closeTitle,
            otherButtons, completion);
    } else {
        NSLog(@"[RealPath] TGAlertController is unavailable");
    }

    if (!realPath)
        NSLog(@"[RealPath] resolution failed path=%@ error=%@", path, error);
}

static IMP orig_pageMenuElementItemsForItem = NULL;
static id hook_pageMenuElementItemsForItem(id self, SEL _cmd, id item,
                                            id sourceView, CGRect sourceRect) {
    id originalItems = orig_pageMenuElementItemsForItem
        ? ((id(*)(id, SEL, id, id, CGRect))orig_pageMenuElementItemsForItem)(
            self, _cmd, item, sourceView, sourceRect) : nil;
    NSString *path = fileItemPath(item);
    if (!path.length || !path.isAbsolutePath)
        return originalItems;

    NSMutableArray *items = [originalItems isKindOfClass:NSArray.class]
        ? [originalItems mutableCopy] : [NSMutableArray array];
    NSString *actionTitle = filzaRealPathLocalizedText(
        @"Show Real Path", @"显示真实路径", @"顯示真實路徑");
    UIImage *image = [UIImage systemImageNamed:@"link"];
    NSString *capturedPath = [path copy];
    UIAction *action = [UIAction actionWithTitle:actionTitle image:image
        identifier:@"local.filzareborn.show-real-path"
        handler:^(__unused UIAction *selectedAction) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showRealSystemPath(capturedPath);
            });
        }];
    [items addObject:action];
    return items;
}

static BOOL pathUsesDirectFileOperations(NSString *path) {
    if (!path.length || !path.isAbsolutePath) return NO;
    if (MCMFilzaPathHasActiveLease(path)) return YES;
    NSString *candidate = path.stringByStandardizingPath;
    NSString *trash = filzaDeviceStorageTrashPath().stringByStandardizingPath;
    return [candidate isEqualToString:trash] ||
        [candidate hasPrefix:[trash stringByAppendingString:@"/"]];
}

static BOOL fileItemsUseDirectOperations(NSArray *items) {
    if (items.count == 0) return NO;
    for (id item in items) {
        NSString *path = fileItemPath(item);
        if (!pathUsesDirectFileOperations(path)) return NO;
    }
    return YES;
}

static void showDeleteFailure(UIViewController *controller,
                              NSArray<NSError *> *errors) {
    if (errors.count == 0 || ![controller isKindOfClass:UIViewController.class]) return;
    NSString *message = errors.firstObject.localizedDescription ?: @"Delete failed";
    if (errors.count > 1)
        message = [NSString stringWithFormat:@"%lu items failed.\n%@",
            (unsigned long)errors.count, message];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete failed"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void reloadFileSystemController(id controller) {
    SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
    if ([controller respondsToSelector:loadSelector])
        ((void(*)(id, SEL))objc_msgSend)(controller, loadSelector);
}

static IMP orig_fileSystemPageDeleteAction = NULL;
static IMP orig_fileSystemDeleteSelectedItems = NULL;
static IMP orig_fileSystemDoTrashSelectedItems = NULL;
static IMP orig_fileSystemDoEraseSelectedItems = NULL;
static IMP parentFileSystemAskDeleteItems = NULL;
static IMP parentFileSystemDoTrashSelectedItems = NULL;

// Filza's jailed filesystem subclass replaces delete, trash, and erase with
// no-ops. Reuse Filza's native parent trash flow for paths backed by an active
// MCM lease. Its trashDir lookup is redirected to Device Storage/.Trash above.
static NSUInteger hook_fileSystemPageDeleteAction(id self, SEL _cmd) {
    SEL selector = NSSelectorFromString(@"currentPath");
    NSString *path = [self respondsToSelector:selector]
        ? ((id(*)(id, SEL))objc_msgSend)(self, selector) : nil;
    if (pathUsesDirectFileOperations(path)) return 0x8000;
    return orig_fileSystemPageDeleteAction
        ? ((NSUInteger(*)(id, SEL))orig_fileSystemPageDeleteAction)(self, _cmd)
        : 0x8000;
}

static void hook_fileSystemDeleteSelectedItems(id self, SEL _cmd) {
    SEL selectedSelector = NSSelectorFromString(@"indexPathsForSelectedItemsOrMenu");
    NSArray *indexPaths = [self respondsToSelector:selectedSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(self, selectedSelector) : nil;
    if (!fileItemsUseDirectOperations(selectedFileItems(self, indexPaths))) {
        if (orig_fileSystemDeleteSelectedItems)
            ((void(*)(id, SEL))orig_fileSystemDeleteSelectedItems)(self, _cmd);
        return;
    }
    SEL askSelector = NSSelectorFromString(@"askDeleteItems:");
    if ([self respondsToSelector:askSelector])
        ((void(*)(id, SEL, id))objc_msgSend)(self, askSelector, indexPaths ?: @[]);
}

static void hook_fileSystemAskDeleteItems(id self, SEL _cmd, NSArray *indexPaths) {
    if (parentFileSystemAskDeleteItems)
        ((void(*)(id, SEL, id))parentFileSystemAskDeleteItems)(
            self, _cmd, indexPaths ?: @[]);
}

static void hook_fileSystemDoTrashSelectedItems(id self, SEL _cmd,
                                                 NSArray *indexPaths,
                                                 void (^completion)(NSArray *)) {
    NSArray *items = selectedFileItems(self, indexPaths);
    if (!fileItemsUseDirectOperations(items)) {
        if (orig_fileSystemDoTrashSelectedItems)
            ((void(*)(id, SEL, id, id))orig_fileSystemDoTrashSelectedItems)(
                self, _cmd, indexPaths, completion);
        return;
    }
    if (parentFileSystemDoTrashSelectedItems) {
        NSLog(@"[Trash] moving %lu item(s) through Filza native trash flow to %@",
              (unsigned long)items.count, filzaDeviceStorageTrashPath());
        ((void(*)(id, SEL, id, id))parentFileSystemDoTrashSelectedItems)(
            self, _cmd, indexPaths, completion);
    } else if (completion) {
        completion(@[]);
    }
}

static void hook_fileSystemDoEraseSelectedItems(id self, SEL _cmd,
                                                 NSArray *indexPaths,
                                                 void (^completion)(NSArray *)) {
    MCMFilzaStart();
    NSArray *items = selectedFileItems(self, indexPaths);
    if (!fileItemsUseDirectOperations(items)) {
        if (orig_fileSystemDoEraseSelectedItems)
            ((void(*)(id, SEL, id, id))orig_fileSystemDoEraseSelectedItems)(
                self, _cmd, indexPaths, completion);
        return;
    }

    NSMutableArray *deleted = [NSMutableArray array];
    NSMutableArray<NSError *> *errors = [NSMutableArray array];
    for (id item in items) {
        NSString *path = fileItemPath(item);
        NSError *error = nil;
        if (!pathUsesDirectFileOperations(path)) {
            setPastePOSIXError(&error, EACCES, @"delete", path ?: @"(unknown)");
        } else if ([NSFileManager.defaultManager removeItemAtPath:path error:&error]) {
            [deleted addObject:item];
            NSLog(@"[ContainerDelete] deleted %@", path);
        }
        if (error) {
            [errors addObject:error];
            NSLog(@"[ContainerDelete] failed path=%@ error=%@", path, error);
        }
    }
    if (completion) completion(deleted);
    showDeleteFailure(self, errors);
    NSLog(@"[ContainerDelete] complete deleted=%lu failed=%lu",
          (unsigned long)deleted.count, (unsigned long)errors.count);
}

static dispatch_queue_t pasteCopyQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("local.filzamod.container-copy", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static IMP orig_copyFilesAndDirectoryFromPasteboard = NULL;
static void hook_copyFilesAndDirectoryFromPasteboard(id self, SEL _cmd) {
    MCMFilzaStart();
    NSString *destinationDirectory = ((id(*)(id, SEL))objc_msgSend)(self,
        NSSelectorFromString(@"currentPath"));
    destinationDirectory = localPathFromPasteboardValue(destinationDirectory)
        ?: destinationDirectory;
    if (!MCMFilzaPathHasActiveLease(destinationDirectory)) {
        ((void(*)(id, SEL))orig_copyFilesAndDirectoryFromPasteboard)(self, _cmd);
        return;
    }

    Class pasteboardClass = NSClassFromString(@"TGPasteboard");
    id pasteboard = [pasteboardClass respondsToSelector:@selector(sharedInstance)]
        ? ((id(*)(id, SEL))objc_msgSend)(pasteboardClass, @selector(sharedInstance)) : nil;
    NSArray *objects = [pasteboard respondsToSelector:NSSelectorFromString(@"resolveAndGetObjects")]
        ? ((id(*)(id, SEL))objc_msgSend)(pasteboard,
            NSSelectorFromString(@"resolveAndGetObjects")) : nil;
    if (![objects isKindOfClass:NSArray.class] || objects.count == 0) {
        ((void(*)(id, SEL))orig_copyFilesAndDirectoryFromPasteboard)(self, _cmd);
        return;
    }

    UIViewController *controller = self;
    dispatch_async(pasteCopyQueue(), ^{
        NSMutableArray<NSError *> *errors = [NSMutableArray array];
        NSUInteger copied = 0;
        for (id object in objects) {
            if (![object isKindOfClass:NSDictionary.class]) continue;
            NSString *source = localPathFromPasteboardValue(object[@"path"]);
            NSString *name = [object[@"name"] isKindOfClass:NSString.class]
                ? object[@"name"] : source.lastPathComponent;
            NSString *destination = uniquePasteDestination(destinationDirectory, name);
            NSError *error = nil;
            if (!source || !destination) {
                setPastePOSIXError(&error, EINVAL, @"resolve paste item", name ?: @"(unknown)");
            } else if (pasteDestinationIsInsideSource(source, destinationDirectory)) {
                setPastePOSIXError(&error, EINVAL, @"paste directory into itself", source);
            } else if (directCopyItem(source, destination, &error)) {
                copied++;
                NSLog(@"[ContainerPaste] copied %@ -> %@", source, destination);
            }
            if (error) {
                [errors addObject:error];
                NSLog(@"[ContainerPaste] failed: %@", error.localizedDescription);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
            if ([controller respondsToSelector:loadSelector])
                ((void(*)(id, SEL))objc_msgSend)(controller, loadSelector);
            showPasteFailure(controller, errors);
            NSLog(@"[ContainerPaste] complete copied=%lu failed=%lu destination=%@",
                (unsigned long)copied, (unsigned long)errors.count, destinationDirectory);
        });
    });
}

static NSError *externalDropError(NSString *description, NSError *underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = description.length > 0
        ? description : @"The dropped file could not be loaded.";
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:NSCocoaErrorDomain
        code:NSFileReadUnknownError userInfo:info];
}

static NSArray<NSString *> *externalDropTypeIdentifiers(NSItemProvider *provider) {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (id value in provider.registeredTypeIdentifiers) {
        if (![value isKindOfClass:NSString.class] || [value length] == 0)
            continue;
        NSString *identifier = value;
        // Loading NSURL/public.file-url is the Filza 4.0 path that crashes in
        // iPadOS 27's NSFileCoordinator. Ask for a copied file representation
        // of the payload type instead.
        if ([identifier isEqualToString:@"public.file-url"] ||
            [identifier isEqualToString:@"public.url"])
            continue;
        if (![identifiers containsObject:identifier])
            [identifiers addObject:identifier];
    }
    for (NSString *fallback in @[@"public.data", @"public.folder",
                                  @"public.item"]) {
        if (![identifiers containsObject:fallback] &&
            [provider hasItemConformingToTypeIdentifier:fallback])
            [identifiers addObject:fallback];
    }
    return identifiers.copy;
}

typedef void (^ExternalDropRepresentationCompletion)(NSURL *URL,
                                                       NSError *error);

static void loadExternalDropRepresentation(NSItemProvider *provider,
                                            NSArray<NSString *> *identifiers,
                                            NSUInteger index,
                                            NSError *lastError,
                                            ExternalDropRepresentationCompletion completion) {
    if (index >= identifiers.count) {
        NSString *name = provider.suggestedName ?: @"item";
        completion(nil, externalDropError(
            [NSString stringWithFormat:@"Cannot load dropped file %@.", name],
            lastError));
        return;
    }

    NSString *identifier = identifiers[index];
    [provider loadFileRepresentationForTypeIdentifier:identifier
        completionHandler:^(NSURL *URL, NSError *error) {
            if (URL.isFileURL) {
                completion(URL, nil);
                return;
            }
            loadExternalDropRepresentation(provider, identifiers, index + 1,
                error ?: lastError, completion);
        }];
}

static NSString *externalDropFileName(NSItemProvider *provider, NSURL *URL) {
    NSString *name = provider.suggestedName;
    if (name.length == 0) name = URL.lastPathComponent;
    name = name.lastPathComponent;
    if (name.length == 0 || [name isEqualToString:@"."] ||
        [name isEqualToString:@".."]) return @"Dropped Item";
    return name;
}

static IMP orig_fileSystemPerformDrop = NULL;
static void hook_fileSystemPerformDrop(id self, SEL _cmd,
                                       UIDropInteraction *interaction,
                                       id<UIDropSession> session) {
    SEL currentPathSelector = NSSelectorFromString(@"currentPath");
    NSArray<UIDragItem *> *items = session.items;
    if (session.localDragSession || items.count == 0 ||
        ![self respondsToSelector:currentPathSelector]) {
        if (orig_fileSystemPerformDrop)
            ((void(*)(id, SEL, id, id))orig_fileSystemPerformDrop)(
                self, _cmd, interaction, session);
        return;
    }

    MCMFilzaStart();
    id pathValue = ((id(*)(id, SEL))objc_msgSend)(self, currentPathSelector);
    NSString *destinationDirectory = localPathFromPasteboardValue(pathValue);
    BOOL isDirectory = NO;
    if (destinationDirectory.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:destinationDirectory
            isDirectory:&isDirectory] || !isDirectory) {
        if (orig_fileSystemPerformDrop)
            ((void(*)(id, SEL, id, id))orig_fileSystemPerformDrop)(
                self, _cmd, interaction, session);
        return;
    }

    UIViewController *controller = self;
    NSMutableArray<NSError *> *errors = [NSMutableArray array];
    __block NSUInteger copied = 0;
    __block void (^processItem)(NSUInteger) = nil;
    processItem = ^(NSUInteger index) {
        if (index >= items.count) {
            dispatch_async(dispatch_get_main_queue(), ^{
                reloadFileSystemController(controller);
                showPasteFailure(controller, errors);
                NSLog(@"[ExternalDrop] complete copied=%lu failed=%lu destination=%@",
                    (unsigned long)copied, (unsigned long)errors.count,
                    destinationDirectory);
            });
            processItem = nil;
            return;
        }

        NSItemProvider *provider = items[index].itemProvider;
        NSArray<NSString *> *identifiers =
            externalDropTypeIdentifiers(provider);
        loadExternalDropRepresentation(provider, identifiers, 0, nil,
            ^(NSURL *URL, NSError *loadError) {
                NSError *error = loadError;
                if (URL) {
                    NSString *name = externalDropFileName(provider, URL);
                    NSString *destination = uniquePasteDestination(
                        destinationDirectory, name);
                    BOOL scoped = [URL startAccessingSecurityScopedResource];
                    if (!destination) {
                        setPastePOSIXError(&error, EEXIST,
                            @"choose destination", name);
                    } else if (directCopyItem(URL.path, destination, &error)) {
                        copied++;
                        NSLog(@"[ExternalDrop] copied %@ -> %@", URL.path,
                            destination);
                    }
                    if (scoped) [URL stopAccessingSecurityScopedResource];
                }
                if (error) {
                    [errors addObject:error];
                    NSLog(@"[ExternalDrop] failed: %@",
                        error.localizedDescription);
                }
                processItem(index + 1);
            });
    };
    processItem(0);
}

static void runOptInPasteCopyProbe(void) {
    if (!getenv("FILZA_PASTE_PROBE")) return;
    NSString *source = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @".filza-mod-paste-source-%d", getpid()]];
    NSString *destination = [[MCMFilzaVirtualRoot()
        stringByAppendingPathComponent:@"App Groups/group.com.apple.notes"]
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @".filza-mod-paste-destination-%d", getpid()]];
    NSData *payload = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    BOOL sourceWritten = [payload writeToFile:source atomically:NO];
    NSError *error = nil;
    BOOL copied = sourceWritten && directCopyItem(source, destination, &error);
    NSData *roundTrip = copied ? [NSData dataWithContentsOfFile:destination] : nil;
    BOOL verified = [roundTrip isEqualToData:payload];
    BOOL destinationRemoved = !copied ||
        [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
    BOOL sourceRemoved = !sourceWritten ||
        [NSFileManager.defaultManager removeItemAtPath:source error:nil];
    NSLog(@"[ContainerPasteProbe] copied=%d verified=%d cleanup=%d error=%@",
        copied, verified, destinationRemoved && sourceRemoved, error);
}

#pragma mark - Hook Installation

static void installHooks(void) {
    prepareFilzaDeviceStorageTrash();
    Class preferences = NSClassFromString(@"TGPreferences");
    if (preferences) {
        Method defaultPath = class_getInstanceMethod(preferences, NSSelectorFromString(@"defaultPath"));
        if (defaultPath) method_setImplementation(defaultPath, (IMP)hook_defaultPath);
        Method trashDir = class_getInstanceMethod(preferences,
            NSSelectorFromString(@"trashDir"));
        if (trashDir) method_setImplementation(trashDir, (IMP)hook_trashDir);
        SEL favoritesSelector = NSSelectorFromString(@"favoritedLinks");
        Method favoritedLinks = class_getInstanceMethod(preferences, favoritesSelector);
        if (favoritedLinks) {
            orig_preferencesFavoritedLinks = method_getImplementation(favoritedLinks);
            method_setImplementation(favoritedLinks,
                (IMP)hook_preferencesFavoritedLinks);
        }

        SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
        id sharedPreferences = [preferences respondsToSelector:sharedSelector]
            ? ((id(*)(id, SEL))objc_msgSend)(preferences, sharedSelector) : nil;
        if ([sharedPreferences respondsToSelector:favoritesSelector])
            ((id(*)(id, SEL))objc_msgSend)(sharedPreferences, favoritesSelector);
    }

    Class fileSystemController = NSClassFromString(@"TGFileSystemListViewController");
    if (fileSystemController) {
        Method setCurrentPath = class_getInstanceMethod(
            fileSystemController, NSSelectorFromString(@"setCurrentPath:"));
        if (setCurrentPath) {
            orig_fileSystemSetCurrentPath = method_getImplementation(setCurrentPath);
            method_setImplementation(setCurrentPath, (IMP)hook_fileSystemSetCurrentPath);
        }
        Method viewWillAppear = class_getInstanceMethod(
            fileSystemController, @selector(viewWillAppear:));
        if (viewWillAppear) {
            orig_fileSystemViewWillAppear = method_getImplementation(viewWillAppear);
            method_setImplementation(viewWillAppear, (IMP)hook_fileSystemViewWillAppear);
        }
        SEL editableSelector = NSSelectorFromString(@"updateEditableUI");
        Method updateEditableUI = class_getInstanceMethod(fileSystemController,
            editableSelector);
        if (updateEditableUI) {
            orig_fileSystemUpdateEditableUI = method_getImplementation(updateEditableUI);
            const char *types = method_getTypeEncoding(updateEditableUI);
            // updateEditableUI is inherited from TGPageViewController in this
            // Filza build. Add a subclass override rather than modifying every
            // page controller in the application.
            if (!class_addMethod(fileSystemController, editableSelector,
                    (IMP)hook_fileSystemUpdateEditableUI, types))
                method_setImplementation(updateEditableUI,
                    (IMP)hook_fileSystemUpdateEditableUI);
        }

        SEL performDropSelector =
            NSSelectorFromString(@"dropInteraction:performDrop:");
        Method performDrop = class_getInstanceMethod(fileSystemController,
            performDropSelector);
        if (performDrop && method_getImplementation(performDrop) !=
                (IMP)hook_fileSystemPerformDrop) {
            orig_fileSystemPerformDrop = method_getImplementation(performDrop);
            const char *types = method_getTypeEncoding(performDrop);
            if (!class_addMethod(fileSystemController, performDropSelector,
                    (IMP)hook_fileSystemPerformDrop, types))
                method_setImplementation(performDrop,
                    (IMP)hook_fileSystemPerformDrop);
        }

        SEL pageDeleteSelector = NSSelectorFromString(@"pageDeleteAction");
        Method pageDeleteAction = class_getInstanceMethod(fileSystemController,
            pageDeleteSelector);
        if (pageDeleteAction) {
            orig_fileSystemPageDeleteAction = method_getImplementation(pageDeleteAction);
            const char *types = method_getTypeEncoding(pageDeleteAction);
            if (!class_addMethod(fileSystemController, pageDeleteSelector,
                    (IMP)hook_fileSystemPageDeleteAction, types))
                method_setImplementation(pageDeleteAction,
                    (IMP)hook_fileSystemPageDeleteAction);
        }

        SEL deleteSelectedSelector = NSSelectorFromString(@"deleteSelectedItems");
        Method deleteSelected = class_getInstanceMethod(fileSystemController,
            deleteSelectedSelector);
        if (deleteSelected) {
            orig_fileSystemDeleteSelectedItems = method_getImplementation(deleteSelected);
            method_setImplementation(deleteSelected,
                (IMP)hook_fileSystemDeleteSelectedItems);
        }

        SEL askDeleteSelector = NSSelectorFromString(@"askDeleteItems:");
        Method askDelete = class_getInstanceMethod(fileSystemController,
            askDeleteSelector);
        Method parentAskDelete = class_getInstanceMethod(
            class_getSuperclass(fileSystemController), askDeleteSelector);
        if (askDelete && parentAskDelete) {
            parentFileSystemAskDeleteItems = method_getImplementation(parentAskDelete);
            method_setImplementation(askDelete,
                (IMP)hook_fileSystemAskDeleteItems);
        }

        SEL trashSelector = NSSelectorFromString(
            @"doTrashSelectedIndexPaths:completion:");
        Method trashSelected = class_getInstanceMethod(fileSystemController,
            trashSelector);
        Method parentTrash = class_getInstanceMethod(
            class_getSuperclass(fileSystemController), trashSelector);
        if (trashSelected && parentTrash) {
            orig_fileSystemDoTrashSelectedItems = method_getImplementation(trashSelected);
            parentFileSystemDoTrashSelectedItems = method_getImplementation(parentTrash);
            method_setImplementation(trashSelected,
                (IMP)hook_fileSystemDoTrashSelectedItems);
        }

        SEL eraseSelector = NSSelectorFromString(
            @"doEraseSelectedIndexPaths:completion:");
        Method eraseSelected = class_getInstanceMethod(fileSystemController,
            eraseSelector);
        if (eraseSelected) {
            orig_fileSystemDoEraseSelectedItems = method_getImplementation(eraseSelected);
            method_setImplementation(eraseSelected,
                (IMP)hook_fileSystemDoEraseSelectedItems);
        }
    }

    Class pageController = NSClassFromString(@"TGPageViewController");
    if (pageController) {
        SEL menuItemsSelector = NSSelectorFromString(
            @"menuElementItemsForItem:sourceView:sourceRect:");
        Method menuItems = class_getInstanceMethod(pageController,
            menuItemsSelector);
        if (menuItems && method_getImplementation(menuItems) !=
                (IMP)hook_pageMenuElementItemsForItem) {
            orig_pageMenuElementItemsForItem = method_getImplementation(menuItems);
            method_setImplementation(menuItems,
                (IMP)hook_pageMenuElementItemsForItem);
        }

        Method copyPaste = class_getInstanceMethod(pageController,
            NSSelectorFromString(@"copyFilesAndDirectoryFromPasteboard"));
        if (copyPaste) {
            orig_copyFilesAndDirectoryFromPasteboard = method_getImplementation(copyPaste);
            method_setImplementation(copyPaste,
                (IMP)hook_copyFilesAndDirectoryFromPasteboard);
        }
    }

    Class rfm = NSClassFromString(@"TGRootFileManager");
    if (rfm) {
        Class meta = object_getClass(rfm);
        class_replaceMethod(meta, NSSelectorFromString(@"isRootHelperAvailable"), (IMP)hook_isRootHelperAvailable, "B@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"spawnRootHelper"), (IMP)hook_spawnRootHelper, "i@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"spawnRootHelperIfNeeds"), (IMP)hook_spawnRootHelperIfNeeds, "i@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"respawnRootHelper"), (IMP)hook_respawnRootHelper, "i@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"tryLoadFilzaHelper"), (IMP)hook_tryLoadFilzaHelper, "v@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"createHelperConnectionIfNeeds"), (IMP)hook_createHelperConnectionIfNeeds, "v@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"spawnRoot:args:pid:"), (IMP)hook_spawnRoot_args_pid, "i@:@@^i");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectWithReplySync:"), (IMP)hook_sendObjectWithReplySync, "@@:@");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectWithReplySync:fileDescriptor:"), (IMP)hook_sendObjectWithReplySync_fd, "@@:@^i");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectWithReplySync:fileDescriptor:logintty:"), (IMP)hook_sendObjectWithReplySync_fd_logintty, "@@:@^iB");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectNoReply:"), (IMP)hook_sendObjectNoReply, "v@:@");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectWithReplyAsync:queue:completion:"), (IMP)hook_sendObjectWithReplyAsync, "v@:@@?");

    }
    Class zipper = NSClassFromString(@"Zipper");
    if (zipper) {
        Method m;
        m = class_getInstanceMethod(zipper, NSSelectorFromString(@"ZipFiles:toFilePath:currentDirectory:"));
        if (m && method_getImplementation(m) != (IMP)hook_ZipFiles) {
            orig_ZipFiles = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_ZipFiles);
        }
        m = class_getInstanceMethod(zipper, NSSelectorFromString(@"unZipFile:toPath:currentDirectory:outMessage:"));
        if (m && method_getImplementation(m) != (IMP)hook_unZipFile) {
            orig_unZipFile = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_unZipFile);
        }
        m = class_getInstanceMethod(zipper, NSSelectorFromString(@"unZipFile:toPath:currentDirectory:withPassword:outMessage:"));
        if (m && method_getImplementation(m) != (IMP)hook_unZipFilePassword) {
            orig_unZipFilePassword = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_unZipFilePassword);
        }
        m = class_getInstanceMethod(zipper,
            NSSelectorFromString(@"dataInZipFilePath:withName:"));
        if (m && method_getImplementation(m) != (IMP)hook_dataInZipFilePath) {
            orig_dataInZipFilePath = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_dataInZipFilePath);
        }
        m = class_getInstanceMethod(zipper,
            NSSelectorFromString(@"dataInZipFile:withName:"));
        if (m && method_getImplementation(m) != (IMP)hook_dataInZipFile) {
            orig_dataInZipFile = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_dataInZipFile);
        }
    }

    // License/integrity bypass
    Class alertCtrl = NSClassFromString(@"TGAlertController");
    if (alertCtrl) {
        Class alertMeta = object_getClass(alertCtrl);
        Method m = class_getClassMethod(alertCtrl, NSSelectorFromString(@"showAlertWithTitle:text:cancelButton:otherButtons:completion:"));
        if (m) {
            orig_showAlert = method_getImplementation(m);
            class_replaceMethod(alertMeta, NSSelectorFromString(@"showAlertWithTitle:text:cancelButton:otherButtons:completion:"),
                (IMP)hook_showAlertWithTitle, "@@:@@@@@");
        }
    }
    Method pushController = class_getInstanceMethod(UINavigationController.class,
        @selector(pushViewController:animated:));
    if (pushController) {
        orig_pushViewController = method_getImplementation(pushController);
        method_setImplementation(pushController, (IMP)hook_pushViewController);
    }
    Method presentController = class_getInstanceMethod(UIViewController.class,
        @selector(presentViewController:animated:completion:));
    if (presentController) {
        orig_presentViewController = method_getImplementation(presentController);
        method_setImplementation(presentController, (IMP)hook_presentViewController);
    }
    Class activationVC = NSClassFromString(@"NewActivationViewController");
    if (activationVC) {
        Method m = class_getInstanceMethod(activationVC, @selector(viewDidLoad));
        if (m) {
            orig_activationViewDidLoad = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_activationViewDidLoad);
        }
    }

    // Filza classes can be registered after this dylib constructor. This
    // idempotent installer runs again from allApplications before item creation.
    installAppManagerHooks();
    NSLog(@"[Tweak] All hooks installed");
}

#pragma mark - MCM container activation

static void runWriteProbeAtDirectory(NSString *label, NSString *directory) {
    NSString *name = [NSString stringWithFormat:@".filza-mod-write-probe-%d", getpid()];
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSData *payload = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    int descriptor = open(path.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    int createError = descriptor < 0 ? errno : 0;
    ssize_t written = -1;
    if (descriptor >= 0) {
        written = write(descriptor, payload.bytes, payload.length);
        fsync(descriptor);
        close(descriptor);
    }

    NSData *roundTrip = descriptor >= 0 ? [NSData dataWithContentsOfFile:path] : nil;
    BOOL verified = written == (ssize_t)payload.length && [roundTrip isEqualToData:payload];
    int cleanupResult = descriptor >= 0 ? unlink(path.fileSystemRepresentation) : -1;
    struct stat status = {0};
    BOOL removed = descriptor >= 0 && cleanupResult == 0 &&
        lstat(path.fileSystemRepresentation, &status) != 0 && errno == ENOENT;
    NSLog(@"[WriteProbe] target=%@ create=%d errno=%d bytes=%zd readback=%d cleanup=%d path=%@",
        label, descriptor >= 0, createError, written, verified, removed, path);
}

static void runWritableOpenProbe(NSString *label, NSString *path) {
    int descriptor = open(path.fileSystemRepresentation,
        O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    int openError = descriptor < 0 ? errno : 0;
    struct stat status = {0};
    BOOL regularFile = descriptor >= 0 && fstat(descriptor, &status) == 0 &&
        S_ISREG(status.st_mode);
    if (descriptor >= 0) close(descriptor);
    NSLog(@"[WriteProbe] target=%@ open_rdwr=%d errno=%d regular=%d size=%lld path=%@",
        label, descriptor >= 0, openError, regularFile,
        regularFile ? (long long)status.st_size : -1LL, path);
}

static void runOptInWriteProbe(void) {
    if (!getenv("FILZA_WRITE_PROBE")) return;
    NSString *root = MCMFilzaVirtualRoot();
    NSString *canary = [root stringByAppendingPathComponent:
        @"App Data/local.research.SandboxCanaryVictim"];
    runWriteProbeAtDirectory(@"Canary app data", canary);
    runWriteProbeAtDirectory(@"Canary app data tmp",
        [canary stringByAppendingPathComponent:@"tmp"]);
    runWriteProbeAtDirectory(@"Notes app data",
        [root stringByAppendingPathComponent:@"App Data/com.apple.mobilenotes"]);
    runWriteProbeAtDirectory(@"Notes app data tmp",
        [root stringByAppendingPathComponent:@"App Data/com.apple.mobilenotes/tmp"]);
    runWriteProbeAtDirectory(@"Notes app group",
        [root stringByAppendingPathComponent:@"App Groups/group.com.apple.notes"]);
    runWritableOpenProbe(@"Notes database",
        [root stringByAppendingPathComponent:
            @"App Groups/group.com.apple.notes/NoteStore.sqlite"]);
}

static UIViewController *activeBrowserController(void) {
    UIWindow *window = nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) { window = candidate; break; }
        if (!window && !candidate.hidden) window = candidate;
    }
    UIViewController *controller = window.rootViewController;
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)controller).selectedViewController;
        if (!next && [controller isKindOfClass:UISplitViewController.class])
            next = ((UISplitViewController *)controller).viewControllers.lastObject;
        if (!next && [controller respondsToSelector:
                NSSelectorFromString(@"visibleViewControllers")]) {
            id visible = ((id(*)(id, SEL))objc_msgSend)(controller,
                NSSelectorFromString(@"visibleViewControllers"));
            if ([visible isKindOfClass:NSArray.class] && [visible count] > 0)
                next = [visible lastObject];
        }
        if (!next && controller.childViewControllers.count == 1)
            next = controller.childViewControllers.firstObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static BOOL repairActiveBrowserPath(void) {
    UIViewController *controller = activeBrowserController();
    SEL currentPathSelector = NSSelectorFromString(@"currentPath");
    SEL setCurrentPathSelector = NSSelectorFromString(@"setCurrentPath:");
    if (![controller respondsToSelector:currentPathSelector] ||
        ![controller respondsToSelector:setCurrentPathSelector]) {
        NSLog(@"[DeviceStorage] waiting for browser controller; active=%@",
            NSStringFromClass(controller.class));
        return NO;
    }
    NSString *currentPath = ((id(*)(id, SEL))objc_msgSend)(controller,
        currentPathSelector);
    NSString *root = MCMFilzaVirtualRoot();
    BOOL insideRoot = [currentPath isEqualToString:root] ||
        [currentPath hasPrefix:[root stringByAppendingString:@"/"]];
    if (!insideRoot) {
        ((void(*)(id, SEL, id))objc_msgSend)(controller,
            setCurrentPathSelector, root);
        controller.navigationItem.title = @"Device Storage";
        NSLog(@"[DeviceStorage] repaired active browser path from %@ to %@ class=%@",
            currentPath, root, NSStringFromClass(controller.class));
    }
    SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
    if ([controller respondsToSelector:loadSelector]) {
        ((void(*)(id, SEL))objc_msgSend)(controller, loadSelector);
        NSLog(@"[DeviceStorage] reloaded active browser path %@ class=%@",
              root, NSStringFromClass(controller.class));
    }
    return YES;
}

static void scheduleInitialBrowserRepair(NSUInteger attemptsRemaining) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            if (!repairActiveBrowserPath() && attemptsRemaining > 1)
                scheduleInitialBrowserRepair(attemptsRemaining - 1);
        });
}

static void runMCMPath(void) {
    MCMFilzaStart();
    if (MCMFilzaIsRunningInLiveContainer()) return;
    PBWallpaperFeatureStart();
    runOptInWriteProbe();
    runOptInPasteCopyProbe();
}

static NSTimer *gAppManagerCatalogueTimer = nil;
static void startAppManagerCatalogueTimer(void) {
    if (gAppManagerCatalogueTimer) return;
    gAppManagerCatalogueTimer = [NSTimer scheduledTimerWithTimeInterval:300.0
        repeats:YES block:^(__unused NSTimer *timer) {
            if (UIApplication.sharedApplication.applicationState ==
                    UIApplicationStateActive) {
                MHADeviceCatalogScheduleRefresh();
                scheduleCatalogC2Sync();
            }
        }];
}

#pragma mark - Entry Point

__attribute__((constructor)) void TweakInit(void) {
    installHooks();
    [[NSNotificationCenter defaultCenter]
        addObserverForName:MHADeviceCatalogDidRefreshNotification
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(__unused NSNotification *note) {
            scheduleVisibleAppManagerReload();
        }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:MHADeviceCatalogDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(__unused NSNotification *note) {
            scheduleCatalogC2Sync();
            scheduleVisibleAppManagerCatalogueReload();
        }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(__unused NSNotification *note) {
            installAppManagerHooks();
            MHADeviceCatalogLoadCache();
            scheduleCatalogC2Sync();
            MHADeviceCatalogScheduleRefresh();
            startAppManagerCatalogueTimer();
        }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(__unused NSNotification *note) {
            MHADeviceCatalogScheduleRefresh();
            scheduleCatalogC2Sync();
        }];
    // Populate the MCM root before Filza restores its initial browser path.
    runMCMPath();
    scheduleInitialBrowserRepair(8);
}
