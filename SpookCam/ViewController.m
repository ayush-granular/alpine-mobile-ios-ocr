//
//  ViewController.m
//  SpookCam
//
//  Created by Jack Wu on 2/21/2014.
//
//

#import "ViewController.h"
#import "ImageProcessor.h"
#import "UIImage+OrientationFix.h"
#import "LiveImageProcessor.h"
#import "AppDelegate.h"
#import <GLKit/GLKit.h>

@import Firebase;
@import AVFoundation;

NS_ENUM(NSInteger, SelectionType) {
    SelectionTypeRunning = 100,
    SelectionTypePaused
};

@interface ViewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, ImageProcessorDelegate>

@property (weak, nonatomic) IBOutlet UIImageView *mainImageView;
@property (weak, nonatomic) IBOutlet UILabel *digitsLabel;
@property (weak, nonatomic) IBOutlet UIButton *captureLiveButton;

@property (strong, nonatomic) UIImagePickerController * imagePickerController;
@property (strong, nonatomic) UIImage * workingImage;
@property (strong, nonatomic) FIRVisionTextRecognizer * textRecognizer;
@property (strong, nonatomic) LiveImageProcessor * liveProcessor;

@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    
    EAGLContext *eaglContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    UIWindow *window = ((AppDelegate *)[UIApplication sharedApplication].delegate).window;
    GLKView *view = [[GLKView alloc] initWithFrame:window.bounds context:eaglContext];
    _liveProcessor = [[LiveImageProcessor alloc] initWithContext:eaglContext inView:view];
    
    //[self setupWithImage:[UIImage imageNamed:@"ghost_tiny.png"]];
    FIRVision *vision = [FIRVision vision];
    _textRecognizer = [vision onDeviceTextRecognizer];
    
}

#pragma mark - Custom Accessors

- (UIImagePickerController *)imagePickerController {
  if (!_imagePickerController) { /* Lazy Loading */
    _imagePickerController = [[UIImagePickerController alloc] init];
    _imagePickerController.allowsEditing = NO;
    _imagePickerController.delegate = self;
  }
  return _imagePickerController;
}

#pragma mark - IBActions

- (IBAction)takePhotoFromCamera:(UIBarButtonItem *)sender {
  self.imagePickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
  [self presentViewController:self.imagePickerController animated:YES completion:nil];
  self.captureLiveButton.tag = SelectionTypeRunning;
  [self capturePhoto:self.captureLiveButton];
}

- (IBAction)takePhotoFromAlbum:(UIBarButtonItem *)sender {
  self.imagePickerController.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
  [self presentViewController:self.imagePickerController animated:YES completion:nil];
  self.captureLiveButton.tag = SelectionTypeRunning;
  [self capturePhoto:self.captureLiveButton];
}

- (IBAction)savePhoto:(UIBarButtonItem *)sender {
  if (!self.workingImage) {
    return;
  }
  UIImageWriteToSavedPhotosAlbum(self.workingImage, nil, nil, nil);
  self.captureLiveButton.tag = SelectionTypeRunning;
  [self capturePhoto:self.captureLiveButton];
}

- (IBAction)capturePhoto:(UIButton *)sender {
    switch (sender.tag) {
        case SelectionTypeRunning:
        {
            sender.tag = SelectionTypePaused;
            UIImage *capturedImage = [self.liveProcessor captureImageAndStop:YES];
            if (!capturedImage) {
                return;
            }
            [self setupWithImage:capturedImage];
            [sender setTitle:@"Resume" forState:UIControlStateNormal];
            self.view.backgroundColor = [UIColor whiteColor];
            [self.mainImageView setHidden:NO];
        }
            break;
        case SelectionTypePaused:
            sender.tag = SelectionTypeRunning;
            [self.liveProcessor resumeImageProcessing];
            [sender setTitle:@"Capture" forState:UIControlStateNormal];
            self.view.backgroundColor = [UIColor clearColor];
            [self.mainImageView setHidden:YES];
        default:
            break;
    }
}

#pragma mark - Private

- (void)setupWithImage:(UIImage*)image {
  UIImage * fixedImage = [image imageWithFixedOrientation];
  self.workingImage = fixedImage;
  self.mainImageView.image = fixedImage;
  
  // Commence with processing!
  //[self logPixelsOfImage:fixedImage];
  [ImageProcessor sharedProcessor].delegate = self;
  [[ImageProcessor sharedProcessor] processImage:fixedImage];
}

- (void)logPixelsOfImage:(UIImage*)image {
  // 1. Get pixels of image
  CGImageRef inputCGImage = [image CGImage];
  NSUInteger width = CGImageGetWidth(inputCGImage);
  NSUInteger height = CGImageGetHeight(inputCGImage);
  
  NSUInteger bytesPerPixel = 4;
  NSUInteger bytesPerRow = bytesPerPixel * width;
  NSUInteger bitsPerComponent = 8;
  
  UInt32 * pixels;
  pixels = (UInt32 *) calloc(height * width, sizeof(UInt32));
  
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(pixels, width, height,
                                               bitsPerComponent, bytesPerRow, colorSpace,
                                               kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
  
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), inputCGImage);
  
  CGColorSpaceRelease(colorSpace);
  CGContextRelease(context);
  
#define Mask8(x) ( (x) & 0xFF )
#define R(x) ( Mask8(x) )
#define G(x) ( Mask8(x >> 8 ) )
#define B(x) ( Mask8(x >> 16) )
  
  // 2. Iterate and log!
  NSLog(@"Brightness of image:");
  UInt32 * currentPixel = pixels;
  for (NSUInteger j = 0; j < height; j++) {
    for (NSUInteger i = 0; i < width; i++) {
      UInt32 color = *currentPixel;
      printf("%3.0f ", (R(color)+G(color)+B(color))/3.0);
      currentPixel++;
    }
    printf("\n");
  }
  
  free(pixels);
  
#undef R
#undef G
#undef B
  
}

#pragma mark - Protocol Conformance

- (void)imageProcessorFinishedProcessingWithImage:(UIImage *)outputImage withText:(NSString *)text {
  self.workingImage = outputImage;
  //self.mainImageView.image = outputImage;
  self.digitsLabel.text = text;
}

#pragma mark - UIImagePickerDelegate

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
  [[picker presentingViewController] dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
  // Dismiss the imagepicker
  [[picker presentingViewController] dismissViewControllerAnimated:YES completion:nil];
  
  /* Google OCR
  FIRVisionImage *image = [[FIRVisionImage alloc] initWithImage:info[UIImagePickerControllerOriginalImage]];
    // Calculate the image orientation
    FIRVisionDetectorImageOrientation orientation;
    
    // Using front-facing camera
    AVCaptureDevicePosition devicePosition = AVCaptureDevicePositionFront;
    
    UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;
    switch (deviceOrientation) {
        case UIDeviceOrientationPortrait:
            if (devicePosition == AVCaptureDevicePositionFront) {
                orientation = FIRVisionDetectorImageOrientationLeftTop;
            } else {
                orientation = FIRVisionDetectorImageOrientationRightTop;
            }
            break;
        case UIDeviceOrientationLandscapeLeft:
            if (devicePosition == AVCaptureDevicePositionFront) {
                orientation = FIRVisionDetectorImageOrientationBottomLeft;
            } else {
                orientation = FIRVisionDetectorImageOrientationTopLeft;
            }
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            if (devicePosition == AVCaptureDevicePositionFront) {
                orientation = FIRVisionDetectorImageOrientationRightBottom;
            } else {
                orientation = FIRVisionDetectorImageOrientationLeftBottom;
            }
            break;
        case UIDeviceOrientationLandscapeRight:
            if (devicePosition == AVCaptureDevicePositionFront) {
                orientation = FIRVisionDetectorImageOrientationTopRight;
            } else {
                orientation = FIRVisionDetectorImageOrientationBottomRight;
            }
            break;
        default:
            orientation = FIRVisionDetectorImageOrientationTopLeft;
            break;
    }
    
    FIRVisionImageMetadata *metadata = [[FIRVisionImageMetadata alloc] init];
    metadata.orientation = orientation;
    
    image.metadata = metadata;

    [_textRecognizer processImage:image
                       completion:^(FIRVisionText *_Nullable result,
                                    NSError *_Nullable error) {
                           if (error != nil || result == nil) {
                               // ...
                               return;
                           }
                           
                           // Recognized text
    }];
  */
  [self setupWithImage:info[UIImagePickerControllerOriginalImage]];
}

@end
