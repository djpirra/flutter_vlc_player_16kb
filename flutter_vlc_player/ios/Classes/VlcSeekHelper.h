#import <Foundation/Foundation.h>
#import <MobileVLCKit/MobileVLCKit.h>

@interface VlcSeekHelper : NSObject

+ (void)seekPlayer:(VLCMediaPlayer *)player toPosition:(float)position fast:(BOOL)isFast;
+ (void)seekPlayer:(VLCMediaPlayer *)player toTime:(int64_t)time fast:(BOOL)isFast;

@end
