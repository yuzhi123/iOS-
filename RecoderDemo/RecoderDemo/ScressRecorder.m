//
//  ScressRecorder.m
//  Record
//
//  Created by zzw on 2017/8/11.
//  Copyright © 2017年 zzw. All rights reserved.
//

#define kUserDefaults       [NSUserDefaults standardUserDefaults]

#import "ScressRecorder.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>



@interface ScressRecorder()
@property (strong, nonatomic) AVAssetWriter *videoWriter;
@property (strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property (strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *avAdaptor;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (strong, nonatomic) NSDictionary *outputBufferPoolAuxAttributes;
@property (nonatomic) CFTimeInterval firstTimeStamp;
@property (nonatomic) BOOL isRecording;
@property (retain, nonatomic)   AVAudioRecorder  *recorder;
@property (copy, nonatomic)     NSString * recordFilePath;//录音文件路径

@end

@implementation ScressRecorder
{
    dispatch_queue_t _render_queue;
    dispatch_queue_t _append_pixelBuffer_queue;
    dispatch_semaphore_t _frameRenderingSemaphore;
    dispatch_semaphore_t _pixelAppendSemaphore;
    
    CGSize _viewSize;
    CGFloat _scale; // 分辨率设置 用于设置屏幕的清晰度
    
    CGColorSpaceRef _rgbColorSpace;
    CVPixelBufferPoolRef _outputBufferPool;
}

#pragma mark - initializers

+ (instancetype)share{
    static dispatch_once_t once;
    static ScressRecorder *share;
    dispatch_once(&once, ^{
        share = [[self alloc] init];
    });
    return share;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _viewSize = [UIApplication sharedApplication].delegate.window.bounds.size;
        _scale = [UIScreen mainScreen].scale;//计算屏幕分辨率
        // record half size resolution for retina iPads
        if ((UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) && _scale > 1) {
            _scale = 1.0;
        }
        _isRecording = NO;
        
        _append_pixelBuffer_queue = dispatch_queue_create("ScreenRecorder.append_queue", DISPATCH_QUEUE_SERIAL);
        _render_queue = dispatch_queue_create("ScreenRecorder.render_queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_render_queue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        // 信号量用来控制线程数量
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
        _pixelAppendSemaphore = dispatch_semaphore_create(1);
    }
    return self;
}

#pragma mark - public

- (void)setVideoURL:(NSURL *)videoURL
{
    NSAssert(!_isRecording, @"videoURL can not be changed whilst recording is in progress");
    _videoURL = videoURL;
}

- (BOOL)startRecording
{
    if (!_isRecording) {
        [self setUpWriter];
        _isRecording = (_videoWriter.status == AVAssetWriterStatusWriting);
        // 每当屏幕刷行一次就执行一次
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(writeVideoFrame)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        // 设置fps fps越大录制的时间越短
        if ([UIDevice currentDevice].systemVersion.floatValue >= 10.0) {
            _displayLink.preferredFramesPerSecond = 12;
        }
        else {
            _displayLink.frameInterval = 4;
        }
        [self recorderAudio];
    }
    return _isRecording;
}

- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
{
    if (_isRecording) {
        _isRecording = NO;
        [self endRecord];
        [_displayLink removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [_displayLink invalidate];
        [self completeRecordingSession:completionBlock];
    }
}

- (void)pauseRecording {
    if (_isRecording) {
        [self.recorder pause];
        [_displayLink setPaused:YES];
    }
}

- (void)continueRecording {
    if (_isRecording) {
        [self.recorder record];
        [_displayLink setPaused:NO];
    }
}

- (void)stopRecordingNeedClearup:(BOOL)need {
    if (_isRecording) {
        _isRecording = NO;
        [self endRecord];
        [_displayLink removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [_displayLink invalidate];
    }
    if (need) {
        [self cleanup];
    }
}

#pragma mark - private
#pragma mark -- 视频写入

-(void)setUpWriter
{
   //  色彩空间：（Color Space）这是一个色彩范围的容器，类型必须是CGColorSpaceRef.对于这个参数，我们可以传入CGColorSpaceCreateDeviceRGB函数的返回值，它将给我们一个RGB色彩空间。
    _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(_viewSize.width * _scale),
                                       (id)kCVPixelBufferHeightKey : @(_viewSize.height * _scale),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(_viewSize.width * _scale * 4)
                                       };
    
    _outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);
    
    NSError* error = nil;
    // 设置写入路径以及写入格式
    _videoWriter = [[AVAssetWriter alloc] initWithURL:self.videoURL ?: [self tempFileURL]
                                             fileType:AVFileTypeQuickTimeMovie
                                                error:&error];
    NSParameterAssert(_videoWriter);
    
    // 设置像素量
    NSInteger pixelNumber = _viewSize.width * _viewSize.height * _scale;
    // 像素比特
    NSDictionary* videoCompression = @{AVVideoAverageBitRateKey: @(pixelNumber * 11.4)};
    
    //
    NSDictionary* videoSettings = @{AVVideoCodecKey: AVVideoCodecH264,
                                    AVVideoWidthKey: [NSNumber numberWithInt:_viewSize.width*_scale],
                                    AVVideoHeightKey: [NSNumber numberWithInt:_viewSize.height*_scale],
                                    AVVideoCompressionPropertiesKey: videoCompression};// 视屏比特率
    
    _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    NSParameterAssert(_videoWriterInput);
    
   // 表明输入是否应该调整其处理媒体实时数据源的数据。
    _videoWriterInput.expectsMediaDataInRealTime = YES;
    _videoWriterInput.transform = [self videoTransformForDeviceOrientation];
    
    _avAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput sourcePixelBufferAttributes:nil];
    
    [_videoWriter addInput:_videoWriterInput];
    
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:CMTimeMake(0, 1000)];
}

- (CGAffineTransform)videoTransformForDeviceOrientation
{
    CGAffineTransform videoTransform;
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationLandscapeLeft:
            videoTransform = CGAffineTransformMakeRotation(-M_PI_2);
            break;
        case UIDeviceOrientationLandscapeRight:
            videoTransform = CGAffineTransformMakeRotation(M_PI_2);
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            videoTransform = CGAffineTransformMakeRotation(M_PI);
            break;
        default:
            videoTransform = CGAffineTransformIdentity;
    }
    return videoTransform;
}

- (NSURL*)tempFileURL
{
    NSString *outputPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/vido.mov"];
    [self removeTempFilePath:outputPath];
    return [NSURL fileURLWithPath:outputPath];
}

- (void)removeTempFilePath:(NSString*)filePath
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:filePath]) {
        NSError* error;
        if ([fileManager removeItemAtPath:filePath error:&error] == NO) {
            NSLog(@"Could not delete old recording:%@", [error localizedDescription]);
        }
    }
}

- (void)completeRecordingSession:(VideoCompletionBlock)completionBlock;
{
    dispatch_async(_render_queue, ^{
        dispatch_sync(_append_pixelBuffer_queue, ^{
            
            [_videoWriterInput markAsFinished];
            [_videoWriter finishWritingWithCompletionHandler:^{
                
                void (^completion)(NSURL *path) = ^(NSURL *path) {
                    [self cleanup];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completionBlock) completionBlock(path);
                    });
                };
                
                if (self.videoURL) {
                    
                    [self mergeVideoAndAudiocompletion:^(NSURL *path) {
                        
                        [self removeTempFilePath:_videoWriter.outputURL.path];
                        
                        [self removeTempFilePath:self.recordFilePath];
                        completion(path);
                    }];
                    
                } else {
                    
                    [self mergeVideoAndAudiocompletion:^(NSURL *path) {
                        
                        ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                        if(path != nil)
                        {
                            [library writeVideoAtPathToSavedPhotosAlbum:path completionBlock:^(NSURL *assetURL, NSError *error) {
                                if (error) {
                                    NSLog(@"Error copying video to camera roll:%@", [error localizedDescription]);
                                     NSLog(@"视频写入失败");
                                     //completion(path);
                                  
                                    
                                } else {
                                    [self removeTempFilePath:_videoWriter.outputURL.path];
                                    
                                    [self removeTempFilePath:self.recordFilePath];
                                    completion(path);
                                    NSLog(@"视频写入成功");
                                    
                                  
                                }
                            }];
                        }else
                        {
                            
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [kUserDefaults setObject:@"1" forKey:@"isFinish"];
                                [kUserDefaults synchronize];
                              //  [MBProgressHUD showErrorMessage:@"视频录制失败请重新录制"];
                            });
                        }
                        
                    }];
                    
                }
            }];
        });
    });
}

- (void)cleanup
{
    self.avAdaptor = nil;
    self.videoWriterInput = nil;
    self.videoWriter = nil;
    self.firstTimeStamp = 0;
    self.outputBufferPoolAuxAttributes = nil;
    if (_rgbColorSpace) {
        CGColorSpaceRelease(_rgbColorSpace);
    }
    if (_outputBufferPool) {
        CVPixelBufferPoolRelease(_outputBufferPool);
    }
   
}

#pragma mark -- 视频采样
- (void)writeVideoFrame
{
    // throttle the number of frames to prevent meltdown
    // technique gleaned from Brad Larson's answer here: http://stackoverflow.com/a/5956119
    if (dispatch_semaphore_wait(_frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    dispatch_async(_render_queue, ^{
        // 数据是否准备写入
        if (![_videoWriterInput isReadyForMoreMediaData]) return;
        
        if (!self.firstTimeStamp) {
            self.firstTimeStamp = _displayLink.timestamp;
        }
        CFTimeInterval elapsed = (_displayLink.timestamp - self.firstTimeStamp);
        CMTime time = CMTimeMakeWithSeconds(elapsed, 60);
        //基于图像缓冲区的类型。像素缓冲区实现图像缓冲区的内存存储
        CVPixelBufferRef pixelBuffer = NULL;
        CGContextRef bitmapContext = [self createPixelBufferAndBitmapContext:&pixelBuffer];
        
        // draw each window into the context (other windows include UIKeyboard, UIAlert)
        // FIX: UIKeyboard is currently only rendered correctly in portrait orientation
        dispatch_sync(dispatch_get_main_queue(), ^{
            UIGraphicsPushContext(bitmapContext); {
                [self.recordView drawViewHierarchyInRect:self.recordView.bounds afterScreenUpdates:NO];
            } UIGraphicsPopContext();
        });
        
        // append pixelBuffer on a async dispatch_queue, the next frame is rendered whilst this one appends
        // must not overwhelm the queue with pixelBuffers, therefore:
        // check if _append_pixelBuffer_queue is ready
        // if it’s not ready, release pixelBuffer and bitmapContext
        if (dispatch_semaphore_wait(_pixelAppendSemaphore, DISPATCH_TIME_NOW) == 0) {
            dispatch_async(_append_pixelBuffer_queue, ^{
                BOOL success = [_avAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
                if (!success) {
                    NSLog(@"Warning: Unable to write buffer to video:%@",pixelBuffer);
                }
                CGContextRelease(bitmapContext);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                CVPixelBufferRelease(pixelBuffer);
                
                dispatch_semaphore_signal(_pixelAppendSemaphore);
            });
        } else {
            CGContextRelease(bitmapContext);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
        }
        dispatch_semaphore_signal(_frameRenderingSemaphore);
    });
}

- (CGContextRef)createPixelBufferAndBitmapContext:(CVPixelBufferRef *)pixelBuffer
{
    CVPixelBufferPoolCreatePixelBuffer(NULL, _outputBufferPool, pixelBuffer);
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    
    CGContextRef bitmapContext = NULL;
    bitmapContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(*pixelBuffer),
                                          CVPixelBufferGetWidth(*pixelBuffer),
                                          CVPixelBufferGetHeight(*pixelBuffer),
                                          8, CVPixelBufferGetBytesPerRow(*pixelBuffer), _rgbColorSpace,
                                          kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
                                          );
    CGContextScaleCTM(bitmapContext, _scale, _scale);
    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, _viewSize.height);
    CGContextConcatCTM(bitmapContext, flipVertical);
    
    return bitmapContext;
}
#pragma mark 录音
- (void)recorderAudio{
    
    //设置文件名和录音路径
    self.recordFilePath = [self getPathByFileName:[NSUUID UUID].UUIDString ofType:@"wav"];
    //初始化录音
    AVAudioRecorder *temp = [[AVAudioRecorder alloc]initWithURL:[NSURL URLWithString:[self.recordFilePath stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]
                                                       settings:[self getAudioRecorderSettingDict]
                                                          error:nil];
    self.recorder = temp;
    self.recorder.meteringEnabled = YES;
    [self.recorder prepareToRecord];
    //开始录音
    [[AVAudioSession sharedInstance] setCategory: AVAudioSessionCategoryPlayAndRecord error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    [self.recorder record];
    
}

#pragma mark -- 暂停录制
- (void)pause {
    [self.recorder pause];
}

#pragma mark -- 结束录制
- (void)endRecord{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [self.recorder stop];
    self.recorder = nil;
}

#pragma mark -- 设置音频采样
- (NSDictionary*)getAudioRecorderSettingDict
{
    NSDictionary *recordSetting = [[NSDictionary alloc] initWithObjectsAndKeys:
                                   [NSNumber numberWithFloat: 8000.0],AVSampleRateKey, //采样率
                                   [NSNumber numberWithInt: kAudioFormatLinearPCM],AVFormatIDKey,
                                   [NSNumber numberWithInt:16],AVLinearPCMBitDepthKey,//采样位数 默认 16
                                   [NSNumber numberWithInt: 1], AVNumberOfChannelsKey,//通道的数目
                                   nil];
    return recordSetting;
}

- (NSString*)getPathByFileName:(NSString *)_fileName ofType:(NSString *)_type
{
    NSString* fileDirectory =
    [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/vido.wav"];

    return fileDirectory;
}
#pragma 音视频合成
-  (void)mergeVideoAndAudiocompletion:(void(^)(NSURL * path))block;
{
    BOOL result = YES;
    NSURL *audioUrl=[NSURL fileURLWithPath:self.recordFilePath];
    NSString *outputPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/vido.mov"];
    NSURL * videoUrl =  [NSURL fileURLWithPath:outputPath];
    
    AVURLAsset* audioAsset = [[AVURLAsset alloc]initWithURL:audioUrl options:nil];
    AVURLAsset* videoAsset = [[AVURLAsset alloc]initWithURL:videoUrl options:nil];
    
    //混合音乐
    AVMutableComposition* mixComposition = [AVMutableComposition composition];
    AVMutableCompositionTrack *compositionCommentaryTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                                        preferredTrackID:kCMPersistentTrackID_Invalid];
    NSArray *audioArr = [audioAsset tracksWithMediaType:AVMediaTypeAudio];
    NSLog(@"%@",audioArr);
    if (audioArr.count) {
        if ([compositionCommentaryTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioAsset.duration)
                                                ofTrack:[audioArr objectAtIndex:0]
                                                 atTime:kCMTimeZero error:nil]) {
            NSLog(@"插入成功");
        }
        else{
            NSLog(@"插入失败");
        }
    }else {
        result = NO;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
       // NSLog(@"%ld",[TImeChange getTimeFrom1970]);
        // [MBProgressHUD showActivityMessageInView:@"视频合成中"];
    });
   
    //混合视频
    AVMutableCompositionTrack *compositionVideoTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                                   preferredTrackID:kCMPersistentTrackID_Invalid];
    NSArray *videoArr = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
    dispatch_async(dispatch_get_main_queue(), ^{
       // NSLog(@"%ld",[TImeChange getTimeFrom1970]);
      //  [MBProgressHUD hideHUD];
    });
    if (videoArr.count) {
        NSError* error = nil;
       
        if ([compositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration)
                                           ofTrack:[videoArr objectAtIndex:0]
                                            atTime:kCMTimeZero error:&error]) {
            
           NSLog(@"视频插入成功");
        }
        else{
            NSLog(@"视频插入失败");
        }
    
        NSLog(@"视频合成成功");
    }else {
        
        NSLog(@"视频合成失败");
        result = NO;
    }
    
    AVAssetExportSession* _assetExport = [[AVAssetExportSession alloc] initWithAsset:mixComposition
                                                                          presetName:AVAssetExportPresetPassthrough];
    

   // 此处必须保证混合后的格式和混合前的格式一样,否则exportAsynchronouslyWithCompletionHandler的回调极可能不执行
    [_assetExport setOutputFileType:AVFileTypeQuickTimeMovie];
    //保存混合后的文件的过程
    if (self.videoURL) {
        
        _assetExport.outputURL = self.videoURL;
        
    }else{
        
        NSString* videoName = @"explain.mov";
        NSString *exportPath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:videoName];
     [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)objectAtIndex:0];
        NSURL    *exportUrl = [NSURL fileURLWithPath:exportPath];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:exportPath])
        {
            [[NSFileManager defaultManager] removeItemAtPath:exportPath error:nil];
        }
       
        NSLog(@"file type %@",_assetExport.outputFileType);
        _assetExport.outputURL = exportUrl;
    }
    
    // 支持快速去启动
    _assetExport.shouldOptimizeForNetworkUse = YES;
   
    // 视频导出
    [_assetExport exportAsynchronouslyWithCompletionHandler:
     ^(void )
     {
         NSLog(@"完成了");
         if (result) {
             block(_assetExport.outputURL);
         }else {
             block(nil);
         }
     }];
}

#pragma mark - getters & setters
- (void)setRecordView:(UIView *)recordView {
    _recordView = recordView;
    _viewSize = self.recordView.bounds.size;
}


@end

