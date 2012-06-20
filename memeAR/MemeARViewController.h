#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@class CIDetector;

@interface MemeARViewController : UIViewController <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    NSMutableDictionary* plistDict;
	IBOutlet UIView *previewView;
	AVCaptureVideoPreviewLayer *previewLayer;
	AVCaptureVideoDataOutput *videoDataOutput;
	BOOL detectFaces;
    int index;
	dispatch_queue_t videoDataOutputQueue;
	AVCaptureStillImageOutput *stillImageOutput;
	UIView *flashView;
	UIImage *square;
    NSMutableArray *memes;
    NSArray *memesImageNames;
    NSString *name;
	BOOL isUsingFrontFacingCamera;
	CIDetector *faceDetector;
	CGFloat beginGestureScale;
	CGFloat effectiveScale;
    int countDict;
    int totalFeatures;
}

@property (nonatomic,retain) UIToolbar *toolBar;
@property (nonatomic,retain) UIButton *button;

@end
