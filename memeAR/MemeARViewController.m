#import "MemeARViewController.h"
#import "ExampleShareImage.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <AssertMacros.h>
#import <AssetsLibrary/AssetsLibrary.h>

#pragma mark-

static const NSString *AVCaptureStillImageIsCapturingStillImageContext = @"AVCaptureStillImageIsCapturingStillImageContext";

static CGFloat DegreesToRadians(CGFloat degrees) {return degrees * M_PI / 180;};

static void ReleaseCVPixelBuffer(void *pixel, const void *data, size_t size);
static void ReleaseCVPixelBuffer(void *pixel, const void *data, size_t size) 
{	
	CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)pixel;
	CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
	CVPixelBufferRelease( pixelBuffer );
}

static OSStatus CreateCGImageFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, CGImageRef *imageOut);
static OSStatus CreateCGImageFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, CGImageRef *imageOut) 
{	
	OSStatus err = noErr;
	OSType sourcePixelFormat;
	size_t width, height, sourceRowBytes;
	void *sourceBaseAddr = NULL;
	CGBitmapInfo bitmapInfo;
	CGColorSpaceRef colorspace = NULL;
	CGDataProviderRef provider = NULL;
	CGImageRef image = NULL;
	
	sourcePixelFormat = CVPixelBufferGetPixelFormatType( pixelBuffer );
	if ( kCVPixelFormatType_32ARGB == sourcePixelFormat )
		bitmapInfo = kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipFirst;
	else if ( kCVPixelFormatType_32BGRA == sourcePixelFormat )
		bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
	else
		return -95014;
	
	sourceRowBytes = CVPixelBufferGetBytesPerRow( pixelBuffer );
	width = CVPixelBufferGetWidth( pixelBuffer );
	height = CVPixelBufferGetHeight( pixelBuffer );
	
	CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
	sourceBaseAddr = CVPixelBufferGetBaseAddress( pixelBuffer );
	
	colorspace = CGColorSpaceCreateDeviceRGB();
    
	CVPixelBufferRetain( pixelBuffer );
	provider = CGDataProviderCreateWithData( (void *)pixelBuffer, sourceBaseAddr, sourceRowBytes * height, ReleaseCVPixelBuffer);
	image = CGImageCreate(width, height, 8, 32, sourceRowBytes, colorspace, bitmapInfo, provider, NULL, true, kCGRenderingIntentDefault);
	
bail:
	if ( err && image ) {
		CGImageRelease( image );
		image = NULL;
	}
	if ( provider ) CGDataProviderRelease( provider );
	if ( colorspace ) CGColorSpaceRelease( colorspace );
	*imageOut = image;
	return err;
}

static CGContextRef CreateCGBitmapContextForSize(CGSize size);
static CGContextRef CreateCGBitmapContextForSize(CGSize size)
{
    CGContextRef    context = NULL;
    CGColorSpaceRef colorSpace;
    int             bitmapBytesPerRow;
	
    bitmapBytesPerRow = (size.width * 4);
	
    colorSpace = CGColorSpaceCreateDeviceRGB();
    context = CGBitmapContextCreate (NULL,
									 size.width,
									 size.height,
									 8,
									 bitmapBytesPerRow,
									 colorSpace,
									 kCGImageAlphaPremultipliedLast);
	CGContextSetAllowsAntialiasing(context, NO);
    CGColorSpaceRelease( colorSpace );
    return context;
}

#pragma mark-

@interface UIImage (RotationMethods)
- (UIImage *)imageRotatedByDegrees:(CGFloat)degrees;
@end

@implementation UIImage (RotationMethods)

- (UIImage *)imageRotatedByDegrees:(CGFloat)degrees 
{   
	UIView *rotatedViewBox = [[UIView alloc] initWithFrame:CGRectMake(0,0,self.size.width, self.size.height)];
	CGAffineTransform t = CGAffineTransformMakeRotation(DegreesToRadians(degrees));
	rotatedViewBox.transform = t;
	CGSize rotatedSize = rotatedViewBox.frame.size;
	[rotatedViewBox release];
	
	UIGraphicsBeginImageContext(rotatedSize);
	CGContextRef bitmap = UIGraphicsGetCurrentContext();
	
	CGContextTranslateCTM(bitmap, rotatedSize.width/2, rotatedSize.height/2);
    
	CGContextRotateCTM(bitmap, DegreesToRadians(degrees));
	
	CGContextScaleCTM(bitmap, 1.0, -1.0);
	CGContextDrawImage(bitmap, CGRectMake(-self.size.width / 2, -self.size.height / 2, self.size.width, self.size.height), [self CGImage]);
	
	UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return newImage;
	
}

@end

#pragma mark-

@interface MemeARViewController (InternalMethods)
- (void)setupAVCapture;
- (void)teardownAVCapture;
- (void)drawFaceBoxesForFeatures:(NSArray *)features forVideoBox:(CGRect)clap orientation:(UIDeviceOrientation)orientation;
@end

@implementation MemeARViewController

@synthesize toolBar;
@synthesize button;

int faceIndex2 = 0;

- (void)setupAVCapture
{
	NSError *error = nil;
	
	AVCaptureSession *session = [AVCaptureSession new];
	if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone)
	    [session setSessionPreset:AVCaptureSessionPreset640x480];
	else
	    [session setSessionPreset:AVCaptureSessionPresetPhoto];
	
	AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
	require( error == nil, bail );
	
    isUsingFrontFacingCamera = NO;
	if ( [session canAddInput:deviceInput] )
		[session addInput:deviceInput];
	
	stillImageOutput = [AVCaptureStillImageOutput new];
	[stillImageOutput addObserver:self forKeyPath:@"capturingStillImage" options:NSKeyValueObservingOptionNew context:AVCaptureStillImageIsCapturingStillImageContext];
	if ( [session canAddOutput:stillImageOutput] )
		[session addOutput:stillImageOutput];
	
	videoDataOutput = [AVCaptureVideoDataOutput new];
	NSDictionary *rgbOutputSettings = [NSDictionary dictionaryWithObject:
									   [NSNumber numberWithInt:kCMPixelFormat_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey];
	[videoDataOutput setVideoSettings:rgbOutputSettings];
	[videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
	videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
	[videoDataOutput setSampleBufferDelegate:self queue:videoDataOutputQueue];
	
    if ( [session canAddOutput:videoDataOutput] )
		[session addOutput:videoDataOutput];
	[[videoDataOutput connectionWithMediaType:AVMediaTypeVideo] setEnabled:detectFaces];
	
	effectiveScale = 1.0;
	previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:session];
	[previewLayer setBackgroundColor:[[UIColor blackColor] CGColor]];
	[previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
	CALayer *rootLayer = [previewView layer];
	[rootLayer setMasksToBounds:YES];
	[previewLayer setFrame:[rootLayer bounds]];
	[rootLayer addSublayer:previewLayer];
	[session startRunning];
    
bail:
	[session release];
	if (error) {
		UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"Fallo con el error %d", (int)[error code]]
															message:[error localizedDescription]
														   delegate:nil 
												  cancelButtonTitle:@"Regresar" 
												  otherButtonTitles:nil];
		[alertView show];
		[alertView release];
		[self teardownAVCapture];
	}
}

- (void)teardownAVCapture
{
	[videoDataOutput release];
	if (videoDataOutputQueue)
		dispatch_release(videoDataOutputQueue);
	[stillImageOutput removeObserver:self forKeyPath:@"isCapturingStillImage"];
	[stillImageOutput release];
	[previewLayer removeFromSuperlayer];
	[previewLayer release];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ( context == AVCaptureStillImageIsCapturingStillImageContext ) {
		BOOL isCapturingStillImage = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		
		if ( isCapturingStillImage ) {
			flashView = [[UIView alloc] initWithFrame:[previewView frame]];
			[flashView setBackgroundColor:[UIColor whiteColor]];
			[flashView setAlpha:0.f];
            
            [self.view insertSubview: flashView belowSubview: self.button];
			
			[UIView animateWithDuration:.4f
							 animations:^{
								 [flashView setAlpha:1.f];
							 }
			 ];
		}
		else {
			[UIView animateWithDuration:.4f
							 animations:^{
								 [flashView setAlpha:0.f];
							 }
							 completion:^(BOOL finished){
								 [flashView removeFromSuperview];
								 [flashView release];
								 flashView = nil;
							 }
			 ];
		}
	}
}

- (AVCaptureVideoOrientation)avOrientationForDeviceOrientation:(UIDeviceOrientation)deviceOrientation
{
	AVCaptureVideoOrientation result = deviceOrientation;
	if ( deviceOrientation == UIDeviceOrientationLandscapeLeft )
		result = AVCaptureVideoOrientationLandscapeRight;
	else if ( deviceOrientation == UIDeviceOrientationLandscapeRight )
		result = AVCaptureVideoOrientationLandscapeLeft;
	return result;
}

- (CGImageRef)newSquareOverlayedImageForFeatures:(NSArray *)features 
                                       inCGImage:(CGImageRef)backgroundImage 
                                 withOrientation:(UIDeviceOrientation)orientation 
                                     frontFacing:(BOOL)isFrontFacing
{
	CGImageRef returnImage = NULL;
	CGRect backgroundImageRect = CGRectMake(0., 0., CGImageGetWidth(backgroundImage), CGImageGetHeight(backgroundImage));
	CGContextRef bitmapContext = CreateCGBitmapContextForSize(backgroundImageRect.size);
	CGContextClearRect(bitmapContext, backgroundImageRect);
	CGContextDrawImage(bitmapContext, backgroundImageRect, backgroundImage);
	CGFloat rotationDegrees = 0.;
	
	switch (orientation) {
		case UIDeviceOrientationPortrait:
			rotationDegrees = -90.;
			break;
		case UIDeviceOrientationPortraitUpsideDown:
			rotationDegrees = 90.;
			break;
		case UIDeviceOrientationLandscapeLeft:
			if (isFrontFacing) rotationDegrees = 180.;
			else rotationDegrees = 0.;
			break;
		case UIDeviceOrientationLandscapeRight:
			if (isFrontFacing) rotationDegrees = 0.;
			else rotationDegrees = 180.;
			break;
		case UIDeviceOrientationFaceUp:
		case UIDeviceOrientationFaceDown:
		default:
			break;
	}
	//UIImage *rotatedSquareImage = [square imageRotatedByDegrees:rotationDegrees];
	
    int faceIndex = 0;
	for ( CIFaceFeature *ff in features ) {
		CGRect faceRect = [ff bounds];
        
        if(isFrontFacing){ // front facing
            
            faceRect.size.width *= 1.34;
            faceRect.size.height *= 1.34;
            
            if(UIDeviceOrientationIsLandscape(orientation)){ // is landscape
                
                if(UIDeviceOrientationLandscapeLeft == orientation){ // landscape left
                    
                    faceRect.origin.x -= faceRect.size.width/5;
                    faceRect.origin.y -= faceRect.size.height/5; // this moves y
                    
                } else { // landscape right
                    
                    faceRect.origin.x -= faceRect.size.width/10;
                    faceRect.origin.y -= faceRect.size.height * 0.01; // this moves y
                    
                }
                
            } else { // portrait
                
                faceRect.origin.x -= faceRect.size.height/4.4;
                faceRect.origin.y -= faceRect.size.width/9.3;
                
            }
            
        } else { // back camera
            
            faceRect.size.width *= 1.385;
            faceRect.size.height *= 1.385;
            
            if(UIDeviceOrientationIsLandscape(orientation)){ // is landscape
                
                if(UIDeviceOrientationLandscapeLeft == orientation){ // landscape left
                    
                    faceRect.origin.x += faceRect.size.width * 0.12;
                    faceRect.origin.y += faceRect.size.height * 0.05; // this moves y
                    
                } else { //landscape right
                    
                    faceRect.origin.x += faceRect.size.width * 0.08;
                    faceRect.origin.y -= faceRect.size.height/7.5; // this moves y
                    
                }
                
            }
            
            faceRect.origin.x -= faceRect.size.height/4;
            faceRect.origin.y -= faceRect.size.width/8.9;
            
        }
        
		CGContextDrawImage(bitmapContext, faceRect, [[[memes objectAtIndex:faceIndex++] imageRotatedByDegrees:rotationDegrees] CGImage]);
	}
	returnImage = CGBitmapContextCreateImage(bitmapContext);
	CGContextRelease (bitmapContext);
	
	return returnImage;
}

- (BOOL)writeCGImageToCameraRoll:(CGImageRef)cgImage withMetadata:(NSDictionary *)metadata withOrientation:(int)orientation
{
    UIImageOrientation newOrientation;  
    switch (orientation) {  
        case 1:  
            newOrientation = UIImageOrientationUp;  
            break;  
        case 3:  
            newOrientation = UIImageOrientationDown;  
            break;  
        case 8:  
            newOrientation = UIImageOrientationLeft;  
            break;  
        case 6:  
            newOrientation = UIImageOrientationRight;  
            break;  
        case 2:  
            newOrientation = UIImageOrientationUpMirrored;  
            break;  
        case 4:  
            newOrientation = UIImageOrientationDownMirrored;  
            break;  
        case 5:  
            newOrientation = UIImageOrientationLeftMirrored;  
            break;  
        case 7:  
            newOrientation = UIImageOrientationRightMirrored;  
            break;  
    }  
    
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:1 orientation:newOrientation];
    
    ExampleShareImage *shareImage = [[[ExampleShareImage alloc] initWithNibName:nil bundle:nil] autorelease];
    shareImage.image = image;
    
    [image release];
    
    //[self presentModalViewController:shareImage animated:YES];
    [self.navigationController pushViewController:shareImage animated:YES];
    
    return YES;
    
    /*
     
     CFMutableDataRef destinationData = CFDataCreateMutable(kCFAllocatorDefault, 0);
     CGImageDestinationRef destination = CGImageDestinationCreateWithData(destinationData,CFSTR("public.jpeg"),1,NULL);
     
     BOOL success = (destination != NULL);
     require(success, bail);
     
     const float JPEGCompQuality = 0.85f;
     CFMutableDictionaryRef optionsDict = NULL;
     CFNumberRef qualityNum = NULL;
     
     qualityNum = CFNumberCreate(0, kCFNumberFloatType, &JPEGCompQuality);    
     if ( qualityNum ) {
     optionsDict = CFDictionaryCreateMutable(0, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
     if ( optionsDict )
     CFDictionarySetValue(optionsDict, kCGImageDestinationLossyCompressionQuality, qualityNum);
     CFRelease( qualityNum );
     }
     
     CGImageDestinationAddImage( destination, cgImage, optionsDict );
     success = CGImageDestinationFinalize( destination );
     
     if ( optionsDict )
     CFRelease(optionsDict);
     
     require(success, bail);
     
     CFRetain(destinationData);
     ALAssetsLibrary *library = [ALAssetsLibrary new];
     [library writeImageDataToSavedPhotosAlbum:(id)destinationData metadata:metadata completionBlock:^(NSURL *assetURL, NSError *error) {
     if (destinationData)
     CFRelease(destinationData);
     }];
     [library release];
     
     bail:
     if (destinationData)
     CFRelease(destinationData);
     if (destination)
     CFRelease(destination);
     return success;
     */
}
- (void)displayErrorOnMainQueue:(NSError *)error withMessage:(NSString *)message
{
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"%@ (%d)", message, (int)[error code]]
															message:[error localizedDescription]
														   delegate:nil 
												  cancelButtonTitle:@"Regresar" 
												  otherButtonTitles:nil];
		[alertView show];
		[alertView release];
	});
}
- (void)takePicture:(id)sender
{
	AVCaptureConnection *stillImageConnection = [stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
	UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];
	AVCaptureVideoOrientation avcaptureOrientation = [self avOrientationForDeviceOrientation:curDeviceOrientation];
	[stillImageConnection setVideoOrientation:avcaptureOrientation];
	[stillImageConnection setVideoScaleAndCropFactor:effectiveScale];
	
    BOOL doingFaceDetection = detectFaces;
	
    if (doingFaceDetection)
		[stillImageOutput setOutputSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCMPixelFormat_32BGRA] 
																		forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
	else
		[stillImageOutput setOutputSettings:[NSDictionary dictionaryWithObject:AVVideoCodecJPEG 
																		forKey:AVVideoCodecKey]]; 
	
	[stillImageOutput captureStillImageAsynchronouslyFromConnection:stillImageConnection
                                                  completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
                                                      if (error) {
                                                          [self displayErrorOnMainQueue:error withMessage:@"Error al tomar foto"];
                                                      }
                                                      else {
                                                          if (doingFaceDetection) {
                                                              CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(imageDataSampleBuffer);
                                                              CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, imageDataSampleBuffer, kCMAttachmentMode_ShouldPropagate);
                                                              CIImage *ciImage = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffer options:(NSDictionary *)attachments];
                                                              if (attachments)
                                                                  CFRelease(attachments);
                                                              
                                                              NSDictionary *imageOptions = nil;
                                                              NSNumber *orientation = CMGetAttachment(imageDataSampleBuffer, kCGImagePropertyOrientation, NULL);
                                                              if (orientation) {
                                                                  imageOptions = [NSDictionary dictionaryWithObject:orientation forKey:CIDetectorImageOrientation];
                                                              }
                                                              
                                                              dispatch_sync(videoDataOutputQueue, ^(void) {
                                                                  NSArray *features = [faceDetector featuresInImage:ciImage options:imageOptions];
                                                                  CGImageRef srcImage = NULL;
                                                                  OSStatus err = CreateCGImageFromCVPixelBuffer(CMSampleBufferGetImageBuffer(imageDataSampleBuffer), &srcImage);
                                                                  check(!err);
                                                                  
                                                                  CGImageRef cgImageResult = [self newSquareOverlayedImageForFeatures:features 
                                                                                                                            inCGImage:srcImage 
                                                                                                                      withOrientation:curDeviceOrientation 
                                                                                                                          frontFacing:isUsingFrontFacingCamera];
                                                                  if (srcImage)
                                                                      CFRelease(srcImage);
                                                                  
                                                                  CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, 
                                                                                                                              imageDataSampleBuffer, 
                                                                                                                              kCMAttachmentMode_ShouldPropagate);
                                                                  [self writeCGImageToCameraRoll:cgImageResult withMetadata:(id)attachments withOrientation:[[imageOptions objectForKey:CIDetectorImageOrientation]intValue]];
                                                                  if (attachments)
                                                                      CFRelease(attachments);
                                                                  if (cgImageResult)
                                                                      CFRelease(cgImageResult);
                                                                  
                                                              });
                                                              
                                                              [ciImage release];
                                                          }
                                                          else {
                                                              NSData *jpegData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                                                              CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, 
                                                                                                                          imageDataSampleBuffer, 
                                                                                                                          kCMAttachmentMode_ShouldPropagate);
                                                              ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                                                              [library writeImageDataToSavedPhotosAlbum:jpegData metadata:(id)attachments completionBlock:^(NSURL *assetURL, NSError *error) {
                                                                  if (error) {
                                                                      [self displayErrorOnMainQueue:error withMessage:@"Error al guardar al album"];
                                                                  }
                                                              }];
                                                              
                                                              if (attachments)
                                                                  CFRelease(attachments);
                                                              [library release];
                                                          }
                                                      }
                                                  }
	 ];
}

+ (CGRect)videoPreviewBoxForGravity:(NSString *)gravity frameSize:(CGSize)frameSize apertureSize:(CGSize)apertureSize
{
    CGFloat apertureRatio = apertureSize.height / apertureSize.width;
    CGFloat viewRatio = frameSize.width / frameSize.height;
    
    CGSize size = CGSizeZero;
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        if (viewRatio > apertureRatio) {
            size.width = frameSize.width;
            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
        } else {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
            size.height = frameSize.height;
        }
    } else if ([gravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
        if (viewRatio > apertureRatio) {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
            size.height = frameSize.height;
        } else {
            size.width = frameSize.width;
            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
        }
    } else if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
        size.width = frameSize.width;
        size.height = frameSize.height;
    }
	
	CGRect videoBox;
	videoBox.size = size;
	if (size.width < frameSize.width)
		videoBox.origin.x = (frameSize.width - size.width) / 2;
	else
		videoBox.origin.x = (size.width - frameSize.width) / 2;
	
	if ( size.height < frameSize.height )
		videoBox.origin.y = (frameSize.height - size.height) / 2;
	else
		videoBox.origin.y = (size.height - frameSize.height) / 2;
    
	return videoBox;
}

- (void)drawFaceBoxesForFeatures:(NSArray *)features forVideoBox:(CGRect)clap orientation:(UIDeviceOrientation)orientation
{
	NSArray *sublayers = [NSArray arrayWithArray:[previewLayer sublayers]];
	NSInteger sublayersCount = [sublayers count], currentSublayer = 0;
	NSInteger featuresCount = [features count], currentFeature = 0;
    
    totalFeatures = featuresCount;
	
	[CATransaction begin];
	[CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
    
	for ( CALayer *layer in sublayers ) {
		if ( [[layer name] isEqualToString:@"FaceLayer"] )
			[layer setHidden:YES];
	}
	
	if ( featuresCount == 0 || !detectFaces ) {
		[CATransaction commit];
		return;
	}
    
	CGSize parentFrameSize = [previewView frame].size;
	NSString *gravity = [previewLayer videoGravity];
	BOOL isMirrored = [previewLayer isMirrored];
	CGRect previewBox = [MemeARViewController videoPreviewBoxForGravity:gravity 
                                                              frameSize:parentFrameSize 
                                                           apertureSize:clap.size];
    
	for ( CIFaceFeature *ff in features ) {
        
		CGRect faceRect = [ff bounds];
		CGFloat temp = faceRect.size.width;
		faceRect.size.width = faceRect.size.height;
		faceRect.size.height = temp;
		temp = faceRect.origin.x;
		faceRect.origin.x = faceRect.origin.y;
		faceRect.origin.y = temp;
		CGFloat widthScaleBy = previewBox.size.width / clap.size.height;
		CGFloat heightScaleBy = previewBox.size.height / clap.size.width;
		faceRect.size.width *= widthScaleBy;
		faceRect.size.height *= heightScaleBy;
		faceRect.origin.x *= widthScaleBy;
		faceRect.origin.y *= heightScaleBy;
        
        if ( isMirrored ){
            faceRect.size.width += (faceRect.size.width * 0.32);
            faceRect.size.height += (faceRect.size.height * 0.32);
            
            if(UIDeviceOrientationIsLandscape(orientation)){
                
                if(UIDeviceOrientationLandscapeLeft == orientation){ // landscape left
                    
                    faceRect.origin.y -= (faceRect.size.width / 7.3);
                    faceRect.origin.x -= (faceRect.size.height / 5.5); //this moves y
                    
                } else { // landscape right
                    
                    faceRect.origin.y -= (faceRect.size.width / 6.5);
                    faceRect.origin.x += (faceRect.size.height * .02); //this moves y
                    
                }
                
            } else { // portrait
                faceRect.origin.x -= (faceRect.size.width / 10);
                faceRect.origin.y -= (faceRect.size.height / 4);
            }
            
            
        } else {
            faceRect.size.width += (faceRect.size.width * 0.4);
            faceRect.size.height += (faceRect.size.height * 0.4);
            
            if(UIDeviceOrientationIsLandscape(orientation)){
                
                if(UIDeviceOrientationLandscapeLeft == orientation){ // landscape left
                    
                    faceRect.origin.x -= (faceRect.size.height / 12); // this moves y
                    faceRect.origin.y -= (faceRect.size.width / 7.5);
                    
                } else { // landscape right
                    
                    faceRect.origin.y -= (faceRect.size.width / 6);
                    faceRect.origin.x -= (faceRect.size.height / 3.7); //this moves y
                    
                }
                
            } else {
                faceRect.origin.x -= (faceRect.size.width / 6.5);
                faceRect.origin.y -= (faceRect.size.height / 4);
            }
            
        }
        
		if ( isMirrored )
			faceRect = CGRectOffset(faceRect, previewBox.origin.x + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
		else
			faceRect = CGRectOffset(faceRect, previewBox.origin.x, previewBox.origin.y);
        
		CALayer *featureLayer = nil;
		
		while ( !featureLayer && (currentSublayer < sublayersCount) ) {
			CALayer *currentLayer = [sublayers objectAtIndex:currentSublayer++];
			if ( [[currentLayer name] isEqualToString:@"FaceLayer"] ) {
				featureLayer = currentLayer;
				[currentLayer setHidden:NO];
			}
		}
        
		if ( !featureLayer ) {
			featureLayer = [CALayer new];
			//[featureLayer setContents:(id)[square CGImage]];
            [featureLayer setContents:(id)[[memes objectAtIndex:0] CGImage]];
			[featureLayer setName:@"FaceLayer"];
			[previewLayer addSublayer:featureLayer];
			[featureLayer release];
		}
		[featureLayer setFrame:faceRect];
		
		switch (orientation) {
			case UIDeviceOrientationPortrait:
				[featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(0.))];
				break;
			case UIDeviceOrientationPortraitUpsideDown:
				[featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(180.))];
				break;
			case UIDeviceOrientationLandscapeLeft:
				[featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(90.))];
				break;
			case UIDeviceOrientationLandscapeRight:
				[featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(-90.))];
				break;
			case UIDeviceOrientationFaceUp:
			case UIDeviceOrientationFaceDown:
			default:
				break;
		}
		currentFeature++;
	}
	
	[CATransaction commit];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{	
	CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
	CIImage *ciImage = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffer options:(NSDictionary *)attachments];
	if (attachments)
		CFRelease(attachments);
	NSDictionary *imageOptions = nil;
	UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];
	int exifOrientation;
    
	enum {
		PHOTOS_EXIF_0ROW_TOP_0COL_LEFT			= 1,
		PHOTOS_EXIF_0ROW_TOP_0COL_RIGHT			= 2,
		PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT      = 3,
		PHOTOS_EXIF_0ROW_BOTTOM_0COL_LEFT       = 4,
		PHOTOS_EXIF_0ROW_LEFT_0COL_TOP          = 5, 
		PHOTOS_EXIF_0ROW_RIGHT_0COL_TOP         = 6,  
		PHOTOS_EXIF_0ROW_RIGHT_0COL_BOTTOM      = 7,  
		PHOTOS_EXIF_0ROW_LEFT_0COL_BOTTOM       = 8  
	};
	
	switch (curDeviceOrientation) {
		case UIDeviceOrientationPortraitUpsideDown:
			exifOrientation = PHOTOS_EXIF_0ROW_LEFT_0COL_BOTTOM;
			break;
		case UIDeviceOrientationLandscapeLeft:
			if (isUsingFrontFacingCamera)
				exifOrientation = PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT;
			else
				exifOrientation = PHOTOS_EXIF_0ROW_TOP_0COL_LEFT;
			break;
		case UIDeviceOrientationLandscapeRight:
			if (isUsingFrontFacingCamera)
				exifOrientation = PHOTOS_EXIF_0ROW_TOP_0COL_LEFT;
			else
				exifOrientation = PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT;
			break;
		case UIDeviceOrientationPortrait:
		default:
			exifOrientation = PHOTOS_EXIF_0ROW_RIGHT_0COL_TOP;
			break;
	}
    
	imageOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:exifOrientation] forKey:CIDetectorImageOrientation];
	NSArray *features = [faceDetector featuresInImage:ciImage options:imageOptions];
	[ciImage release];
	CMFormatDescriptionRef fdesc = CMSampleBufferGetFormatDescription(sampleBuffer);
	CGRect clap = CMVideoFormatDescriptionGetCleanAperture(fdesc, false);
	
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		[self drawFaceBoxesForFeatures:features forVideoBox:clap orientation:curDeviceOrientation];
	});
}

- (void) turnTorchOn: (bool) on {
    Class captureDeviceClass = NSClassFromString(@"AVCaptureDevice");
    if (captureDeviceClass != nil) {
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if ([device hasTorch]){
            
            [device lockForConfiguration:nil];
            if (on) {
                [device setTorchMode:AVCaptureTorchModeOn];
            } else {
                [device setTorchMode:AVCaptureTorchModeOff];          
            }
            [device unlockForConfiguration];
        }
    }
}

- (void)switchCameras:(id)sender
{
	AVCaptureDevicePosition desiredPosition;
	if (isUsingFrontFacingCamera)
		desiredPosition = AVCaptureDevicePositionBack;
	else
		desiredPosition = AVCaptureDevicePositionFront;
	
	for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
		if ([d position] == desiredPosition) {
			[[previewLayer session] beginConfiguration];
			AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:d error:nil];
			for (AVCaptureInput *oldInput in [[previewLayer session] inputs]) {
				[[previewLayer session] removeInput:oldInput];
			}
			[[previewLayer session] addInput:input];
			[[previewLayer session] commitConfiguration];
			break;
		}
	}
	isUsingFrontFacingCamera = !isUsingFrontFacingCamera;
}

- (void)switchFace:(id)sender
{
	index = arc4random() % countDict;
    //name = [memesImageNames objectAtIndex:index];
	//square = [UIImage imageNamed:[NSString stringWithFormat:@"%@.png", name]];
    //square = [memes objectAtIndex:index];
    
    NSArray *sublayers = [NSArray arrayWithArray:[previewLayer sublayers]];
    
    int faceIndex = 0;
	for ( CALayer *layer in sublayers ) {
		if ( [[layer name] isEqualToString:@"FaceLayer"] ){
			//[layer setContents:(id)[square CGImage]];
            
            UIImage *random = [memes objectAtIndex:arc4random() % countDict];
            
            [memes removeObject:random];
            [memes insertObject:random atIndex:faceIndex];
            
            [layer setContents:(id)[[memes objectAtIndex:faceIndex] CGImage]];
            
            faceIndex++;
        }
	}
    
}

-(void) addCenterButtonWithImage:(UIImage*)buttonImage highlightImage:(UIImage*)highlightImage
{
    self.button = [UIButton buttonWithType:UIButtonTypeCustom];
    self.button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleTopMargin;
    self.button.frame = CGRectMake(0.0, 0.0, buttonImage.size.width, buttonImage.size.height);
    [self.button setBackgroundImage:buttonImage forState:UIControlStateNormal];
    [self.button setBackgroundImage:highlightImage forState:UIControlStateHighlighted];
    [self.button addTarget:self action:@selector(takePicture:) forControlEvents:UIControlEventTouchUpInside];
    
    CGFloat heightDifference = buttonImage.size.height - self.view.frame.size.height;
    if (heightDifference < 0)
        self.button.center = CGPointMake(self.view.frame.size.width/2,self.view.frame.size.height - 30 );
    else
    {
        CGPoint center = CGPointMake(50, 100);
        center.y = center.y - heightDifference/2.0;
        self.button.center = center;
    }
    
    [self.view addSubview:self.button];
    [self.view bringSubviewToFront:self.button];
}

- (void)dealloc
{
	[self teardownAVCapture];
	[faceDetector release];
	[square release];
	[super dealloc];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [[UIApplication sharedApplication] setStatusBarHidden:YES];
    
    
    index = 0;
    detectFaces = YES;
    
    UIBarButtonItem *changeCamera = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCamera target:self action:@selector(switchCameras:)];
    
    UIBarButtonItem *barBtnRightButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(switchFace:)];
    
    UIBarButtonItem *flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    
    NSArray *toolbarButtons = [[NSArray alloc] initWithObjects:changeCamera, flexSpace, barBtnRightButton, nil];
    
    self.toolBar.items = toolbarButtons;
    [self.view addSubview:self.toolBar];
    
    [self.toolBar release];
    
    [self addCenterButtonWithImage:[UIImage imageNamed:@"tabBar.png"] highlightImage:nil];
    
	[self setupAVCapture];
    
    memes = [[NSMutableArray alloc] init];
    
    NSString *images = [[NSBundle mainBundle] pathForResource:@"images" ofType:@"plist"];
    memesImageNames = [[NSArray arrayWithContentsOfFile:images] retain];
    name = [[memesImageNames objectAtIndex:index] retain];
    
    for (int i=0; i<memesImageNames.count; i++){
        [memes addObject:[UIImage imageNamed:[NSString stringWithFormat:@"%@.png",[memesImageNames objectAtIndex:i]]]];
    }
    
    countDict = [memesImageNames count];
    
    square = [memes objectAtIndex:0];
    
	//square = [[UIImage imageNamed:[NSString stringWithFormat:@"%@.png", name]] retain];
    NSDictionary *detectorOptions = [[NSDictionary alloc] initWithObjectsAndKeys:CIDetectorAccuracyLow, CIDetectorAccuracy, nil];
	faceDetector = [[CIDetector detectorOfType:CIDetectorTypeFace context:nil options:detectorOptions] retain];
	[detectorOptions release];
}

- (void)viewDidUnload
{
    [super viewDidUnload];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES];
    [self.navigationController setToolbarHidden:YES];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
	return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

@end
