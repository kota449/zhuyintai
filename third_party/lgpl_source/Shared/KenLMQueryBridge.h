#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KenLMQueryBridge : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError * _Nullable * _Nullable)error;
- (nullable NSNumber *)conditionalLog10WithContext:(NSString *)context
                                         candidate:(NSString *)candidate;

@end

NS_ASSUME_NONNULL_END
