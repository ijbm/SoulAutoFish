// AutoFishJS.h
// Soul 派对钓鱼 · H5 注入引擎载体
#import <Foundation/Foundation.h>

@interface AutoFishJS : NSObject
/// 完整的注入引擎 JS（幂等，可重复注入）
+ (NSString *)engine;
@end
