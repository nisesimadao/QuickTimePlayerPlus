#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <unistd.h>

static NSString *QTPExecutableDirectory(void)
{
    char buffer[PATH_MAX];
    uint32_t size = sizeof(buffer);
    if (_NSGetExecutablePath(buffer, &size) != 0) {
        return nil;
    }

    NSString *executablePath = [[NSFileManager.defaultManager stringWithFileSystemRepresentation:buffer length:strlen(buffer)] stringByResolvingSymlinksInPath];
    return executablePath.stringByDeletingLastPathComponent;
}

static NSString *QTPNormalizeArgument(NSString *argument)
{
    if ([argument isEqualToString:@"~"]) {
        argument = NSHomeDirectory();
    } else if ([argument hasPrefix:@"~/"]) {
        argument = [NSHomeDirectory() stringByAppendingPathComponent:[argument substringFromIndex:2]];
    }

    if ([NSFileManager.defaultManager fileExistsAtPath:argument]) {
        NSString *directory = argument.stringByDeletingLastPathComponent.stringByStandardizingPath;
        return [directory stringByAppendingPathComponent:argument.lastPathComponent];
    }
    return argument;
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSString *executableDirectory = QTPExecutableDirectory();
        if (!executableDirectory) {
            return 127;
        }

        NSString *contentsDirectory = executableDirectory.stringByDeletingLastPathComponent;
        NSString *pluginRoot = [contentsDirectory stringByAppendingPathComponent:@"PlugIns/QuickTimePlayerPlus"];
        NSString *realExecutable = [executableDirectory stringByAppendingPathComponent:@"QuickTime Player.real"];
        NSString *injector = [pluginRoot stringByAppendingPathComponent:@"QuickTimePlayerPlus.dylib"];

        setenv("DYLD_INSERT_LIBRARIES", injector.fileSystemRepresentation, 1);
        setenv("QTP_PLUGIN_PATH", pluginRoot.fileSystemRepresentation, 1);

        NSMutableArray<NSData *> *argumentData = [NSMutableArray array];
        [argumentData addObject:[realExecutable dataUsingEncoding:NSUTF8StringEncoding]];
        for (int index = 1; index < argc; index++) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            [argumentData addObject:[QTPNormalizeArgument(argument) dataUsingEncoding:NSUTF8StringEncoding]];
        }

        char **execArguments = calloc(argumentData.count + 1, sizeof(char *));
        if (!execArguments) {
            return 127;
        }

        for (NSUInteger index = 0; index < argumentData.count; index++) {
            execArguments[index] = (char *)argumentData[index].bytes;
        }

        execv(realExecutable.fileSystemRepresentation, execArguments);
        perror("execv");
        free(execArguments);
        return 127;
    }
}
