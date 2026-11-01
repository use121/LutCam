#import "ExposureBridge.h"

BOOL LCSetExposureTargetBias(AVCaptureDevice *device, float bias) {
    @try {
        [device setExposureTargetBias:bias completionHandler:nil];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[LutCam] setExposureTargetBias(%.3f) 被设备拒绝: %@ — %@",
              bias, exception.name, exception.reason);
        return NO;
    }
}
