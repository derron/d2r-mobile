"""以合成手指与视图运行真实触摸处理器；UIKit 用最小 Foundation 对象替代，处理器从 front_ios.m 原样读取，不用设备、凭据或游戏数据。
Run the production Objective-C touch handler with synthetic fingers/views.

UIKit types are replaced with minimal Foundation objects; the handler itself is
read unchanged from front_ios.m. No device, credentials or game data are used.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SyncBuildTouchTests(unittest.TestCase):
    def test_build_caption_consumes_only_its_taps(self):
        text = (ROOT / "dm/ios/Sources/front_ios.m").read_text()
        start = text.index("- (NSSet<UITouch *> *)syncBuildTouches:")
        handler = text[start:text.index("- (void)sweepEndedSlots", start)]
        source = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdatomic.h>
#include <assert.h>
#include "dm_build_sync.h"
@interface UITouch : NSObject
@property CGPoint point;
- (CGPoint)locationInView:(id)view;
@end
@implementation UITouch
- (CGPoint)locationInView:(id)view { (void)view; return self.point; }
@end
@interface Controller : NSObject
@property id presentedViewController;
@end
@implementation Controller @end
@interface Window : NSObject
@property Controller *rootViewController;
@end
@implementation Window @end
static _Atomic int g_touch_frontend = 1;
static int visible = 1, opened;
int dm_update_build_rect(float rect[4]) {
    float r[] = {.1f,.8f,.4f,.95f}; memcpy(rect,r,sizeof r); return visible;
}
void dm_update_build_open(void) { opened++; }
@interface View : NSObject { UITouch *_buildFinger; dm_build_tap _buildTap; }
@property CGRect bounds;
@property Window *window;
- (NSSet<UITouch *> *)syncBuildTouches:(NSSet<UITouch *> *)touches phase:(int)phase;
@end
@implementation View
''' + handler + r'''
@end
static UITouch *finger(CGFloat x, CGFloat y) { UITouch *t=[UITouch new];t.point=CGPointMake(x,y);return t; }
int main(void) { @autoreleasepool {
    View *v=[View new]; v.bounds=CGRectMake(0,0,100,100);
    v.window=[Window new]; v.window.rootViewController=[Controller new];
    UITouch *a=finger(20,90), *b=finger(80,20);
    NSSet *both=[NSSet setWithObjects:a,b,nil], *one=[NSSet setWithObject:a];
    NSSet *rest=[v syncBuildTouches:both phase:0];
    assert(rest.count==1 && [rest containsObject:b]);
    a.point=CGPointMake(23,91);
    assert([v syncBuildTouches:one phase:1].count==0);
    rest=[v syncBuildTouches:both phase:2]; assert(opened==1 && rest.count==1 && [rest containsObject:b]);
    [v syncBuildTouches:one phase:0]; a.point=CGPointMake(50,91);
    [v syncBuildTouches:one phase:1]; a.point=CGPointMake(23,91);
    [v syncBuildTouches:one phase:2]; assert(opened==1); // 拖出再返回的手势仍取消。 | A drag that returns is still cancelled.
    [v syncBuildTouches:one phase:0]; [v syncBuildTouches:one phase:3];
    [v syncBuildTouches:one phase:2]; assert(opened==1);
    [v syncBuildTouches:one phase:0]; visible=0;
    assert([v syncBuildTouches:one phase:2].count==0 && opened==1); // 消耗已经隐藏目标的抬手事件。 | Consume a now-hidden target's release.
    assert([v syncBuildTouches:one phase:0].count==1); visible=1;
    atomic_store(&g_touch_frontend,0); assert([v syncBuildTouches:one phase:0].count==1);
    atomic_store(&g_touch_frontend,1);
    v.window.rootViewController.presentedViewController=[NSObject new];
    assert([v syncBuildTouches:one phase:0].count==1);
    v.window.rootViewController.presentedViewController=nil;
    v.bounds=CGRectMake(0,0,1024,576); a.point=CGPointMake(205,518);
    assert([v syncBuildTouches:one phase:0].count==0);
    assert([v syncBuildTouches:one phase:2].count==0 && opened==2);
    puts("PASS: tap, multi-touch, drag, cancel, hidden target, gameplay, modal and iPad UI view");
} }
'''
        with tempfile.TemporaryDirectory(prefix="build-touch-test-") as folder:
            path = Path(folder) / "touch.m"
            path.write_text(source)
            binary = Path(folder) / "touch"
            subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                            "-I" + str(ROOT / "dm/host"), str(path), "-framework", "Foundation",
                            "-framework", "CoreGraphics", "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
