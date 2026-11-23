#import <Sparkle/Sparkle.h>

NS_ASSUME_NONNULL_BEGIN

@interface WorkstationUpdateDriver : SPUStandardUserDriver
@property (nonatomic, copy, nullable) void (^prepareUpdate)(void (^completion)(BOOL));
@end

NS_ASSUME_NONNULL_END
