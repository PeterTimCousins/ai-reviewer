#import <Foundation/Foundation.h>
#import <unistd.h>

static NSString *ExpandPath(NSString *path) {
    return [path stringByExpandingTildeInPath];
}

static NSString *ConfigString(NSDictionary *config, NSString *key, NSError **error) {
    id value = config[key];
    if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIReviewer"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"Invalid config: %@ must be a non-empty string", key]}];
        }
        return nil;
    }
    return (NSString *)value;
}

static NSNumber *ConfigNumber(NSDictionary *config, NSString *key, NSError **error) {
    id value = config[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIReviewer"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"Invalid config: %@ must be a number", key]}];
        }
        return nil;
    }
    return (NSNumber *)value;
}

static NSDictionary *LoadConfig(NSString *path, NSError **error) {
    NSString *expanded = ExpandPath(path);
    NSData *data = [NSData dataWithContentsOfFile:expanded options:0 error:error];
    if (!data) {
        return nil;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIReviewer"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid config: root must be an object"}];
        }
        return nil;
    }

    return (NSDictionary *)json;
}

static NSString *RunGit(NSString *repoPath, NSArray<NSString *> *arguments, NSError **error) {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/git";

    NSMutableArray<NSString *> *taskArguments = [NSMutableArray arrayWithObjects:@"-C", repoPath, nil];
    [taskArguments addObjectsFromArray:arguments];
    task.arguments = taskArguments;

    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;

    @try {
        [task launch];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIReviewer"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Unable to launch git"}];
        }
        return nil;
    }

    [task waitUntilExit];

    NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";

    if (task.terminationStatus != 0) {
        NSString *message = [errorOutput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (message.length == 0) {
            message = [NSString stringWithFormat:@"git exited with status %d", task.terminationStatus];
        }
        if (error) {
            *error = [NSError errorWithDomain:@"AIReviewer"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return nil;
    }

    return [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL PathExists(NSString *path, NSError **error) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return YES;
    }

    if (error) {
        *error = [NSError errorWithDomain:@"AIReviewer"
                                     code:6
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"Missing path: %@", path]}];
    }
    return NO;
}

static BOOL ValidateAndPrint(NSDictionary *config, NSError **error) {
    NSString *repoPath = ExpandPath(ConfigString(config, @"repoPath", error));
    if (!repoPath) return NO;

    NSString *reportsPathSetting = ConfigString(config, @"reportsPath", error);
    if (!reportsPathSetting) return NO;

    NSNumber *maxParallelReviews = ConfigNumber(config, @"maxParallelReviews", error);
    if (!maxParallelReviews) return NO;

    NSNumber *pollIntervalSeconds = ConfigNumber(config, @"pollIntervalSeconds", error);
    if (!pollIntervalSeconds) return NO;

    NSString *codexHome = ExpandPath(ConfigString(config, @"codexHome", error));
    if (!codexHome) return NO;

    NSString *reviewCachePath = ExpandPath(ConfigString(config, @"reviewCachePath", error));
    if (!reviewCachePath) return NO;

    NSString *reportsPath = [repoPath stringByAppendingPathComponent:reportsPathSetting];
    NSString *headLogPath = [repoPath stringByAppendingPathComponent:@".git/logs/HEAD"];

    if (!PathExists(repoPath, error)) return NO;
    if (!PathExists(reportsPath, error)) return NO;
    if (!PathExists(headLogPath, error)) return NO;

    NSString *head = RunGit(repoPath, @[@"rev-parse", @"--short", @"HEAD"], error);
    if (!head) return NO;

    NSString *branch = RunGit(repoPath, @[@"branch", @"--show-current"], error);
    if (!branch) return NO;
    if (branch.length == 0) {
        branch = @"(detached)";
    }

    printf("AI Reviewer\n");
    printf("repo: %s\n", [repoPath UTF8String]);
    printf("reports: %s\n", [reportsPath UTF8String]);
    printf("head: %s\n", [head UTF8String]);
    printf("branch: %s\n", [branch UTF8String]);
    printf("codexHome: %s\n", [codexHome UTF8String]);
    printf("reviewCachePath: %s\n", [reviewCachePath UTF8String]);
    printf("maxParallelReviews: %d\n", [maxParallelReviews intValue]);
    printf("pollIntervalSeconds: %d\n", [pollIntervalSeconds intValue]);

    return YES;
}

static BOOL Watch(NSDictionary *config, NSError **error) {
    NSString *repoPath = ExpandPath(ConfigString(config, @"repoPath", error));
    if (!repoPath) return NO;

    NSNumber *pollIntervalSeconds = ConfigNumber(config, @"pollIntervalSeconds", error);
    if (!pollIntervalSeconds) return NO;

    int interval = MAX(1, [pollIntervalSeconds intValue]);
    NSString *lastHead = RunGit(repoPath, @[@"rev-parse", @"HEAD"], error);
    if (!lastHead) return NO;

    printf("watching: %s\n", [repoPath UTF8String]);
    printf("initialHead: %s\n", [lastHead UTF8String]);
    fflush(stdout);

    while (true) {
        sleep((unsigned int)interval);

        NSError *headError = nil;
        NSString *head = RunGit(repoPath, @[@"rev-parse", @"HEAD"], &headError);
        if (!head) {
            fprintf(stderr, "watch warning: %s\n", [[headError localizedDescription] UTF8String]);
            fflush(stderr);
            continue;
        }

        if (![head isEqualToString:lastHead]) {
            printf("headChanged: %s -> %s\n", [lastHead UTF8String], [head UTF8String]);
            fflush(stdout);
            lastHead = head;
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if ((argc != 3 && argc != 4) || strcmp(argv[1], "--config") != 0) {
            fprintf(stderr, "Usage: ai-reviewer-watcher --config <path> [--once|--watch]\n");
            return 1;
        }

        BOOL watchMode = NO;
        if (argc == 4) {
            if (strcmp(argv[3], "--watch") == 0) {
                watchMode = YES;
            } else if (strcmp(argv[3], "--once") != 0) {
                fprintf(stderr, "Usage: ai-reviewer-watcher --config <path> [--once|--watch]\n");
                return 1;
            }
        }

        NSError *error = nil;
        NSString *configPath = [NSString stringWithUTF8String:argv[2]];
        NSDictionary *config = LoadConfig(configPath, &error);
        if (!config || !ValidateAndPrint(config, &error)) {
            fprintf(stderr, "%s\n", [[error localizedDescription] UTF8String]);
            return 1;
        }

        if (watchMode && !Watch(config, &error)) {
            fprintf(stderr, "%s\n", [[error localizedDescription] UTF8String]);
            return 1;
        }
    }

    return 0;
}
