//
//  LiveImageProcessor.h
//  SpookCam
//
//  Created by Ayush Chamoli on 10/8/18.
//

#import <Foundation/Foundation.h>

@class GLKView;

@interface LiveImageProcessor : NSObject

-(instancetype)initWithContext:(EAGLContext*)eaglContext inView:(GLKView*)view;

-(UIImage*)captureImageAndStop:(BOOL)stop;
- (void)resumeImageProcessing;

@end
