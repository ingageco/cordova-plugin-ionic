#import "IonicCordovaCommon.h"
#import <Cordova/CDVPluginResult.h>
#import <objc/message.h>


@interface IonicCordovaCommon()

@property Boolean revertToBase;
@property NSString *baseIndexPath;

@end

@implementation IonicCordovaCommon

// Runs at process start, before Capacitor's CAPBridgeViewController reads the
// persisted serverBasePath in loadView(). If that path points at a snapshot that
// no longer exists on disk (device migration, iCloud restore, failed download),
// Capacitor calls exit(1) before the web view - and any JS recovery code - can
// run, leaving the app in a crash loop until it is reinstalled. Clearing the
// stale pointer here makes Capacitor fall back to the bundled web assets.
+ (void) load {
    [self repairStaleDeployState];
}

+ (NSString*) snapshotsDirectory {
    NSString *libPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    return [[libPath stringByAppendingPathComponent:@"NoCloud"] stringByAppendingPathComponent:@"ionic_built_snapshots"];
}

// A snapshot is only servable if the file Capacitor's startup guard checks for
// (index.html) is present; a bare directory is not enough.
+ (BOOL) isSnapshotServable:(NSString*)versionId {
    if (versionId == nil || versionId.length == 0) {
        return NO;
    }
    NSString *indexPath = [[[self snapshotsDirectory] stringByAppendingPathComponent:versionId] stringByAppendingPathComponent:@"index.html"];
    return [[NSFileManager defaultManager] fileExistsAtPath:indexPath];
}

+ (void) repairStaleDeployState {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *libPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];

    // Capacitor >= 6 persists the base path as a JSON string in Library/kvstore/standard/serverBasePath
    NSString *kvStoreFile = [libPath stringByAppendingPathComponent:@"kvstore/standard/serverBasePath"];
    if ([fm fileExistsAtPath:kvStoreFile]) {
        NSString *persistedPath = nil;
        NSData *data = [NSData dataWithContentsOfFile:kvStoreFile];
        if (data != nil) {
            id decoded = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
            if ([decoded isKindOfClass:[NSString class]]) {
                persistedPath = decoded;
            }
        }
        if (![self isSnapshotServable:[persistedPath lastPathComponent]]) {
            NSLog(@"IonicCordovaCommon: persisted serverBasePath (%@) has no servable snapshot on disk, clearing it to prevent a startup crash", persistedPath);
            [fm removeItemAtPath:kvStoreFile error:nil];
        }
    }

    // Capacitor <= 5 persisted the base path in NSUserDefaults
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSString *legacyPath = [prefs stringForKey:@"serverBasePath"];
    if (legacyPath != nil && legacyPath.length > 0 && ![self isSnapshotServable:[legacyPath lastPathComponent]]) {
        NSLog(@"IonicCordovaCommon: legacy serverBasePath (%@) has no servable snapshot on disk, clearing it to prevent a startup crash", legacyPath);
        [prefs removeObjectForKey:@"serverBasePath"];
        [prefs synchronize];
    }
}

- (void) pluginInitialize {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    self.revertToBase = true;
    self.baseIndexPath = [[NSBundle mainBundle] pathForResource:@"www" ofType: nil];

    if ([prefs stringForKey:@"uuid"] == nil) {
        [prefs setObject:[[NSUUID UUID] UUIDString] forKey:@"uuid"];
    }
    [prefs synchronize];
}

- (void) remove:(CDVInvokedUrlCommand*)command {
    NSDictionary *options = command.arguments[0];
    NSString *path = options[@"target"];
    NSLog(@"Got remove path: %@", path);
    NSError *removeError = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:path error:&removeError]) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: [removeError localizedDescription]]  callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void) copyTo:(CDVInvokedUrlCommand*)command {
    NSDictionary *options = command.arguments[0];
    NSLog(@"Got copyTo: %@", options);
    NSString *srcDir = options[@"source"][@"directory"];
    NSString *srcPath = options[@"source"][@"path"];
    NSString *dest = options[@"target"];
    
    if (![srcDir isEqualToString:@"APPLICATION"]) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"Only Application directory is supported"]  callbackId:command.callbackId];
        return;
    }
    NSMutableString *source = [NSMutableString stringWithString:[[NSBundle mainBundle] resourcePath]];
    [source appendString:@"/"];
    [source appendString:srcPath];
    NSError *createDirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&createDirError]) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: [createDirError localizedDescription]]  callbackId:command.callbackId];
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:source toPath:dest error:&copyError]) {
        NSLog(@"Error copying files: %@", [copyError localizedDescription]);
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: [copyError localizedDescription]]  callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void) downloadFile:(CDVInvokedUrlCommand*)command {
    NSDictionary *options = command.arguments[0];
    NSString *target = options[@"target"];
    NSString *urlStr = options[@"url"];
    NSLog(@"Got downloadFile: %@", options);
    
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"Download Error:%@",error.description);
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: [error localizedDescription]]  callbackId:command.callbackId];
            return;
        }
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
        if (httpResponse.statusCode != 200) {
            NSString *errorMsg = [NSString stringWithFormat:@"HTTP response status code: %ld", (long)httpResponse.statusCode];
            NSLog(@"Download Error: %@", errorMsg);
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: errorMsg]  callbackId:command.callbackId];
            return;
        }
        if (data == nil) {
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"Download returned no data"]  callbackId:command.callbackId];
            return;
        }
        NSError *createDirError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:[target stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&createDirError]) {
            NSLog(@"Error creating download directory: %@", [createDirError localizedDescription]);
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: [createDirError localizedDescription]]  callbackId:command.callbackId];
            return;
        }
        NSError *writeError = nil;
        if (![data writeToFile:target options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"Error writing downloaded file (disk full?): %@", [writeError localizedDescription]);
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: [writeError localizedDescription]]  callbackId:command.callbackId];
            return;
        }
        NSLog(@"File is saved to %@", target);
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    }] resume];
}

- (void) getAppInfo:(CDVInvokedUrlCommand*)command {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *json = [[NSMutableDictionary alloc] init];
    NSString* platformVersion = [[UIDevice currentDevice] systemVersion];
    NSString* versionCode = [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"];
    NSString* bundleName = [[NSBundle mainBundle] infoDictionary][@"CFBundleIdentifier"];
    NSString* versionName = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    NSString* uuid = [prefs stringForKey:@"uuid"];
    NSString *libPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString * cordovaDataDirectory = [libPath stringByAppendingPathComponent:@"NoCloud"];

    NSString* frameworkVersion = [[NSBundle mainBundle] infoDictionary][@"ClFrameworkVersion"];


    if (versionName == nil) {
      versionName = [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"];
      if (versionName == nil) {
        versionName = @"";
      }
    }

    json[@"platform"] = @"ios";
    json[@"platformVersion"] = platformVersion;
    json[@"version"] = versionCode;
    json[@"binaryVersionCode"] = versionCode;
    json[@"bundleName"] = bundleName;
    json[@"bundleVersion"] = versionName;
    json[@"binaryVersionName"] = versionName;
    json[@"clFrameworkVersion"] = frameworkVersion;
    json[@"device"] = uuid;
    json[@"dataDirectory"] = [[NSURL fileURLWithPath:cordovaDataDirectory] absoluteString];
    NSLog(@"Got app info: %@", json);

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:json] callbackId:command.callbackId];

}

- (void) getPreferences:(CDVInvokedUrlCommand*)command {
    // Get updated preferences if available
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSDictionary *immutableStoredPrefs = [prefs objectForKey:@"ionicDeploySavedPreferences"];
    NSMutableDictionary *savedPrefs = [immutableStoredPrefs mutableCopy];
    NSMutableDictionary *nativeConfig = [self getNativeConfig];
    NSMutableDictionary *customConfig = [self getCustomConfig];

    if (savedPrefs!= nil) {

        NSLog(@"found some saved prefs doing precedence ops: %@", savedPrefs);
        // Drop any recorded updates whose snapshot files are gone from disk so
        // the JS layer never redirects the webview into a missing snapshot
        savedPrefs = [self sanitizeSavedPreferences:savedPrefs];

        // Merge with most up to date Native Settings
        [savedPrefs addEntriesFromDictionary:nativeConfig];

        // Merge with any custom settings
        [savedPrefs addEntriesFromDictionary:customConfig];

        NSLog(@"Returning saved prefs: %@", savedPrefs);
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary: savedPrefs] callbackId:command.callbackId];
        return;
    }

    // No saved prefs found get them all from config
    // Make sure to initialize empty updates object
    NSLog(@"initing updates key");
    nativeConfig[@"updates"] = [[NSDictionary alloc] init];
    NSLog(@"Initialized App Prefs: %@", nativeConfig);

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:nativeConfig] callbackId:command.callbackId];
}

- (NSMutableDictionary*) sanitizeSavedPreferences:(NSMutableDictionary*)savedPrefs {
    BOOL changed = NO;

    NSDictionary *updates = savedPrefs[@"updates"];
    if ([updates isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *validUpdates = [updates mutableCopy];
        for (NSString *versionId in updates) {
            if (![IonicCordovaCommon isSnapshotServable:versionId]) {
                NSLog(@"IonicCordovaCommon: dropping update %@ because its snapshot files are missing from disk", versionId);
                [validUpdates removeObjectForKey:versionId];
                changed = YES;
            }
        }
        if (changed) {
            savedPrefs[@"updates"] = validUpdates;
        }
    }

    NSString *currentVersionId = savedPrefs[@"currentVersionId"];
    if ([currentVersionId isKindOfClass:[NSString class]] && ![IonicCordovaCommon isSnapshotServable:currentVersionId]) {
        NSLog(@"IonicCordovaCommon: current version %@ has no snapshot on disk, reverting to bundled version", currentVersionId);
        [savedPrefs removeObjectForKey:@"currentVersionId"];
        [savedPrefs removeObjectForKey:@"currentBuildId"];
        changed = YES;
    }

    // Pending/ready updates have already been written to disk; if the files are
    // gone the update can never be applied, so make the JS re-download it
    NSDictionary *availableUpdate = savedPrefs[@"availableUpdate"];
    if ([availableUpdate isKindOfClass:[NSDictionary class]]) {
        NSString *state = availableUpdate[@"state"];
        NSString *versionId = availableUpdate[@"versionId"];
        BOOL onDisk = [state isEqualToString:@"pending"] || [state isEqualToString:@"ready"];
        if (onDisk && ![IonicCordovaCommon isSnapshotServable:versionId]) {
            NSLog(@"IonicCordovaCommon: available update %@ has no snapshot on disk, discarding it", versionId);
            [savedPrefs removeObjectForKey:@"availableUpdate"];
            changed = YES;
        }
    }

    if (changed) {
        [[NSUserDefaults standardUserDefaults] setObject:savedPrefs forKey:@"ionicDeploySavedPreferences"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    return savedPrefs;
}

- (void) setPreferences:(CDVInvokedUrlCommand*)command {
    NSDictionary *json = command.arguments[0];
    NSLog(@"Got prefs to save: %@", json);
    [[NSUserDefaults standardUserDefaults] setObject:json forKey:@"ionicDeploySavedPreferences"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self getPreferences:command];
}

- (NSMutableDictionary*) getNativeConfig {
    // Get preferences from cordova
    NSString *appId = [NSString stringWithFormat:@"%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IonAppId"]];
    NSNumber * disabled = [NSNumber numberWithBool:[[self.commandDelegate.settings objectForKey:[@"DisableDeploy" lowercaseString]] boolValue]];
    NSString *host = [NSString stringWithFormat:@"%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IonApi"]];
    NSString *updateMethod = [NSString stringWithFormat:@"%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IonUpdateMethod"]];
    NSString *channel = [NSString stringWithFormat:@"%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IonChannelName"]];
    NSNumber *maxV = [NSNumber numberWithInt:[[[NSBundle mainBundle] objectForInfoDictionaryKey:@"IonMaxVersions"] intValue]];
    NSNumber *minBackgroundDuration = [NSNumber numberWithInt:[[[NSBundle mainBundle] objectForInfoDictionaryKey:@"IonMinBackgroundDuration"] intValue]];
    NSString* versionCode = [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"];
    NSString* versionName = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];

    NSString *frameworkVersion = [NSString stringWithFormat:@"%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CLFrameworkVersion"]];

    // Build the preferences json object
    NSMutableDictionary *json = [[NSMutableDictionary alloc] init];
    json[@"appId"] = appId;
    json[@"disabled"] = disabled;
    json[@"channel"] = channel;
    json[@"host"] = host;
    json[@"updateMethod"] = updateMethod;
    json[@"maxVersions"] = maxV;
    json[@"minBackgroundDuration"] = minBackgroundDuration;
    json[@"binaryVersionCode"] = versionCode;
    json[@"binaryVersion"] = versionName;
    json[@"binaryVersionName"] = versionName;
    json[@"clFrameworkVersion"] = frameworkVersion;

    NSLog(@"Got Native app preferences: %@", json);
    return json;
}

- (NSMutableDictionary*) getCustomConfig {
    // Get custom preferences if available
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSDictionary *immutableConfig = [prefs objectForKey:@"ionicDeployCustomPreferences"];
    NSMutableDictionary *customConfig = [immutableConfig mutableCopy];
    if (customConfig!= nil) {
        NSLog(@"Found custom config: %@", customConfig);
        return customConfig;
    }
    NSLog(@"No custom config found");
    NSMutableDictionary *json = [[NSMutableDictionary alloc] init];
    return json;
}

- (void) configure:(CDVInvokedUrlCommand *)command {
    NSDictionary *newConfig = command.arguments[0];
    NSLog(@"Got new config to save: %@", newConfig);
    NSMutableDictionary *storedConfig = [self getCustomConfig];
    [storedConfig addEntriesFromDictionary:newConfig];
    [[NSUserDefaults standardUserDefaults] setObject:storedConfig forKey:@"ionicDeployCustomPreferences"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:newConfig] callbackId:command.callbackId];
}

@end
