//
//  Calib3DWrapper.h
//  Metal Camera
//
//  Created by Trustee Luangdilokrut on 1/4/19.
//  Copyright © 2019 Old Yellow Bricks. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Calib3D : NSObject

+ (NSString *)openCVVersionString;
+ (void)convertPointsFromHomogeneousWithSrc:(double*)src dst:(double*)dst;

@end

NS_ASSUME_NONNULL_END
