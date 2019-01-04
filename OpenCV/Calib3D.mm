//
//  Calib3DWrapper.m
//  Metal Camera
//
//  Created by Trustee Luangdilokrut on 1/4/19.
//  Copyright © 2019 Old Yellow Bricks. All rights reserved.
//

#import <opencv2/opencv.hpp>
#import "Calib3D.h"

@implementation Calib3D

+ (NSString *)openCVVersionString {
    return [NSString stringWithFormat:@"OpenCV Version %s",  CV_VERSION];
}

+ (void)convertPointsFromHomogeneousWithSrc:(double*)src dst:(double*) dst {
    std::vector<cv::Point3d> homCamPoints(4, cv::Point3d(0,0,0));
    
    NSLog(@"src[0] %f",src[3]);
    homCamPoints[0] = cv::Point3d(src[0],src[1],src[2]);
    homCamPoints[1] = cv::Point3d(src[3],src[4],src[5]);
    homCamPoints[2] = cv::Point3d(src[6],src[7],src[8]);
    homCamPoints[3] = cv::Point3d(src[9],src[10],src[11]);
    
//    homCamPoints[0] = cv::Point3d(0,0,0);
//    homCamPoints[1] = cv::Point3d(1,1,1);
//    homCamPoints[2] = cv::Point3d(-1,-1,-1);
//    homCamPoints[3] = cv::Point3d(2,2,2);
    
    std::vector<cv::Point2d> inhomCamPoints(4);
    
    cv::convertPointsFromHomogeneous(homCamPoints, inhomCamPoints);
    dst[0] = inhomCamPoints[0].x;
    dst[1] = inhomCamPoints[0].y;
    dst[2] = inhomCamPoints[1].x;
    dst[3] = inhomCamPoints[1].y;
    dst[4] = inhomCamPoints[2].x;
    dst[5] = inhomCamPoints[2].y;
    dst[6] = inhomCamPoints[3].x;
    dst[7] = inhomCamPoints[3].y;
//
////    NSLog(@"dst[0] %f",inhomCamPoints[3]);
//
//    NSLog(@"dst[0] %f",dst[0]);
//    NSLog(@"dst[1] %f",dst[1]);
//    NSLog(@"dst[2] %f",dst[2]);
//    NSLog(@"dst[3] %f",dst[3]);
}

@end
