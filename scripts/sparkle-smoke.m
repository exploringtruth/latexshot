#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>
#include <fcntl.h>
#include <unistd.h>

static NSString *smokeRoot(void) {
    return NSBundle.mainBundle.infoDictionary[@"SmokeRoot"];
}

static void recordEvent(NSString *name, NSDictionary *details) {
    NSMutableDictionary *entry = [@{
        @"event": name,
        @"version": NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown",
        @"pid": @(getpid())
    } mutableCopy];
    if (details) {
        [entry addEntriesFromDictionary:details];
    }
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL] mutableCopy];
    [data appendBytes:"\n" length:1];
    NSString *eventsPath = [smokeRoot() stringByAppendingPathComponent:@"events.jsonl"];
    int file = open([eventsPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (file >= 0) {
        write(file, data.bytes, data.length);
        close(file);
    }
}

static NSDictionary *errorDetails(NSError *error) {
    if (!error) return @{};
    return @{
        @"domain": error.domain ?: @"",
        @"code": @(error.code),
        @"description": error.description ?: @""
    };
}

@interface SmokeDriver : NSObject <SPUUserDriver>
@end

@implementation SmokeDriver

- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    recordEvent(@"unexpectedPermissionRequest", nil);
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
    [NSApp terminate:nil];
}

- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {
    recordEvent(@"manualCheck", nil);
}

- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    recordEvent(@"updateFound", @{
        @"updateVersion": item.versionString ?: @"",
        @"userInitiated": @(state.userInitiated)
    });
    if (![item.fileURL.host isEqual:@"127.0.0.1"] || ![item.versionString isEqual:@"2.0"]) {
        reply(SPUUserUpdateChoiceSkip);
        [NSApp terminate:nil];
        return;
    }
    reply(SPUUserUpdateChoiceInstall);
}

- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {
    recordEvent(@"releaseNotes", nil);
}

- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {
    recordEvent(@"releaseNotesError", errorDetails(error));
}

- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack {
    recordEvent(@"noUpdate", errorDetails(error));
    ack();
    [NSApp terminate:nil];
}

- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack {
    recordEvent(@"updaterError", errorDetails(error));
    ack();
    [NSApp terminate:nil];
}

- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    recordEvent(@"downloadStarted", nil);
}

- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {
    recordEvent(@"downloadLength", @{@"bytes": @(length)});
}

- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {
}

- (void)showDownloadDidStartExtractingUpdate {
    recordEvent(@"extracting", nil);
}

- (void)showExtractionReceivedProgress:(double)progress {
}

- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    recordEvent(@"readyToInstall", nil);
    reply(SPUUserUpdateChoiceInstall);
}

- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    recordEvent(@"installing", @{@"hostTerminated": @(terminated)});
}

- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack {
    recordEvent(@"installed", @{@"relaunched": @(relaunched)});
    ack();
}

- (void)dismissUpdateInstallation {
    recordEvent(@"dismissed", nil);
}

- (void)showUpdateInFocus {
}

@end

@interface SmokeApp : NSObject <NSApplicationDelegate, SPUUpdaterDelegate>
@property(strong) SmokeDriver *driver;
@property(strong) SPUUpdater *updater;
@end

@implementation SmokeApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *expected = [smokeRoot() stringByAppendingPathComponent:@"installed/UpdaterSmoke.app"];
    if (![NSBundle.mainBundle.bundlePath isEqual:expected] ||
        ![NSBundle.mainBundle.bundleIdentifier containsString:@".DisposableUpdaterTest."]) {
        exit(80);
    }

    recordEvent(@"launched", @{@"bundlePath": NSBundle.mainBundle.bundlePath});

    if ([NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] isEqual:@"2.0"]) {
        [@"relaunched" writeToFile:[smokeRoot() stringByAppendingPathComponent:@"relaunched.txt"]
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:NULL];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
        return;
    }

    self.driver = [SmokeDriver new];
    self.updater = [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle
                                        applicationBundle:NSBundle.mainBundle
                                               userDriver:self.driver
                                                 delegate:self];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) {
        recordEvent(@"startError", errorDetails(error));
        [NSApp terminate:nil];
        return;
    }

    recordEvent(@"updaterConfigured", @{
        @"automaticallyChecks": @(self.updater.automaticallyChecksForUpdates),
        @"updateInterval": @(self.updater.updateCheckInterval)
    });

    [self.updater checkForUpdates];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        recordEvent(@"timeout", nil);
        [NSApp terminate:nil];
    });
}

- (void)updater:(SPUUpdater *)updater willInstallUpdate:(SUAppcastItem *)item {
    recordEvent(@"willInstall", nil);
}

- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error {
    recordEvent(@"aborted", errorDetails(error));
}

- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    recordEvent(@"cycleFinished", error ? errorDetails(error) : @{});
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        SmokeApp *delegate = [SmokeApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
