//
//  ImagePreProcessor.swift
//  SpookCam
//
//  Created by Ayush Chamoli on 6/19/18.
//

import UIKit
import Foundation

class ImagePreProcessor: NSObject {
    
    class func scaleImage(inputImage: UIImage, with size: CGSize) -> UIImage? {
        var scaledImage: UIImage?
        
        guard let data = UIImagePNGRepresentation(inputImage) else {
            return nil
        }

        let imageData = NSData(data: data)
        let bytes = imageData.bytes.assumingMemoryBound(to: UInt8.self)
        
        guard let dataPtr = CFDataCreate(kCFAllocatorDefault, bytes, imageData.length) else {
            return nil
        }

        if let imageSource = CGImageSourceCreateWithData(dataPtr, nil) {
            let options = [kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) / 2.0 , kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary
            scaledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options).flatMap { UIImage(cgImage: $0) }
        }
        
        return scaledImage
    }
    
    class func convertImageToGrayScale(inputImage: UIImage) -> UIImage {
        let context = CIContext(options: nil)
        let currentFilter = CIFilter(name: "CIPhotoEffectNoir")
        currentFilter!.setValue(CIImage(image: inputImage), forKey: kCIInputImageKey)
        let output = currentFilter!.outputImage
        let cgimg = context.createCGImage(output!,from: output!.extent)
        let processedImage = UIImage(cgImage: cgimg!)
        return processedImage
    }
    
    class func applyBlurEffect(inputImage: UIImage) -> UIImage {
        let blurRadius = 5
        let imageToBlur = CIImage(image: inputImage)
        
        // Added "CIAffineClamp" filter
        let affineClampFilter = CIFilter(name: "CIAffineClamp")!
        affineClampFilter.setDefaults()
        affineClampFilter.setValue(imageToBlur, forKey: kCIInputImageKey)
        let resultClamp = affineClampFilter.value(forKey: kCIOutputImageKey)
        
        // resultClamp is used as input for "CIGaussianBlur" filter
        let blurfilter: CIFilter = CIFilter(name:"CIGaussianBlur")!
        blurfilter.setDefaults()
        blurfilter.setValue(imageToBlur, forKey: kCIInputImageKey)
        blurfilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        
        let resultImage = blurfilter.value(forKey: kCIOutputImageKey) as! CIImage
        let imageRef = CIContext(options: nil).createCGImage(resultImage, from: resultImage.extent)
        let blurredImage = UIImage(cgImage: imageRef!)
        return blurredImage
    }
    
    class func detectRectangleAndCrop(inImage inputImage: UIImage, processImage outputImage: UIImage) -> CIImage? {
        let detector = CIDetector(
            ofType: CIDetectorTypeRectangle,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh, CIDetectorAspectRatio: 1.667, CIDetectorMaxFeatureCount: 5]
        )
        //, CIDetectorAspectRatio: 1.667, CIDetectorMaxFeatureCount: 5
        let coreImage = CIImage(cgImage: inputImage.cgImage!)
        var coreImageOutput = CIImage(cgImage: outputImage.cgImage!)

        if let rectangles = detector?.features(in: coreImage) as? [CIRectangleFeature] {
            guard let rect = self.biggestRectangle(inRectangles: rectangles, inImage: outputImage) else {
                return nil
            }
            print(rect.bounds)
        
            //coreImage = self.cropImageForfeatureRectangle(image: coreImage, rect: rect)
            //coreImage = coreImage.cropping(to: CGRect(x: rect.bounds.origin.x, y: abs(rect.bounds.origin.y - rect.bounds.size.height/2.0),width: rect.bounds.size.width, height: rect.bounds.size.height))
            coreImageOutput = coreImageOutput.cropping(to: rect.bounds)
            //let outputImage = self.unskewImage(inImage: UIImage(ciImage: coreImage), withRectfeature: rect)
            return coreImageOutput
        }
        
        return nil
    }
    
    class func cropImageForfeatureRectangle(image: CIImage, rect: CIRectangleFeature) -> CIImage {
        
        var processImage: CIImage
        processImage = image.applyingFilter(
            "CIPerspectiveTransformWithExtent",
            withInputParameters: [
                "inputExtent": CIVector(cgRect: image.extent),
                "inputTopLeft": CIVector(cgPoint: rect.topLeft),
                "inputTopRight": CIVector(cgPoint: rect.topRight),
                "inputBottomLeft": CIVector(cgPoint: rect.bottomLeft),
                "inputBottomRight": CIVector(cgPoint: rect.bottomRight)])
        processImage = image.cropping(to: processImage.extent)
        
        return processImage
    }

    class func unskewImage(inImage inputImage: UIImage, withRectfeature rect: CIRectangleFeature) -> UIImage {
        // Perspective transform
        let perspectiveTransform = CIFilter(name: "CIPerspectiveTransform")!
        perspectiveTransform.setValue(CIVector(cgPoint:rect.topLeft),
                                      forKey: "inputTopLeft")
        perspectiveTransform.setValue(CIVector(cgPoint:rect.topRight),
                                      forKey: "inputTopRight")
        perspectiveTransform.setValue(CIVector(cgPoint:rect.bottomRight),
                                      forKey: "inputBottomRight")
        perspectiveTransform.setValue(CIVector(cgPoint:rect.bottomLeft),
                                      forKey: "inputBottomLeft")
        perspectiveTransform.setValue(inputImage,
                                      forKey: kCIInputImageKey)
        
        // Perspective correction
        let perspectiveCorrection = CIFilter(name: "CIPerspectiveCorrection")!
        
        perspectiveCorrection.setValue(CIVector(cgPoint:rect.topLeft),
                                       forKey: "inputTopLeft")
        perspectiveCorrection.setValue(CIVector(cgPoint:rect.topRight),
                                       forKey: "inputTopRight")
        perspectiveCorrection.setValue(CIVector(cgPoint:rect.bottomRight),
                                       forKey: "inputBottomRight")
        perspectiveCorrection.setValue(CIVector(cgPoint:rect.bottomLeft),
                                       forKey: "inputBottomLeft")
        perspectiveCorrection.setValue(inputImage,
                                       forKey: kCIInputImageKey)
        
        return inputImage
    }
    
    class func biggestRectangle(inRectangles rectangles: [CIRectangleFeature], inImage inputImage: UIImage) -> CIRectangleFeature? {
        if rectangles.count == 0 {
            return nil
        }
        var halfPerimiterValue: Float = 0
        var biggestRectangle = rectangles.first
        for rect: CIRectangleFeature in rectangles {
            let p1 = rect.topLeft
            let p2 = rect.topRight
            let width = CGFloat(hypotf((Float(p2.x - p1.x)), (Float(p2.y - p1.y))))
            
            let p3 = rect.topLeft
            let p4 = rect.bottomLeft
            let height = CGFloat(hypotf((Float(p4.x - p3.x)), (Float(p4.y - p3.y))))
            
            let currentHalfPerimiterValue = width + height
            
            if (CGFloat(halfPerimiterValue) < currentHalfPerimiterValue) && (height < width/2) {
                halfPerimiterValue = Float(currentHalfPerimiterValue)
                biggestRectangle = rect
                print("height    \(height)")
                print("width    \(width)")
            }
        }
        return biggestRectangle
    }

}

