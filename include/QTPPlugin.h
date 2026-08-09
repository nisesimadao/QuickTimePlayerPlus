#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (*QTPPluginMainFunction)(void);

FOUNDATION_EXPORT NSString * const QTPPluginDidLoadNotification;

static inline void QTPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static inline void QTPLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[QuickTimePlayer+] %@", message);
}

NS_ASSUME_NONNULL_END
