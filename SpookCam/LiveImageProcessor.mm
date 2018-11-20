//
//  LiveImageProcessor.m
//  SpookCam
//
//  Created by Ayush Chamoli on 10/8/18.
//

#import "LiveImageProcessor.h"
#import "AppDelegate.h"

#ifdef __cplusplus
#import <opencv2/imgcodecs/ios.h>
#endif

#include <iostream>
#include <algorithm>

using namespace std;
using namespace cv;

#import <AVFoundation/AVFoundation.h>
#import <GLKit/GLKit.h>

@interface LiveImageProcessor()<AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong)AVCaptureDevice *videoDevice;
@property (nonatomic, strong)AVCaptureSession *captureSession;
@property (nonatomic, strong)dispatch_queue_t captureSessionQueue;

@property (nonatomic, strong)GLKView *videoPreviewView;
@property (nonatomic, strong)CIContext *ciContext;
@property (nonatomic, strong)CIContext *rectContext;
@property (nonatomic, assign)CGRect videoPreviewViewBounds;
@property (nonatomic, strong)EAGLContext *eaglContext;
@property (nonatomic, strong)CIDetector *detector;
@property (nonatomic, strong)UIImage *lastFrameImage;

@end

@implementation LiveImageProcessor

-(instancetype)initWithContext:(EAGLContext*)eaglContext inView:(GLKView*)view {
    self = [super init];
    if(self)
    {
        _videoPreviewView = view;
        _eaglContext = eaglContext;
        // create the CIContext instance, note that this must be done after _videoPreviewView is properly set up
        _ciContext = [CIContext contextWithEAGLContext:_eaglContext options:@{kCIContextWorkingColorSpace : [NSNull null]} ];
        _rectContext = [[CIContext alloc] initWithOptions:nil];
        
        AVCaptureDeviceDiscoverySession *captureDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                                                                                                                mediaType:AVMediaTypeVideo
                                                                                                                                 position:AVCaptureDevicePositionBack];
        NSArray *captureDevices = [captureDeviceDiscoverySession devices];
        
        if ([captureDevices count] > 0)
        {
            [self configureSettings];
            [self start];
        }
        else
        {
            NSLog(@"No device with AVMediaTypeVideo");
        }
    }
    return self;
}

-(UIImage*)captureImageAndStop:(BOOL)stop {
    if (stop) {
        [self.captureSession stopRunning];
        [_videoPreviewView setHidden:YES];
    }
    return self.lastFrameImage;
}

- (void)resumeImageProcessing {
    [_videoPreviewView setHidden:NO];
    [self.captureSession startRunning];
}

- (void)configureSettings {
    // setup the GLKView for video/image preview
    UIWindow *window = ((AppDelegate *)[UIApplication sharedApplication].delegate).window;
    _videoPreviewView.enableSetNeedsDisplay = NO;

    // because the native video image from the back camera is in UIDeviceOrientationLandscapeLeft (i.e. the home button is on the right), we need to apply a clockwise 90 degree transform so that we can draw the video preview as if we were in a landscape-oriented view; if you're using the front camera and you want to have a mirrored preview (so that the user is seeing themselves in the mirror), you need to apply an additional horizontal flip (by concatenating CGAffineTransformMakeScale(-1.0, 1.0) to the rotation transform)
    _videoPreviewView.transform = CGAffineTransformMakeRotation(M_PI_2);
    _videoPreviewView.frame = window.bounds;

    // we make our video preview view a subview of the window, and send it to the back; this makes ViewController's view (and its UI elements) on top of the video preview, and also makes video preview unaffected by device rotation
    [window addSubview:_videoPreviewView];
    [window sendSubviewToBack:_videoPreviewView];

    // bind the frame buffer to get the frame buffer width and height;
    // the bounds used by CIContext when drawing to a GLKView are in pixels (not points),
    // hence the need to read from the frame buffer's width and height;
    // in addition, since we will be accessing the bounds in another queue (_captureSessionQueue),
    // we want to obtain this piece of information so that we won't be
    // accessing _videoPreviewView's properties from another thread/queue
    [_videoPreviewView bindDrawable];
    _videoPreviewViewBounds = CGRectZero;
    _videoPreviewViewBounds.size.width = _videoPreviewView.drawableWidth;
    _videoPreviewViewBounds.size.height = _videoPreviewView.drawableHeight;
}

-(void)start
{
    // Set up the CoreImage detector for rectangles
    _detector = [CIDetector detectorOfType:CIDetectorTypeRectangle context:nil
                                              options:@{ CIDetectorAccuracy:CIDetectorAccuracyLow }];
    
    AVCaptureDeviceDiscoverySession *captureDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                                                                                                            mediaType:AVMediaTypeVideo
                                                                                                                             position:AVCaptureDevicePositionBack];
    NSArray *videoDevices = [captureDeviceDiscoverySession devices];
    
    AVCaptureDevicePosition position = AVCaptureDevicePositionBack;
    
    for (AVCaptureDevice *device in videoDevices)
    {
        if (device.position == position) {
            _videoDevice = device;
            break;
        }
    }
    
    // obtain device input
    NSError *error = nil;
    AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:_videoDevice error:&error];
    if (!videoDeviceInput)
    {
        NSLog(@"%@", [NSString stringWithFormat:@"Unable to obtain video device input, error: %@", error]);
        return;
    }
    
    // obtain the preset and validate the preset
    NSString *preset = AVCaptureSessionPresetMedium;
    if (![_videoDevice supportsAVCaptureSessionPreset:preset])
    {
        NSLog(@"%@", [NSString stringWithFormat:@"Capture session preset not supported by video device: %@", preset]);
        return;
    }
    
    // create the capture session
    _captureSession = [[AVCaptureSession alloc] init];
    _captureSession.sessionPreset = preset;
    
    // CoreImage wants BGRA pixel format
    NSDictionary *outputSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : [NSNumber numberWithInteger:kCVPixelFormatType_32BGRA]};
    // create and configure video data output
    AVCaptureVideoDataOutput *videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    videoDataOutput.videoSettings = outputSettings;
    
    // create the dispatch queue for handling capture session delegate method calls
    _captureSessionQueue = dispatch_queue_create("capture_session_queue", NULL);
    [videoDataOutput setSampleBufferDelegate:self queue:_captureSessionQueue];
    videoDataOutput.alwaysDiscardsLateVideoFrames = YES;

    // begin configure capture session
    [_captureSession beginConfiguration];
    
    if (![_captureSession canAddOutput:videoDataOutput])
    {
        NSLog(@"Cannot add video data output");
        _captureSession = nil;
        return;
    }
    
    // connect the video device input and video data and still image outputs
    [_captureSession addInput:videoDeviceInput];
    [_captureSession addOutput:videoDataOutput];
    
    [_captureSession commitConfiguration];
    
    // then start everything
    [_captureSession startRunning];

}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *sourceImage = [CIImage imageWithCVPixelBuffer:(CVPixelBufferRef)imageBuffer options:nil];
    CGRect sourceExtent = sourceImage.extent;

//    // Image processing
//    CIFilter * vignetteFilter = [CIFilter filterWithName:@"CIVignetteEffect"];
//    [vignetteFilter setValue:sourceImage forKey:kCIInputImageKey];
//    [vignetteFilter setValue:[CIVector vectorWithX:sourceExtent.size.width/2 Y:sourceExtent.size.height/2] forKey:kCIInputCenterKey];
//    [vignetteFilter setValue:@(sourceExtent.size.width/2) forKey:kCIInputRadiusKey];
//    CIImage *filteredImage = [vignetteFilter outputImage];
//
//    CIFilter *effectFilter = [CIFilter filterWithName:@"CIPhotoEffectInstant"];
//    [effectFilter setValue:filteredImage forKey:kCIInputImageKey];
//    filteredImage = [effectFilter outputImage];
//
    // Display filtered image
    CGFloat sourceAspect = sourceExtent.size.width / sourceExtent.size.height;
    CGFloat previewAspect = _videoPreviewViewBounds.size.width  / _videoPreviewViewBounds.size.height;

    // we want to maintain the aspect radio of the screen size, so we clip the video image
    CGRect drawRect = sourceExtent;
    if (sourceAspect > previewAspect)
    {
        // use full height of the video image, and center crop the width
        drawRect.origin.x += (drawRect.size.width - drawRect.size.height * previewAspect) / 2.0;
        drawRect.size.width = drawRect.size.height * previewAspect;
    }
    else
    {
        // use full width of the video image, and center crop the height
        drawRect.origin.y += (drawRect.size.height - drawRect.size.width / previewAspect) / 2.0;
        drawRect.size.height = drawRect.size.width / previewAspect;
    }
    
    [_videoPreviewView bindDrawable];

    if (_eaglContext != [EAGLContext currentContext])
        [EAGLContext setCurrentContext:_eaglContext];

    // clear eagl view to grey
    glClearColor(0.5, 0.5, 0.5, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);

    // set the blend mode to "source over" so that CI will use that
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    if (sourceImage) {
        //NSArray *arrRectangles = [_detector featuresInImage:filteredImage options:nil];
        //CIRectangleFeature *feature = [self biggestRectangleInRectangles:arrRectangles];
        //UIImage *imageWithRect = [self drawRectangleOnImage:[[UIImage alloc] initWithCIImage:filteredImage]
        //                                            rect:feature.bounds];
        UIImage *imageWithRect = [self drawContourUsingOpenCV:sourceImage];
        CIImage *processedImage = [[CIImage alloc] initWithCGImage:imageWithRect.CGImage];
        [_ciContext drawImage:processedImage inRect:_videoPreviewViewBounds fromRect:drawRect];
        //[_ciContext drawImage:sourceImage inRect:_videoPreviewViewBounds fromRect:drawRect];
        //self.lastFrameImage = [self.videoPreviewView snapshot];
        self.lastFrameImage = [[UIImage alloc] initWithCIImage: sourceImage
                                                         scale: 1.0
                                                   orientation: UIImageOrientationRight];
    }

    [_videoPreviewView display];
}

-(UIImage *)drawRectangleOnImage:(UIImage *)img rect:(CGRect )rect{
    CGSize imgSize = img.size;
    CGFloat scale = 0;
    UIGraphicsBeginImageContextWithOptions(imgSize, NO, scale);
    //[[UIColor greenColor] setFill];
    //UIRectFill(rect);
    CGContextRef context = UIGraphicsGetCurrentContext();
    [img drawAtPoint:CGPointZero];
    //CGPathRef path = CGPathCreateWithRect(rect, NULL);
    [[UIColor redColor] setStroke];
    CGContextAddRect(context, rect);
    //CGContextAddPath(context, path);
    CGContextDrawPath(context, kCGPathStroke);
    //CGPathRelease(path);

    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

- (CIRectangleFeature *)biggestRectangleInRectangles:(NSArray*)rectangles
{
    if (![rectangles count]) return nil;
    
    float halfPerimiterValue = 0;
    
    CIRectangleFeature *biggestRectangle = [rectangles firstObject];
    
    for (CIRectangleFeature *rect in rectangles)
    {
        CGPoint p1 = rect.topLeft;
        CGPoint p2 = rect.topRight;
        CGFloat width = hypotf(p2.x - p1.x, p2.y - p1.y);
        
        CGPoint p3 = rect.topLeft;
        CGPoint p4 = rect.bottomLeft;
        CGFloat height = hypotf(p4.x - p3.x, p4.y - p3.y);
        CGFloat currentHalfPerimiterValue = (height)+(width);
        
        if (halfPerimiterValue < currentHalfPerimiterValue)
        {
            
            halfPerimiterValue = currentHalfPerimiterValue;
            biggestRectangle = rect;
            NSLog(@"height    %@", @(height));
            NSLog(@"width    %@", @(width));
        }
    }
    
    return biggestRectangle;
}

- (CIDetector *)highAccuracyRectangleDetector
{
    static CIDetector *detector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
                  {
                      detector = [CIDetector detectorOfType:CIDetectorTypeRectangle context:nil options:@{CIDetectorAccuracy : CIDetectorAccuracyHigh, CIDetectorAspectRatio: @1.667, CIDetectorMaxFeatureCount: @5}];
                  });
    return detector;
}

- (UIImage*)drawContourUsingOpenCV:(CIImage*)inputImage {
    UIImage *output;
    UIImage *input = [self imageFromCIImage:inputImage];
    // Convert the image from UIImage to Mat
    cv::Mat imageCV; UIImageToMat(input, imageCV);

    // OpenCV operations:
    // Convert the image from RGB to GrayScale
    cv::Mat gray; cvtColor(imageCV, gray, CV_RGBA2GRAY);

    cv::Mat threshold; cv::threshold(gray, threshold, 125, 255, CV_THRESH_BINARY);

    // Find rectangle
    std::vector<std::vector<cv::Point> > contours;

    findContours(threshold, contours, CV_RETR_EXTERNAL, CV_CHAIN_APPROX_SIMPLE);

    cv::Rect boundingRect;
    NSUInteger largestArea = 0;
    NSInteger largestContourIndex = -1;

    for(size_t i = 0; i < contours.size(); i++ )
    {
        double area = contourArea(contours[i], false);
        if (area > largestArea) {
            largestArea = area;
            largestContourIndex = i;
            boundingRect = cv::boundingRect(contours[i]);
        }
    }

    if (largestContourIndex == -1) {
        return input;
    }
    
    cv::drawContours(imageCV, contours, (int)largestContourIndex, cv::Scalar(0, 255, 0), 2);
    output = MatToUIImage(imageCV);
    return (output) ? output: input;
}

- (UIImage*)imageFromCIImage:(CIImage*)inputImage {
    CGImageRef image = [_rectContext createCGImage:inputImage fromRect:inputImage.extent];
    UIImage *outputImage = [[UIImage alloc] initWithCGImage:image];
    CGImageRelease(image);
    return outputImage;
}

@end
