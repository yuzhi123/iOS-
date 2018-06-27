//
//  ScressRecorder.h
//  ZZWRecord
//
//  Created by zzw on 2017/8/11.
//  Copyright © 2017年 zzw. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
typedef void (^VideoCompletionBlock)(NSURL *videoUrl);
@interface ScressRecorder : NSObject
@property (nonatomic, readonly) BOOL isRecording;

//保存的路径 如果不填,保存到相册
@property (strong, nonatomic) NSURL *videoURL;

@property (strong, nonatomic) UIView *recordView;

+ (instancetype)share;
- (BOOL)startRecording;
//- (BOOL)startRecordingWithView:(UIView *)view;
- (void)pauseRecording;
- (void)continueRecording;
- (void)stopRecordingNeedClearup:(BOOL)need;

- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
@end
