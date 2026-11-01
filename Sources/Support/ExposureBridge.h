#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安全地设置曝光补偿。
///
/// `-[AVCaptureDevice setExposureTargetBias:completionHandler:]` 在参数不被设备接受时
/// 会抛 NSInvalidArgumentException，而 Swift 无法捕获 ObjC 异常，结果就是直接 abort。
/// 这里在 ObjC 层用 @try/@catch 兜住，返回 NO 表示设备拒绝，调用方可以降级处理。
BOOL LCSetExposureTargetBias(AVCaptureDevice *device, float bias);

NS_ASSUME_NONNULL_END
