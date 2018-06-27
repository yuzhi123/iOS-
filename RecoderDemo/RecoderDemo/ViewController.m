//
//  ViewController.m
//  RecoderDemo
//
//  Created by koudaishu on 2018/6/26.
//  Copyright © 2018年 zkl. All rights reserved.
//

#import "ViewController.h"
#import "ScressRecorder.h"

@interface ViewController ()


@property (nonatomic,assign) BOOL isRecoder; // 是否录制中

@property (nonatomic,strong) UILabel* timeLabel; // 时间标签

@property (nonatomic,strong) UIView* recoderView;   //  录制试图

@property (nonatomic,strong) NSTimer* timer;


@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    self.view.backgroundColor = [UIColor whiteColor];
    [self creatUI];
    [self configRecoder];
    
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(timerAction) userInfo:nil repeats:true];
    [_timer setFireDate:[NSDate distantFuture]];
}

#pragma mark -- UI
-(void)creatUI{
    // 播放按钮
    UIButton* playBT = [UIButton buttonWithType:UIButtonTypeCustom];
    playBT.backgroundColor = [UIColor lightGrayColor];
    [playBT addTarget:self action:@selector(recoderWithPause:) forControlEvents:UIControlEventTouchUpInside];
    playBT.frame = CGRectMake(20, 20, 60, 60);
    [playBT setTitle:@"录制" forState:UIControlStateNormal];
    [playBT setTitle:@"暂停" forState:UIControlStateSelected];
    [self.view addSubview:playBT];
    // 结束录制
    UIButton* stopBt = [UIButton buttonWithType:UIButtonTypeCustom];
    stopBt.backgroundColor = [UIColor lightGrayColor];
    [stopBt addTarget:self action:@selector(stopAction) forControlEvents:UIControlEventTouchDragInside];
    stopBt.frame = CGRectMake(self.view.frame.size.width - 80, 20, 60, 60);
    [stopBt setTitle:@"结束" forState:UIControlStateNormal];
    [self.view addSubview:stopBt];
    // 录屏试图
    _recoderView = [[UIView alloc]initWithFrame:CGRectMake(0, 90, self.view.frame.size.width, self.view.frame.size.height-90)];
    _recoderView.backgroundColor = [UIColor lightGrayColor];
    [self.view addSubview:_recoderView];
    //  时间标签
    _timeLabel = [[UILabel alloc]initWithFrame:CGRectMake(0, (_recoderView.frame.size.height - 60)/2.0, self.view.frame.size.width, 60)];
    _timeLabel.textAlignment = 1;
    _timeLabel.font = [UIFont systemFontOfSize:30];
    _timeLabel.textColor = [UIColor redColor];
    _timeLabel.text = @"00:00:00";
    [_recoderView addSubview:_timeLabel];
    
}

#pragma mark -- 录屏配置
-(void)configRecoder{
    //添加录制层
    [ScressRecorder share].recordView = self.recoderView;
}

#pragma  mark -- action
// 播放 暂停  继续播放
-(void)recoderWithPause:(UIButton*)bt{
    
    [bt setTitle:@"继续" forState:UIControlStateNormal];
    bt.selected = !bt.selected;
    if (!self.isRecoder) {  // 开始操作
       [[ScressRecorder share] startRecording]; // 开始录制
        [_timer setFireDate:[NSDate distantPast]];
        return;
    }
    if (bt.selected) {  // 继续录屏操作
         [[ScressRecorder share] continueRecording];
    }
    else{   // 暂停操作
        //暂停录制
        [[ScressRecorder share] pauseRecording];
    }
    
}


-(void)timerAction{
    static int count = 0;
    _timeLabel.text = [NSString stringWithFormat:@"%02d:%02d:%02d",(++count)/3600,(count/60)%60,count%60];
    
}

// 停止播放
-(void)stopAction{
    self.isRecoder = false;
    [[ScressRecorder share] stopRecordingWithCompletion:^(NSURL *url){
        if (url) {
            NSLog(@"录制成功");
        }
        else{
            NSLog(@"录制失败");
        }
    }];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
