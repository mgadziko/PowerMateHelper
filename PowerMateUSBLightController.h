#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PowerMateUSBLightController : NSObject

+ (BOOL)setBrightness:(double)brightness;
+ (BOOL)setPulseEnabled:(BOOL)enabled;
+ (BOOL)setPulseRate:(double)pulseRate;

@end

NS_ASSUME_NONNULL_END
