//
//  ImageProcessor.m
//  SpookCam
//
//  Created by Jack Wu on 2/21/2014.
//
//

#import "ImageProcessor.h"
#import "SpookCam-Swift.h"
#import <ImageIO/ImageIO.h>
#import <TesseractOCR/TesseractOCR.h>

#ifdef __cplusplus
#import <opencv2/imgcodecs/ios.h>
#endif

#include <iostream>
#include <algorithm>

using namespace std;
using namespace cv;
static ImageProcessor *sharedInstance = nil;

@interface ImageProcessor ()
@property(nonatomic, strong) NSMutableString* strDigits;
@property(nonatomic, strong) G8Tesseract *tesseract;
@end

@implementation ImageProcessor

+ (instancetype)sharedProcessor {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
        sharedInstance.tesseract = [[G8Tesseract alloc] initWithLanguage:@"eng"];
        sharedInstance.tesseract.charWhitelist = @"0123456789";
        sharedInstance.tesseract.rect = CGRectMake(20, 20, 100, 100);
        sharedInstance.tesseract.maximumRecognitionTime = 2.0;
    });
    
    return sharedInstance;
}

#pragma mark - Public

- (void)processImage:(UIImage*)inputImage {
    /*
    UIImage *scaledImage = [ImagePreProcessor scaleImageWithInputImage:inputImage with:CGSizeMake(500, 500)];
    UIImage *output = [ImagePreProcessor convertImageToGrayScaleWithInputImage:scaledImage];
    //output = [ImagePreProcessor applyBlurEffectWithInputImage:output];
    CIImage *ciImage = (CIImage*)[ImagePreProcessor detectRectangleAndCropInImage:output processImage:scaledImage];
//    //return  output;
//
    CGImageRef imageRef = [[CIContext contextWithOptions:nil] createCGImage:ciImage
                                                                   fromRect:ciImage.extent];
    
    UIImage * outputImage = [self convertToBlackAndWhiteNoGrayScale:[UIImage imageWithCGImage:imageRef]];
    
//    UIImage * outputImage = [self convertToBlackAndWhiteNoGrayScale:scaledImage];

    // Remove any half tones to get more clear image.
    //outputImage = [self convertToBlackAndWhiteNoGrayScale:outputImage];
*/
    UIImage *outputImage = [self processImageUsingOpenCV:inputImage];
    if ([self.delegate respondsToSelector:
         @selector(imageProcessorFinishedProcessingWithImage:withText:)]) {
        [self.delegate imageProcessorFinishedProcessingWithImage:outputImage withText:_strDigits];
    }
}

#pragma mark - Private

#define Mask8(x) ( (x) & 0xFF )
#define R(x) ( Mask8(x) )
#define G(x) ( Mask8(x >> 8 ) )
#define B(x) ( Mask8(x >> 16) )
#define A(x) ( Mask8(x >> 24) )
#define RGBAMake(r, g, b, a) ( Mask8(r) | Mask8(g) << 8 | Mask8(b) << 16 | Mask8(a) << 24 )
- (UIImage *)processUsingPixels:(UIImage*)inputImage {
    
    // 1. Get the raw pixels of the image
    UInt32 * inputPixels;
    
    CGImageRef inputCGImage = [inputImage CGImage];
    NSUInteger inputWidth = CGImageGetWidth(inputCGImage);
    NSUInteger inputHeight = CGImageGetHeight(inputCGImage);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    NSUInteger bytesPerPixel = 4;
    NSUInteger bitsPerComponent = 8;
    
    NSUInteger inputBytesPerRow = bytesPerPixel * inputWidth;
    
    inputPixels = (UInt32 *)calloc(inputHeight * inputWidth, sizeof(UInt32));
    
    CGContextRef context = CGBitmapContextCreate(inputPixels, inputWidth, inputHeight,
                                                 bitsPerComponent, inputBytesPerRow, colorSpace,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    
    CGContextDrawImage(context, CGRectMake(0, 0, inputWidth, inputHeight), inputCGImage);
    
    UIImage * ghostImage = [UIImage imageNamed:@"ghost"];
    CGImageRef ghostCGImage = [ghostImage CGImage];
    
    CGFloat ghostImageAspectRatio = ghostImage.size.width / ghostImage.size.height;
    NSInteger targetGhostWidth = inputWidth * 0.25;
    CGSize ghostSize = CGSizeMake(targetGhostWidth, targetGhostWidth / ghostImageAspectRatio);
    CGPoint ghostOrigin = CGPointMake(inputWidth * 0.5, inputHeight * 0.2);
    
    NSUInteger ghostBytesPerRow = bytesPerPixel * ghostSize.width;
    UInt32 * ghostPixels = (UInt32 *)calloc(ghostSize.width * ghostSize.height, sizeof(UInt32));
    
    CGContextRef ghostContext = CGBitmapContextCreate(ghostPixels, ghostSize.width, ghostSize.height,
                                                      bitsPerComponent, ghostBytesPerRow, colorSpace,
                                                      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ghostContext, CGRectMake(0, 0, ghostSize.width, ghostSize.height),ghostCGImage);
    
    NSUInteger offsetPixelCountForInput = ghostOrigin.y * inputWidth + ghostOrigin.x;
    for (NSUInteger j = 0; j < ghostSize.height; j++) {
        for (NSUInteger i = 0; i < ghostSize.width; i++) {
            UInt32 * inputPixel = inputPixels + j * inputWidth + i + offsetPixelCountForInput;
            UInt32 inputColor = *inputPixel;

            UInt32 * ghostPixel = ghostPixels + j * (int)ghostSize.width + i;
            UInt32 ghostColor = *ghostPixel;

            // Blend the ghost with 50% alpha
            CGFloat ghostAlpha = 0.5f * (A(ghostColor) / 255.0);
            UInt32 newR = R(inputColor) * (1 - ghostAlpha) + R(ghostColor) * ghostAlpha;
            UInt32 newG = G(inputColor) * (1 - ghostAlpha) + G(ghostColor) * ghostAlpha;
            UInt32 newB = B(inputColor) * (1 - ghostAlpha) + B(ghostColor) * ghostAlpha;

            // Clamp, not really useful here :p
            newR = MAX(0,MIN(255, newB));
            newG = MAX(0,MIN(255, newG));
            newB = MAX(0,MIN(255, newR));

            *inputPixel = RGBAMake(newR, newG, newB, A(inputColor));
        }
    }
    
    
//    // Convert the image to black and white
//    for (NSUInteger j = 0; j < inputHeight; j++) {
//        for (NSUInteger i = 0; i < inputWidth; i++) {
//            UInt32 * currentPixel = inputPixels + (j * inputWidth) + i;
//            UInt32 color = *currentPixel;
//
//            // Average of RGB = greyscale
//            UInt32 averageColor = (R(color) + G(color) + B(color)) / 3.0;
//
//            *currentPixel = RGBAMake(averageColor, averageColor, averageColor, A(color));
//        }
//    }
    
    // Create a new UIImage
    CGImageRef newCGImage = CGBitmapContextCreateImage(context);
    UIImage * processedImage = [UIImage imageWithCGImage:newCGImage];
    // Cleanup!
    CGColorSpaceRelease(colorSpace);
    CGContextRelease(context);
    CGContextRelease(ghostContext);
    free(inputPixels);
    free(ghostPixels);
    
    return processedImage;
}

- (UIImage*)convertToBlackAndWhiteNoGrayScale:(UIImage*)inputImage {
    CIImage *ciImage = [[CIImage alloc]initWithImage:inputImage];
    
    CIFilter *grayFilter = [CIFilter filterWithName:@"CIMaximumComponent"
                                withInputParameters:@{kCIInputImageKey: ciImage}];
    CIImage *outputImage = grayFilter.outputImage;
    
    CIFilter *blackAndWhiteFilter = [CIFilter filterWithName:@"CIColorControls"
                                   withInputParameters:@{kCIInputImageKey: outputImage,
                                                         kCIInputContrastKey: @62.0,
                                                         kCIInputBrightnessKey: @30.0,
                                                         kCIInputSaturationKey: @0}];
    CIImage *output = blackAndWhiteFilter.outputImage;
    
    
    //CIImage *blackAndWhite = [CIFilter filterWithName:@"CIColorControls" keysAndValues:kCIInputImageKey, ciImage, @"inputBrightness", [NSNumber numberWithFloat:0.0], @"inputContrast", [NSNumber numberWithFloat:1.1], @"inputSaturation", [NSNumber numberWithFloat:0.0], nil].outputImage;
    //CIImage *output = [CIFilter filterWithName:@"CIExposureAdjust" keysAndValues:kCIInputImageKey, blackAndWhite, @"inputEV", [NSNumber numberWithFloat:0.7], nil].outputImage;
    
    
    CGImageRef imageRef = [[CIContext contextWithOptions:nil] createCGImage:output
                                                                   fromRect:output.extent];
    return [UIImage imageWithCGImage:imageRef];
}

- (UIImage*)processImageUsingOpenCV:(UIImage*)inputImage {
    UIImage *result;
    
    if (inputImage.size.width > 500) {
        float aspectRatio = inputImage.size.height/float(inputImage.size.width);
        inputImage = [self scaleImage:inputImage toSize:CGSizeMake(500, 500*(aspectRatio))];
    }
    
    _strDigits = [NSMutableString stringWithFormat:@""];
    
    // Convert the image from UIImage to Mat
    //Mat imageCV = [self correctPerspectiveTransform:inputImage];
    Mat imageCV; UIImageToMat(inputImage, imageCV);
    
    // OpenCV operations:
    // Convert the image from RGB to GrayScale
    Mat gray; cvtColor(imageCV, gray, CV_RGBA2GRAY);
    // Apply the gaussian blur to the above image
    
    Mat gaussianBlur; GaussianBlur(gray, gaussianBlur, cv::Size(5,5), 0);
    // Apply the Canny edge detection
    Mat edges; Canny(gaussianBlur, edges, 50, 200, 3);
    result = MatToUIImage(edges);

    // Display the result
    //return MatToUIImage(edges);
    
    // Find rectangle
    std::vector<std::vector<cv::Point> > contours;
    findContours(edges.clone(), contours, CV_RETR_EXTERNAL, CV_CHAIN_APPROX_SIMPLE);
    
    std::vector<cv::Point> approx;
    std::vector<cv::Point> ledContour;
    cv::Rect cropRect;
    
    for(size_t i = 0; i < contours.size(); i++ )
    {
        cv::approxPolyDP(Mat(contours[i]), approx, arcLength(Mat(contours[i]), true)*0.02, true);
        cropRect = boundingRect(contours[i]);
        
        if(approx.size() == 4 && cropRect.width > 50)
        {
            cv::Mat croppedImage = cv::Mat(gray, cropRect).clone();
            result = MatToUIImage(croppedImage);
            
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *documentsPath = [paths objectAtIndex:0]; //Get the docs directory
            NSString *filePath = [documentsPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Image_%zu.png",i]];
            
            NSError *error = nil;
            if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
            {
                [[NSFileManager defaultManager] removeItemAtPath:filePath error:&error];
            }
            
            if(result) // nsdata of image that u have
            {
                [UIImagePNGRepresentation(result) writeToFile:filePath atomically:YES];
            }

            NSLog(@"rectangle shape detected.");
            if ((cropRect.width/inputImage.size.width > 0.55) &&
                ((cropRect.height/inputImage.size.height > 0.10))) {
                NSLog(@"possible LED shape detected.");
                ledContour = approx;
                break;
            }
//            if ((cropRect.width > (0.3*inputImage.size.width)) &&
//                ((0.15*inputImage.size.height) < cropRect.height) &&
//                (cropRect.height < (0.5*inputImage.size.height))) {
//                NSLog(@"possible LED shape detected.");
//                ledContour = approx;
//                break;
//            }
        }
    }
    
    if (ledContour.size() == 0) {
        // Not found
        return nil;
    }
    
    cv::Mat croppedImage = cv::Mat(gray, cropRect).clone();
    result = MatToUIImage(croppedImage);

    // Pending transform
    //double contourArea = fabs(cv::contourArea(cv::Mat(ledContour)) );
    //double boundingRectArea = fabs(cropRect.width * cropRect.height);
    //double errorRatio = (contourArea/boundingRectArea);
    
    /*
    if ((0.6 < errorRatio) && (errorRatio < 1)) {
        // Unskew image
        cv::Point2f src_p[4];
        cv::Point2f dst_p[4];
        
        // from points
        src_p[0] = ledContour[0] - cv::Point(cropRect.x, cropRect.y);
        src_p[1] = ledContour[1] - cv::Point(cropRect.x, cropRect.y);
        src_p[2] = ledContour[2] - cv::Point(cropRect.x, cropRect.y);
        src_p[3] = ledContour[3] - cv::Point(cropRect.x, cropRect.y);
        
        
        // to points
        dst_p[0] = cv::Point2f(0.0f, 0.0f);
        dst_p[1] = cv::Point2f(0.0f, cropRect.height);
        dst_p[2] = cv::Point2f(cropRect.width, cropRect.height);
        dst_p[3] = cv::Point2f(cropRect.width, 0.0f);
        
        //    dst_p[0] = cv::Point2f(0.0f, 0.0f);
        //    dst_p[1] = cv::Point2f(0.0f, cropRect.y - cropRect.size().height);
        //    dst_p[2] = cv::Point2f(cropRect.size().width - cropRect.x, cropRect.y - cropRect.size().height);
        //    dst_p[3] = cv::Point2f(cropRect.size().width - cropRect.x, 0.0f);
        
        
        //    cv::Mat quad = cv::Mat::zeros(300, 220, CV_8UC3);
        //    std::vector<cv::Point2f> dst_pts;
        //    dst_pts.push_back(cv::Point2f(0, 0));
        //    dst_pts.push_back(cv::Point2f(quad.cols, 0));
        //    dst_pts.push_back(cv::Point2f(quad.cols, quad.rows));
        //    dst_pts.push_back(cv::Point2f(0, quad.rows));
        
        cv::Mat transmtx = cv::getPerspectiveTransform(src_p, dst_p);
        cv::warpPerspective(croppedImage, croppedImage, transmtx, croppedImage.size());
    }
    */

    result = MatToUIImage(croppedImage);
    printf("Testing");

    /*
    //cv::Size *dSize = new cv::Size(gray.rows, gray.cols);
    std::vector<cv::Point> target_points
    {
        {0, 0},
        {edges.cols - 1, 0},
        {edges.cols - 1, edges.rows - 1},
        {0, edges.rows - 1}
    };
    
    std::vector<cv::Point> points;

    for(auto const &point : ledContour){
        points.emplace_back(point.x, point.y);
    }

//    cv::Mat const trans_mat = cv::getPerspectiveTransform(points,
//                                                          target_points);
//    cv::warpPerspective(ledContour, edges, trans_mat, edges.size());

    
    Mat srcTri = Mat(4, 1, CV_32FC2, target_points.size());
    Mat dstTri = Mat(4, 1, CV_32FC2, points.size());
//
//    // Extract image with LED contour
    Mat warped = cv::getPerspectiveTransform(srcTri, dstTri);
    Mat output; cv::warpPerspective(edges, output, warped, cropRect.size());
    */
    
//    Mat srcTri = Mat(4, 2, CV_32F, &croppedImage);
//    Mat dstTri = Mat(4, 2, CV_32F, &croppedImage);
//
//        // Extract image with LED contour
//    Mat warped = cv::getPerspectiveTransform(srcTri, dstTri);
//    cv::warpPerspective(edges, croppedImage, warped, cropRect.size());
    
    //croppedImage = [self unSkewImage:croppedImage cropRect:ledContour];
    //result = MatToUIImage(croppedImage);
    
    // Image reprocessing in case not filtered properly
    /*
    std::vector<Vec4i> subHierarchy;
    cv::findContours(croppedImage.clone(), contours, subHierarchy, RETR_TREE, CV_CHAIN_APPROX_SIMPLE);

    for(size_t i = 0; i < contours.size(); i++ )
    {
        cv::Rect digitCropRect = boundingRect(contours[i]);
        cv::approxPolyDP(Mat(contours[i]), approx, arcLength(Mat(contours[i]), true)*0.02, true);
        
        if (approx.size() == 6 &&
            digitCropRect.width > cropRect.width/2.0 &&
            digitCropRect.height > cropRect.height/2.0 &&
            subHierarchy[i][0] == 0) {
            croppedImage = cv::Mat(croppedImage, digitCropRect).clone();
            result = MatToUIImage(croppedImage);
            printf("Testing");
            cropRect = digitCropRect;
            ledContour = approx;
            break;
        }
    }
    */
    
    // TODO: Support regular digits
    /*
    _tesseract.image = [result g8_blackAndWhite];
    [_tesseract recognize];
    // Retrieve the recognized text
    NSLog(@"%@", [_tesseract recognizedText]);
    */

     /*
    // TODO: Perspective correction for the image
    vector<vector<cv::Point> > contours_poly(1);
    cv::approxPolyDP(Mat(ledContour), contours_poly[0], 5, true);
    cv::Rect boundRect=boundingRect(ledContour);
    
    if(contours_poly[0].size()==4){
        std::vector<Point2f> quad_pts;
        std::vector<Point2f> squre_pts;
        quad_pts.push_back(Point2f(contours_poly[0][0].x,contours_poly[0][0].y));
        quad_pts.push_back(Point2f(contours_poly[0][1].x,contours_poly[0][1].y));
        quad_pts.push_back(Point2f(contours_poly[0][3].x,contours_poly[0][3].y));
        quad_pts.push_back(Point2f(contours_poly[0][2].x,contours_poly[0][2].y));
        squre_pts.push_back(Point2f(boundRect.x,boundRect.y));
        squre_pts.push_back(Point2f(boundRect.x,boundRect.y+boundRect.height));
        squre_pts.push_back(Point2f(boundRect.x+boundRect.width,boundRect.y));
        squre_pts.push_back(Point2f(boundRect.x+boundRect.width,boundRect.y+boundRect.height));
        
        Mat transmtx = getPerspectiveTransform(quad_pts,squre_pts);
        Mat transformed = Mat::zeros(croppedImage.rows, croppedImage.cols, CV_8UC3);
        warpPerspective(croppedImage, transformed, transmtx, croppedImage.size());
    }
    
    result = MatToUIImage(croppedImage);
    printf("Testing");
    */

    /*
    UIImage *output = MatToUIImage(gray);
    CGFloat offset = 10;
    CGImageRef cutImageRef = CGImageCreateWithImageInRect(output.CGImage, CGRectMake((cropRect.x + offset), (cropRect.y + offset), (cropRect.width - 2*offset), (cropRect.height - 2*offset)));
    UIImage* croppedImage = [UIImage imageWithCGImage:cutImageRef];
    CGImageRelease(cutImageRef);
    //return croppedImage;
    */
 
    //  TODO: Perspective correction for the image
//    CGFloat offset = 10;
//    CGRect rectObjC = CGRectMake((cropRect.x + offset), (cropRect.y + offset), (cropRect.width - 2*offset), (cropRect.height - 2*offset));
//
//    cv::Mat croppedImage = gray(boundingRect(ledContour));
//    //cv::Mat undistorted = cv::Mat( cvSize(rectObjC.size.width,rectObjC.size.height), CV_8UC1);
//    //cv::warpPerspective(imageCV, undistorted, cv::getPerspectiveTransform(gray, croppedImage), cvSize(rectObjC.size.width,rectObjC.size.height));
//
//    UIImage *newImage = [self UIImageFromCVMat:croppedImage];
//    //undistorted.release();
//    return newImage;
    
    // operations to cleanup the thresholded image
    Mat threshArr; cv::threshold(croppedImage, threshArr, 0, 255, CV_THRESH_BINARY_INV | CV_THRESH_OTSU);
    Mat kernel; cv::getStructuringElement(CV_SHAPE_ELLIPSE, cv::Size(1,5));
    Mat thresh; cv::morphologyEx(threshArr, thresh, CV_MOP_DILATE, kernel);
    
    // Re-process image
//    cv::threshold(thresh, threshArr, 0, 255, CV_THRESH_OTSU);
//    cv::getStructuringElement(CV_SHAPE_ELLIPSE, cv::Size(1,5));
//    cv::morphologyEx(threshArr, thresh, CV_MOP_OPEN, kernel);

    if (thresh.data == NULL) {
        return result;
    }
    
    result = MatToUIImage(thresh);
    printf("Testing");
    
    std::vector<Vec4i> hierarchy;
    
    cv::findContours(thresh.clone(), contours, hierarchy, RETR_CCOMP, CV_CHAIN_APPROX_NONE);
    std::vector<std::vector<cv::Point>> digitCnts;
    
    for(size_t i = 0; i < contours.size(); i++ )
    {
        cv::Rect digitCropRect = boundingRect(contours[i]);
        if (digitCropRect.width > cropRect.width/2.0) {
            // Ignore same rect
            continue;
        }
        cv::Mat croppedImage = cv::Mat(thresh, digitCropRect).clone();
        result = MatToUIImage(croppedImage);
        printf("Testing");
        
        if (digitCropRect.height/double(cropRect.height) > 0.30 && hierarchy[i][3] == -1) {
            NSLog(@"Testing time");
        }
        // Save to disk for testing.
        /*
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths objectAtIndex:0]; //Get the docs directory
        NSString *filePath = [documentsPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Image_%zu.png",i]];
        
        NSError *error = nil;
        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
        {
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:&error];
        }
                                
        if(result) // nsdata of image that u have
        {
            [UIImagePNGRepresentation(result) writeToFile:filePath atomically:YES];
        }
        */
        
        // Filter out contour if exists inside another contour before adding to digitCnts.
        // (hierarchy[i][3] == -1) means have no parent contour.
        if(digitCropRect.width/double(cropRect.width) > 0.030 && digitCropRect.height/double(cropRect.height) > 0.30 && hierarchy[i][3] == -1) {
        //if(digitCropRect.width >= 15 && digitCropRect.height >= 30 && hierarchy[i][3] == -1) {
            digitCnts.push_back(contours[i]);
        }
    }
    
    
    // sort digit contours left to right
    std::sort(digitCnts.begin(), digitCnts.end(), contourComparator);
    
    std::map <std::tuple<int, int, int, int, int, int, int>, int> DIGITS_LOOKUP;
    DIGITS_LOOKUP[std::make_tuple(1, 1, 1, 0, 1, 1, 1)] = 0;
    DIGITS_LOOKUP[std::make_tuple(0, 0, 1, 0, 0, 1, 0)] = 1;
    DIGITS_LOOKUP[std::make_tuple(1, 0, 1, 1, 1, 0, 1)] = 2;
    DIGITS_LOOKUP[std::make_tuple(1, 0, 1, 1, 0, 1, 1)] = 3;
    DIGITS_LOOKUP[std::make_tuple(0, 1, 1, 1, 0, 1, 0)] = 4;
    DIGITS_LOOKUP[std::make_tuple(1, 1, 0, 1, 0, 1, 1)] = 5;
    DIGITS_LOOKUP[std::make_tuple(1, 1, 0, 1, 1, 1, 1)] = 6;
    DIGITS_LOOKUP[std::make_tuple(1, 0, 1, 0, 0, 1, 0)] = 7;
    DIGITS_LOOKUP[std::make_tuple(1, 1, 1, 1, 1, 1, 1)] = 8;
    DIGITS_LOOKUP[std::make_tuple(1, 1, 1, 1, 0, 1, 1)] = 9;
    
    for(size_t i = 0; i < digitCnts.size(); i++ )
    {
        cv::Rect cropRect = boundingRect(digitCnts[i]);
        if ((cropRect.width/float(cropRect.height)) < 0.40) {
            // Caveat for value 1
            cropRect.x = cropRect.x - cropRect.height/2.8;
            cropRect.width = cropRect.height/2;
        }

        cv::Mat roi = cv::Mat(thresh, cropRect).clone();
        result = MatToUIImage(roi);
        printf("Testing");
        
        int roiW = cropRect.width;
        int roiH = cropRect.height;
        
        int dW = int(roiW * 0.30);
        int dH = int(roiH * 0.15);
        int dHC = int(roiH * 0.05);
        
        cv::Point top1(0, 0);
        cv::Point top2(cropRect.width, dH);
        
        cv::Point topLeft1(0, 0);
        cv::Point topLeft2(dW, cropRect.height/2);

        cv::Point topRight1(cropRect.width - dW, 0);
        cv::Point topRight2(cropRect.width, cropRect.height/2);
        
        cv::Point center1(0, (cropRect.height/2) - dHC);
        cv::Point center2(cropRect.width, (cropRect.height/2) + dHC);

        cv::Point bottomLeft1(0, cropRect.height/2);
        cv::Point bottomLeft2(dW, cropRect.height);

        cv::Point bottomRight1(cropRect.width - dW, cropRect.height/2);
        cv::Point bottomRight2(cropRect.width, cropRect.height);
        
        cv::Point bottom1(0, cropRect.height - dH);
        cv::Point bottom2(cropRect.width, cropRect.height);


        // Define Seven segment
        vector<cv::Point> segments;
        segments.push_back(top1);
        segments.push_back(top2);
        segments.push_back(topLeft1);
        segments.push_back(topLeft2);
        segments.push_back(topRight1);
        segments.push_back(topRight2);
        segments.push_back(center1);
        segments.push_back(center2);
        segments.push_back(bottomLeft1);
        segments.push_back(bottomLeft2);
        segments.push_back(bottomRight1);
        segments.push_back(bottomRight2);
        segments.push_back(bottom1);
        segments.push_back(bottom2);

        std::tuple<int, int, int, int, int, int, int> onTuple = std::make_tuple(0, 0, 0, 0, 0, 0, 0);
        int onCounter = 0;
        
        for(size_t i = 0; i < segments.size(); i++ )
        {
            cv::Point topLeft = segments[i];
            i++;
            cv::Point bottomRight = segments[i];
            cv::Rect cropRect(topLeft, bottomRight);
            cv::Mat segROI = cv::Mat(roi, cropRect).clone();
            result = MatToUIImage(segROI);
            
            int total = cv::countNonZero(segROI);
            int area = cropRect.width * cropRect.height;
            
            if (total/float(area) > 0.4) {
                switch (onCounter) {
                    case 0:
                        std::get<0>(onTuple) = 1;
                        break;
                    case 1:
                        std::get<1>(onTuple) = 1;
                        break;
                    case 2:
                        std::get<2>(onTuple) = 1;
                        break;
                    case 3:
                        std::get<3>(onTuple) = 1;
                        break;
                    case 4:
                        std::get<4>(onTuple) = 1;
                        break;
                    case 5:
                        std::get<5>(onTuple) = 1;
                        break;
                    case 6:
                        std::get<6>(onTuple) = 1;
                        break;
                    default:
                        break;
                }
            }
            onCounter++;
        }

        int digit = DIGITS_LOOKUP[onTuple];
        printf("Digits %d", digit);
        [_strDigits appendString:@(digit).stringValue];
    }
    
    result = MatToUIImage(thresh);
    return inputImage;
}

bool contourComparator(const vector<cv::Point>& pt1, const vector<cv::Point> & pt2) {
    cv::Rect ra(boundingRect(pt1));
    cv::Rect rb(boundingRect(pt2));
    return (ra.x < rb.x);
}

#pragma mark - Helper methods

- (Mat)warpImage:(Mat)src {
    Point2f srcTri[3];
    Point2f dstTri[3];
    
    Mat rot_mat( 2, 3, CV_32FC1 );
    Mat warp_mat( 2, 3, CV_32FC1 );
    Mat warp_dst, warp_rotate_dst;
    
    /// Set the dst image the same type and size as src
    warp_dst = Mat::zeros( src.rows, src.cols, src.type() );
    
    /// Set your 3 points to calculate the  Affine Transform
    srcTri[0] = Point2f( 0,0 );
    srcTri[1] = Point2f( src.cols - 1, 0 );
    srcTri[2] = Point2f( 0, src.rows - 1 );
    
    dstTri[0] = Point2f( src.cols*0.0, src.rows*0.33 );
    dstTri[1] = Point2f( src.cols*0.85, src.rows*0.25 );
    dstTri[2] = Point2f( src.cols*0.15, src.rows*0.7 );
    
    /// Get the Affine Transform
    warp_mat = getAffineTransform( srcTri, dstTri );
    
    /// Apply the Affine Transform just found to the src image
    warpAffine( src, warp_dst, warp_mat, warp_dst.size() );
    
    /** Rotating the image after Warp */
    
    /// Compute a rotation matrix with respect to the center of the image
    cv::Point center = cv::Point( warp_dst.cols/2, warp_dst.rows/2 );
    double angle = -50.0;
    double scale = 0.6;
    
    /// Get the rotation matrix with the specifications above
    rot_mat = getRotationMatrix2D( center, angle, scale );
    
    /// Rotate the warped image
    warpAffine( warp_dst, warp_rotate_dst, rot_mat, warp_dst.size() );
    
    return warp_dst;
}

- (Mat)unSkewImage:(Mat)src cropRect:(vector<cv::Point>)not_a_rect_shape {
    const cv::Point *point = &not_a_rect_shape[0];
    int n = (int)not_a_rect_shape.size();
    Mat draw = src.clone();
    polylines(draw, &point, &n, 1, true, Scalar(0, 255, 0), 3, CV_AA);
    imwrite("draw.jpg", draw);
    
    // Assemble a rotated rectangle out of that info
    RotatedRect box = minAreaRect(cv::Mat(not_a_rect_shape));
    std::cout << "Rotated box set to (" << box.boundingRect().x << "," << box.boundingRect().y << ") " << box.size.width << "x" << box.size.height << std::endl;
    
    Point2f pts[4];
    
    box.points(pts);
    
    // Does the order of the points matter? I assume they do NOT.
    // But if it does, is there an easy way to identify and order
    // them as topLeft, topRight, bottomRight, bottomLeft?
    
    cv::Point2f src_vertices[3];
    src_vertices[0] = pts[0];
    src_vertices[1] = pts[1];
    src_vertices[2] = pts[3];
    //src_vertices[3] = not_a_rect_shape[3];
    
    Point2f dst_vertices[3];
    dst_vertices[0] = cv::Point(0, 0);
    dst_vertices[1] = cv::Point(box.boundingRect().width-1, 0);
    dst_vertices[2] = cv::Point(0, box.boundingRect().height-1);
    
    /* Mat warpMatrix = getPerspectiveTransform(src_vertices, dst_vertices);
     
     cv::Mat rotated;
     cv::Size size(box.boundingRect().width, box.boundingRect().height);
     warpPerspective(src, rotated, warpMatrix, size, INTER_LINEAR, BORDER_CONSTANT);*/
    Mat warpAffineMatrix = getAffineTransform(src_vertices, dst_vertices);
    
    cv::Mat rotated;
    cv::Size size(box.boundingRect().width, box.boundingRect().height);
    warpAffine(src, rotated, warpAffineMatrix, size, INTER_LINEAR, BORDER_CONSTANT);
    
    return rotated;
}

cv::Point2f center(0,0);

cv::Point2f computeIntersect(cv::Vec4i a, cv::Vec4i b)
{
    int x1 = a[0], y1 = a[1], x2 = a[2], y2 = a[3], x3 = b[0], y3 = b[1], x4 = b[2], y4 = b[3];
    
    if (float d = ((float)(x1 - x2) * (y3 - y4)) - ((y1 - y2) * (x3 - x4)))
    {
        cv::Point2f pt;
        pt.x = ((x1 * y2 - y1 * x2) * (x3 - x4) - (x1 - x2) * (x3 * y4 - y3 * x4)) / d;
        pt.y = ((x1 * y2 - y1 * x2) * (y3 - y4) - (y1 - y2) * (x3 * y4 - y3 * x4)) / d;
        return pt;
    }
    else
        return cv::Point2f(-1, -1);
}

void sortCorners(std::vector<cv::Point2f>& corners,
                 cv::Point2f center)
{
    std::vector<cv::Point2f> top, bot;
    
    for (int i = 0; i < corners.size(); i++)
    {
        if (corners[i].y < center.y)
            top.push_back(corners[i]);
        else
            bot.push_back(corners[i]);
    }
    corners.clear();
    
    if (top.size() == 2 && bot.size() == 2){
        cv::Point2f tl = top[0].x > top[1].x ? top[1] : top[0];
        cv::Point2f tr = top[0].x > top[1].x ? top[0] : top[1];
        cv::Point2f bl = bot[0].x > bot[1].x ? bot[1] : bot[0];
        cv::Point2f br = bot[0].x > bot[1].x ? bot[0] : bot[1];
        
        
        corners.push_back(tl);
        corners.push_back(tr);
        corners.push_back(br);
        corners.push_back(bl);
    }
}

- (Mat)correctPerspectiveTransform:(Mat)input {
    Mat src = input;
    
    std::vector<cv::Vec4i> lines;
    cv::HoughLinesP(src, lines, 1, CV_PI/180, 70, 30, 10);
    
    // Expand the lines
    for (int i = 0; i < lines.size(); i++)
    {
        cv::Vec4i v = lines[i];
        lines[i][0] = 0;
        lines[i][1] = ((float)v[1] - v[3]) / (v[0] - v[2]) * -v[0] + v[1];
        lines[i][2] = src.cols;
        lines[i][3] = ((float)v[1] - v[3]) / (v[0] - v[2]) * (src.cols - v[2]) + v[3];
    }
    
    std::vector<cv::Point2f> corners;
    for (int i = 0; i < lines.size(); i++)
    {
        for (int j = i+1; j < lines.size(); j++)
        {
            cv::Point2f pt = computeIntersect(lines[i], lines[j]);
            if (pt.x >= 0 && pt.y >= 0)
                corners.push_back(pt);
        }
    }
    
    std::vector<cv::Point2f> approx;
    cv::approxPolyDP(cv::Mat(corners), approx, cv::arcLength(cv::Mat(corners), true) * 0.02, true);
    
    if (approx.size() != 4)
    {
        std::cout << "The object is not quadrilateral!" << std::endl;
    }
    
    // Get mass center
    for (int i = 0; i < corners.size(); i++)
        center += corners[i];
    center *= (1. / corners.size());
    
    sortCorners(corners, center);
    if (corners.size() == 0){
        std::cout << "The corners were not sorted correctly!" << std::endl;
    }
    cv::Mat dst = src.clone();
    
    // Draw lines
    for (int i = 0; i < lines.size(); i++)
    {
        cv::Vec4i v = lines[i];
        cv::line(dst, cv::Point(v[0], v[1]), cv::Point(v[2], v[3]), CV_RGB(0,255,0));
    }
    
    // Draw corner points
    cv::circle(dst, corners[0], 3, CV_RGB(255,0,0), 2);
    cv::circle(dst, corners[1], 3, CV_RGB(0,255,0), 2);
    cv::circle(dst, corners[2], 3, CV_RGB(0,0,255), 2);
    cv::circle(dst, corners[3], 3, CV_RGB(255,255,255), 2);
    
    // Draw mass center
    cv::circle(dst, center, 3, CV_RGB(255,255,0), 2);
    
    cv::Mat quad = cv::Mat::zeros(300, 220, CV_8UC3);
    
    std::vector<cv::Point2f> quad_pts;
    quad_pts.push_back(cv::Point2f(0, 0));
    quad_pts.push_back(cv::Point2f(quad.cols, 0));
    quad_pts.push_back(cv::Point2f(quad.cols, quad.rows));
    quad_pts.push_back(cv::Point2f(0, quad.rows));
    
    cv::Mat transmtx = cv::getPerspectiveTransform(corners, quad_pts);
    cv::warpPerspective(src, quad, transmtx, quad.size());
    
    return quad;
}

- (UIImage *)scaleImage:(UIImage*)input toSize:(CGSize)newSize {
    
    CGRect scaledImageRect = CGRectZero;
    
    CGFloat aspectWidth = newSize.width / input.size.width;
    CGFloat aspectHeight = newSize.height / input.size.height;
    CGFloat aspectRatio = MIN ( aspectWidth, aspectHeight );
    
    scaledImageRect.size.width = input.size.width * aspectRatio;
    scaledImageRect.size.height = input.size.height * aspectRatio;
    scaledImageRect.origin.x = (newSize.width - scaledImageRect.size.width) / 2.0f;
    scaledImageRect.origin.y = (newSize.height - scaledImageRect.size.height) / 2.0f;
    
    UIGraphicsBeginImageContextWithOptions( newSize, NO, 0 );
    [input drawInRect:scaledImageRect];
    UIImage* scaledImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return scaledImage;
}

@end

