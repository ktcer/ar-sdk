//
//  ViewController.m
//  BaiduAROpenSDKProDemo
//
//  Created by Asa on 2018/3/8.
//  Copyright © 2018年 JIA CHUANSHENG. All rights reserved.
//

#import "BARBusinessDemoViewController.h"

#if defined (__arm64__)

#import "BARMainController.h"
#import "BARRenderViewController.h"
#import "BARRouter.h"
#import "BARSDKPro.h"
#import "BARRouter+BARVoice.h"
#import "BARRouter+BARImageSearchModule.h"
#import "BARVideoRecorder.h"
#import "BARMainController+Public.h"
#import "BARRouter+BARTTS.h"
#import "BARCaseTask.h"
#import "BARCaseManager.h"
#import "BARRouter+BARLogoRecog.h"
#import <Photos/Photos.h>

#define IPAD     (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
#define ASPECT_RATIO (IPAD ? (4.0/3.0) : (16.0/9.0))

@interface BARBusinessDemoViewController ()<BARRenderViewControllerDataSource, UIAlertViewDelegate, BARCaseTaskDelegate,UINavigationControllerDelegate>
{
    BOOL _downloadFinished;
    BOOL _sameSearching;
    BOOL _logoInRecognition;
    BOOL _recording;
    BOOL _loadARFinished;
}

/**
 UI
 */
@property (nonatomic, strong) UIButton *moreButton;//更多按钮
@property (nonatomic, strong) UIButton *backButton;//返回按钮
@property (nonatomic, strong) UIButton *cameraButton;//相机翻转按钮：前后摄像头切换
@property (nonatomic, strong) UIButton *recorderButton;//录制按钮
@property (nonatomic, strong) UIButton *screenShotButton;//拍摄按钮
@property (nonatomic, strong) UILabel *progressLabel;//单个case预下载进度条展示
@property (nonatomic, strong) UILabel *tipsLabel;//提示Label
@property (nonatomic,strong) UIActivityIndicatorView *indicatorView;//loading

@property (nonatomic,strong) NSArray *actionArray;//操作列表

/**
 AR
 */
@property (nonatomic,strong) BARMainController *arController;//AR控制器
@property (nonatomic,strong) BARRenderViewController *renderVC;//相机控制器
@property (nonatomic, strong) BARVideoRecorder *videoRecorder;//AR视频录制

/**
 组件
 */
@property (nonatomic, strong) id voiceConfigure;//语音识别能力组件
@property (nonatomic, strong) id searchModule;//识图（本地+云端）识图能力组件
@property (nonatomic, strong) id logoRecogHandler;

/**
 Case预下载：通过创建BARCaseTask，来预下载case
 */
@property (nonatomic, strong) dispatch_queue_t delegateQueue;//BARCaseTask回调queue
@property (nonatomic, strong) NSOperationQueue *taskQueue;//将task添加进此queue
@property (nonatomic, strong) NSMutableDictionary * tasks;//task管理 @{ARKey:Task}

/**
 其他属性
 */
@property (nonatomic, copy) NSString *arKey;
@property (nonatomic, copy) NSString *arType;

@end

@implementation BARBusinessDemoViewController

#pragma mark - Lifecycle

/**
 ReadMe：
 case的几个操作流程如下：
 加载AR --> 下载AR资源包并且加载AR
 启动AR --> 加载AR成功后，调用startAR
 */

- (void)viewDidLoad {
    [super viewDidLoad];
    
    if([BARSDKPro isSupportAR]){
        [self setUpNotifications];//设置通知
        [self loadActionData];//设置操作列表
        [self setupARView];//设置ARView
        [self setupActionView];//设置UI
        
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (status == AVAuthorizationStatusDenied) {
            [self showalert:@"请在设置中打开相机权限"];
        } else if(status == AVAuthorizationStatusAuthorized) {
            [self cameraAuthorizedFinished];
        } else if(status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) {
                        [self cameraAuthorizedFinished];
                    } else {
                        [self showalert:@"请在设置中打开相机权限"];
                    }
                });
            }];
        } else {
            [self showalert:@"请在设置中打开相机权限"];
        }
    }
}

- (void)cameraAuthorizedFinished{
    [self setupARController];//设置AR控制器
    #error 设置ARKey&ARType
    self.arKey = @"";
    self.arType = @"";
    
    #error 设置申请的APPID、APIKey https://dumix.baidu.com/dumixar
    [BARSDKPro setAppID:@"" APIKey:@"" andSecretKey:@""];
    [self setupComponents];
    
}

- (void)setupComponents{
    [self setupARVoice];//设置语音组件
    [self setupTTS];//设置TTS组件
}

-(void)viewDidDisappear:(BOOL)animated{
    [super viewDidDisappear:animated];
    [[NSNotificationCenter defaultCenter]removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self  selector:@selector(orientationChanged:)    name:UIDeviceOrientationDidChangeNotification  object:nil];
    if (self.navigationController) {
        self.navigationController.delegate = self;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.navigationController) {
        self.navigationController.delegate = nil;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)dealloc {
    [self removeNotificationsObserver];
    [[BARRouter sharedInstance] voice_cleanUpWithConfigure:self.voiceConfigure];
    [[BARRouter sharedInstance] cleanUpTTS];
    [[BARRouter sharedInstance] logo_cleanUpWithCaller:self.logoRecogHandler];
    
    [self stop:nil];
}

#pragma mark - Private

- (NSOperationQueue *)taskQueue {
    if (!_taskQueue) {
        _taskQueue = [[NSOperationQueue alloc] init];
        _taskQueue.maxConcurrentOperationCount = 4;
    }
    return _taskQueue;
}

- (dispatch_queue_t)delegateQueue {
    if (!_delegateQueue) {
        _delegateQueue = dispatch_queue_create("com.baidu.bar.sdk.casetask.queue",DISPATCH_QUEUE_SERIAL);
    }
    return _delegateQueue;
}

- (NSMutableDictionary *)tasks {
    if (!_tasks) {
        _tasks = [[NSMutableDictionary alloc] init];
    }
    return _tasks;
}

- (BARVideoRecorder *)videoRecorder {
    if (!_videoRecorder) {
        _videoRecorder = [[BARVideoRecorder alloc] initVideoRecorder];
    }
    return _videoRecorder;
}

#pragma mark - Notifications

- (void)setUpNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationEnterForeground:)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (void)removeNotificationsObserver {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    [self.arController pauseAR];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    [self.arController pauseAR];
}

- (void)applicationEnterForeground:(NSNotification *)notification
{
    [self.arController resumeAR];
}

#pragma mark - Setup

- (void)setupARController{
    self.arController = [[BARMainController alloc]initARWithCameraSize:self.renderVC.cameraSize previewSize:self.renderVC.previewSizeInPixels];
    [self.arController setDevicePosition:[self.renderVC devicePosition]];
    __weak typeof(self) weakSelf = self;
    [self.arController setUiStateChangeBlock:^(BARSDKUIState state, NSDictionary *stateInfo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.tipsLabel.text = @"";
            switch (state) {
                    
                case BARSDKUIState_DistanceNormal:
                {
                    
                }
                    break;
                    
                case BARSDKUIState_DistanceTooFar:
                case BARSDKUIState_DistanceTooNear:
                {
                    NSLog(@"过远，过近");
                }
                    break;
                case BARSDKUIState_TrackLost_HideModel:
                {
                    [weakSelf.arController setBAROutputType:BAROutputVideo];
                }
                    break;
                case BARSDKUIState_TrackLost_ShowModel:
                {
                    NSLog(@"跟踪丢失,显示模型");
                }
                    break;
                    
                case BARSDKUIState_TrackOn:
                {
                    [weakSelf.arController setBAROutputType:BAROutputBlend];
                    break;
                }
                    
                case BARSDKUIState_TrackTimeOut:
                {
                    //跟踪超时
                }
                    break;
                    
                default:
                    break;
            }
        });
    }];
    
    self.arController.luaMsgBlock = ^(BARMessageType msgType, NSDictionary *dic) {
        switch (msgType) {
            case BARMessageTypeOpenURL:
            {
                //打开浏览器
                NSString *urlStr = dic[@"url"];
                if (urlStr) {
                    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlStr]];
                }
                
            }
                break;
            case BARMessageTypeEnableFrontCamera:
            {
                //允许前置摄像头使用
                weakSelf.cameraButton.hidden = NO;
            }
                break;
            case BARMessageTypeChangeFrontBackCamera:
            {
                //前后摄像头切换
                [weakSelf cameraSwitchBtnClick:nil];
            }
                break;
            case BARMessageTypeIntitialClick:
            {
                //引导图点击
            }
                break;
            case BARMessageTypeNativeUIVisible:
            {
                //隐藏或者显示界面元素
            }
                break;
            case BARMessageTypeCloseAR:
            {
                [weakSelf closeAR:nil];
            }
                break;
            case BARMessageTypeShowAlert:
            {
                //展示弹框
            }
                break;
            case BARMessageTypeShowToast:
            {
                //展示提示框
            }
                break;
            case BARMessageTypeSwitchCase:
            {
                //切换Case
            }
                break;
            case BARMessageTypeLogoStart:
            {
                //Logo识别开始
                [weakSelf logoRecogChanged:YES];
            }
                break;
            case BARMessageTypeLogoStop:
            {
                //Logo识别结束
                [weakSelf logoRecogChanged:NO];
            }
                break;
            case BARMessageTypeBatchDownloadRetryShowDialog:
            {
                //分布加载
                [weakSelf handleBatchDownload];
            }
                break;
            default:
                break;
        }
    };
}

- (void)handleCommonLuaMsg:(NSDictionary *)dic{
    NSInteger msgId = [[dic objectForKey:@"id"] integerValue];
    if(22000 == msgId){
        NSString *ar_key  = [dic objectForKey:@"arkey"];
        NSString *ar_type = [dic objectForKey:@"artype"];
        if(![self canOpenNewCase:ar_key arType:ar_type]){
            return;
        }
        [self openNewCase:ar_key arType:ar_type];
    }
}

- (BOOL)canOpenNewCase:(NSString *)arKey arType:(NSString *)arType{
    if(!arKey || !arType){
        return NO;
    }
    if(arKey.length == 0 || arType.length == 0){
        return NO;
    }
    if([arKey isEqualToString:self.arKey]){
        //return NO;
    }
    return YES;
}

- (void)openNewCase:(NSString *)arKey arType:(NSString *)arType{
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self unLoadCase];
        kBARType curType = [self.arController arTypeFromServer:arType];
        self.arKey = arKey;
        self.arType = [NSString stringWithFormat:@"%i",curType];
        [self loadAR:nil];
    });
    
}

- (void)handleBatchDownload {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"网络不给力" message:@"是否重试？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    __weak typeof(self) weakSelf = self;
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf.arController cancelDownloadBatchZip];
    }];
    [alert addAction:cancelAction];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"重试" style:UIAlertControllerStyleAlert handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf.arController retryDownloadBatchZip];
    }];
    
    [self presentViewController:alert animated:YES completion:NULL];
    
}

- (void)loadActionData{
    
    self.actionArray = @[
                         @{@"action":@"downloadAR:",
                           @"des":@"预下载AR",
                           },
                         @{@"action":@"cancelAllTask:",
                           @"des":@"取消下载",
                           },
                         @{@"action":@"loadAR:",
                           @"des":@"加载AR",
                           }
                         ,@{@"action":@"pause:",
                            @"des":@"暂停AR",
                            }
                         ,@{@"action":@"resume:",
                            @"des":@"恢复AR",
                            }
                         ,@{@"action":@"stop:",
                            @"des":@"停止AR",
                            }
                         ,
                         @{@"action":@"switchAR:",
                           @"des":@"切换AR",
                           },
                         
                         @{@"action":@"loadLocalAR:",
                           @"des":@"从本地加载AR",
                           },
                         @{@"action":@"startSameSearch",
                           @"des":@"开始识图",
                           },
                         @{@"action":@"stopSameSearch",
                           @"des":@"停止识图",
                           },
                         
                         @{@"action":@"startVoice:",
                           @"des":@"启动语音",
                           },
                         @{@"action":@"stopVoice:",
                           @"des":@"结束语音",
                           },
                         @{@"action":@"closeAR:",
                           @"des":@"关闭页面",
                           }
                         ];
}

- (void)setupARView{
    self.renderVC = [[BARRenderViewController alloc] init];
    self.renderVC.aspect = ASPECT_RATIO;
    self.renderVC.dataSource = self;
    self.renderVC.isLandscape = self.isLandscape;
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    self.renderVC.frame = CGRectMake(0, 0, screenWidth, screenHeight);
    [self addChildViewController:self.renderVC];
    [self.view addSubview:self.renderVC.view];
    self.renderVC.view.backgroundColor = [UIColor clearColor];
    [self.renderVC didMoveToParentViewController:self];
}

- (void)setupActionView {
    self.cameraButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.cameraButton addTarget:self action:@selector(cameraSwitchBtnClick:) forControlEvents:UIControlEventTouchUpInside];
    [self.cameraButton setTitle:@" 翻转 " forState:UIControlStateNormal];
    [self.cameraButton sizeToFit];
    self.cameraButton.backgroundColor = [UIColor brownColor];
    [self.view addSubview:self.cameraButton];
    
    
    self.recorderButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.recorderButton addTarget:self action:@selector(shootVideo:) forControlEvents:UIControlEventTouchUpInside];
    [self.recorderButton setTitle:@" 录制 " forState:UIControlStateNormal];
    [self.recorderButton sizeToFit];
    self.recorderButton.backgroundColor = [UIColor brownColor];
    [self.view addSubview:self.recorderButton];
    
    self.screenShotButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.screenShotButton addTarget:self action:@selector(takePic:) forControlEvents:UIControlEventTouchUpInside];
    [self.screenShotButton setTitle:@" 拍摄 " forState:UIControlStateNormal];
    [self.screenShotButton sizeToFit];
    self.screenShotButton.backgroundColor = [UIColor brownColor];
    [self.view addSubview:self.screenShotButton];
    
    self.cameraButton.layer.position = CGPointMake(50,self.view.frame.size.height - 30);
    self.recorderButton.layer.position = CGPointMake(self.view.frame.size.width/2,self.view.frame.size.height - 30);
    self.screenShotButton.layer.position = CGPointMake(self.view.frame.size.width/2 + 60, self.view.frame.size.height - 30);
    
    if (self.isLandscape) {
        UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
        if (UIInterfaceOrientationPortrait == orientation || UIInterfaceOrientationPortraitUpsideDown == orientation) {
            self.cameraButton.layer.position = CGPointMake(self.view.frame.size.height - 30, 50);
            self.recorderButton.layer.position = CGPointMake(self.view.frame.size.height - 30, self.view.frame.size.width/2);
            self.screenShotButton.layer.position = CGPointMake(self.view.frame.size.height - 30, self.view.frame.size.width/2 + 60);
        }else {
            [self adjustViewsForOrientation:orientation];
        }
    }
    
    self.backButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.backButton addTarget:self action:@selector(closeAR:) forControlEvents:UIControlEventTouchUpInside];
    [self.backButton setTitle:@" 返回 " forState:UIControlStateNormal];
    [self.backButton sizeToFit];
    self.backButton.backgroundColor = [UIColor orangeColor];
    self.backButton.frame = CGRectMake(15, 30, 45, 45);
    [self.view addSubview:self.backButton];
    
    self.moreButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.moreButton addTarget:self action:@selector(more:) forControlEvents:UIControlEventTouchUpInside];
    [self.moreButton setTitle:@" 更多 " forState:UIControlStateNormal];
    [self.moreButton sizeToFit];
    self.moreButton.backgroundColor = [UIColor blueColor];
    self.moreButton.frame = CGRectMake(self.backButton.frame.size.width + self.backButton.frame.origin.x + 30, 30, 45, 45);
    [self.view addSubview:self.moreButton];
    
    if (self.navigationController) {
        self.navigationController.delegate = self;
    }
}

- (void)more:(id)sender {
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:@"操作" message:nil
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];
    
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *dic in self.actionArray) {
        
        NSString *title = dic[@"des"];
        SEL selector = NSSelectorFromString(dic[@"action"]);
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            if (selector) {
                [weakSelf performSelector:selector withObject:nil];
            }
        }];
        
        [actionSheet addAction:action];
    }
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:NULL];
    [actionSheet addAction:cancelAction];
    
    if (actionSheet.popoverPresentationController) {
        actionSheet.popoverPresentationController.sourceView = sender;
        actionSheet.popoverPresentationController.sourceRect = [sender bounds];
    }
    
    [self presentViewController:actionSheet animated:YES completion:NULL];
}

- (UIActivityIndicatorView *)indicatorView {
    if (!_indicatorView) {
        _indicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
        _indicatorView.center = self.view.center;
        _indicatorView.hidesWhenStopped = YES;
        _indicatorView.backgroundColor = [UIColor blueColor];
        [self.view addSubview:_indicatorView];
    }
    return _indicatorView;
}

- (UILabel *)progressLabel {
    if (!_progressLabel) {
        _progressLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _progressLabel.text = @"             ";
        [_progressLabel sizeToFit];
        _progressLabel.center = CGPointMake(self.view.center.x, self.view.center.y + 30);
        _progressLabel.textAlignment = NSTextAlignmentCenter;
        _progressLabel.backgroundColor = [UIColor clearColor];
        _progressLabel.font = [UIFont systemFontOfSize:18];
        [self.view addSubview:_progressLabel];
    }
    return _progressLabel;
}

- (UILabel *)tipsLabel {
    if (!_tipsLabel) {
        _tipsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _tipsLabel.text = @"             ";
        [_tipsLabel sizeToFit];
        _tipsLabel.center = CGPointMake(self.view.center.x, self.view.center.y + 30);
        _tipsLabel.textAlignment = NSTextAlignmentCenter;
        _tipsLabel.backgroundColor = [UIColor clearColor];
        _tipsLabel.font = [UIFont systemFontOfSize:18];
        [self.view addSubview:_tipsLabel];
    }
    return _tipsLabel;
}
#pragma mark - Actions

//case预下载
- (void)downloadAR:(id)sender {
    self.progressLabel.text = @"";
    [self.indicatorView startAnimating];
    BARCaseTask *task = [[BARCaseTask alloc] initWithDelegateQueue:self.delegateQueue];
    task.arkey = self.arKey;
    [task addDelegate:self];
    [self.tasks setObject:task forKey:self.arKey];
    [self.taskQueue addOperation:task];
}

//取消下载
- (void)cancelAllTask:(id)sender {
    //默认取消所有task，业务方可自定义下载、取消逻辑
    [self.taskQueue cancelAllOperations];
    @synchronized (self.tasks) {
        NSArray *allKey = [self.tasks allKeys];
        for (NSString *arKey in allKey) {
            BARCaseTask* task = [self.tasks objectForKey:arKey];
            if(![task isCancelled]){
                [task cancel];
            }
            [task removeDelegate:self];
        }
        [self.tasks removeAllObjects];
    }
    [self.indicatorView stopAnimating];
    self.progressLabel.text = @"";
    [self.progressLabel removeFromSuperview];
    self.progressLabel = nil;
}

//加载AR
- (void)loadAR:(id)sender {
    _loadARFinished = NO;
    [self.indicatorView startAnimating];
    self.renderVC.videoPreviewView.enabled = NO;
    [self unLoadCase];
    [self.renderVC changeToSystemCamera];
    
    __weak typeof(self) weakSelf = self;
    [self.arController loadAR:self.arKey success:^(NSString *arKey, kBARType arType) {
        [weakSelf.indicatorView stopAnimating];
        [weakSelf handleARKey:arKey arType:arType];
    } failure:^{
        [weakSelf.indicatorView stopAnimating];
    }];
    
}

- (void)loadLocalAR:(id)sender {
    _loadARFinished = NO;
    [self.indicatorView startAnimating];
    self.renderVC.videoPreviewView.enabled = NO;
    [self unLoadCase];
    [self.renderVC changeToSystemCamera];
    
    __weak typeof(self) weakSelf = self;
    NSString *localPath = [[NSBundle mainBundle] pathForResource:@"aiqiyi" ofType:@"bundle"];
    [self.arController loadARFromFilePath:localPath arType:@"5" success:^(NSString *arKey, kBARType arType) {
        [weakSelf.indicatorView stopAnimating];
        [weakSelf handleARKey:arKey arType:arType];
    } failure:^{
        [weakSelf.indicatorView stopAnimating];
    }];
}

/**
 if ARType = 6 || 7 --->加载识图模块
 else kBARTypeUnkonw 当前不支持
 else               --->启动AR
 */
- (void)handleARKey:(NSString *)arKey arType:(kBARType)arType {
    if (arKey && ![arKey isEqualToString:@""]) {
        self.arKey = arKey;
    }
    self.arType = [NSString stringWithFormat:@"%i",arType];
    if (kBARTypeLocalSameSearch == arType || kBARTypeCloudSameSearch == arType) {
        [self startSameSearch];
    }else if (kBARTypeARKit == arType) {
        //UnSupport
    }else {
        [self start:nil];
    }
}

//启动AR
- (void)start:(id)sender{
    _loadARFinished = YES;
    [self.arController startAR];
    if(self.renderVC.videoPreviewView){
        self.renderVC.videoPreviewView.enabled = YES;
        [self.arController setTargetView:self.renderVC.videoPreviewView];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.renderVC changeToARCamera];
        });
    }
}

- (void)changeToBackCamera{
    if(1 == [self.renderVC devicePosition]){//front
        [self.renderVC rotateCamera];
    }
}

//停止AR
- (void)stop:(id)sender{
    //打点
    [self unLoadCase];
    _loadARFinished = NO;
    self.renderVC.videoPreviewView.enabled = NO;
    [self.renderVC changeToSystemCamera];
    [[BARRouter sharedInstance] cancelTTS];
    [self.arController destroyCaseForSameSearch:^{
    }];
}

//暂停AR
- (void)pause:(id)sender{
    [self.arController pauseAR];
    [[BARRouter sharedInstance] pauseTTS];
}

//恢复AR
- (void)resume:(id)sender{
    [self.arController resumeAR];
    [[BARRouter sharedInstance] resumeTTS];
}

//停止AR并关闭相机
- (void)closeARView {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf stop:nil];
        [weakSelf.renderVC stopCapture];
        [weakSelf dismissViewControllerAnimated:YES completion:NULL];
    });
}

//切换AR：需要输入内容平台ARKey以及ARType
- (void)switchAR:(id)sender {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"输入ARKey&ARType" message:nil delegate:self cancelButtonTitle:@"取消" otherButtonTitles:@"确定", nil];
    alert.alertViewStyle = UIAlertViewStyleLoginAndPasswordInput;
    [[alert textFieldAtIndex:1] setSecureTextEntry:NO];
    [[alert textFieldAtIndex:0] setPlaceholder:@"ARKey"];
    [[alert textFieldAtIndex:1] setPlaceholder:@"ARType"];
    [alert textFieldAtIndex:0].text = self.arKey;
    [alert textFieldAtIndex:1].text = self.arType;
    [alert textFieldAtIndex:0].clearButtonMode = UITextFieldViewModeAlways;
    [alert textFieldAtIndex:1].clearButtonMode = UITextFieldViewModeAlways;
    [alert show];
}

//视频录制
- (void)shootVideo:(id)sender {
    
    if (!_loadARFinished) {
        
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:nil message:@"还没有加载AR" delegate:nil
                                                  cancelButtonTitle:nil otherButtonTitles:@"OK", nil];
        [alertView show];
        
        return;
    }
    
    if (_recording) {
        [self stopShootVideo:sender];
        [(UIButton *)sender setTitle:@" 录制 " forState:UIControlStateNormal];
    }else {
        [(UIButton *)sender setTitle:@" 停止 " forState:UIControlStateNormal];
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if(status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                if(granted){
                    [self.videoRecorder updateWriterWithAudioTrack:YES];
                    [self shootVideoBtnStartAction:YES];
                }
                else{
                    [self.videoRecorder updateWriterWithAudioTrack:NO];
                    [self shootVideoBtnStartAction:NO];
                }
            }];
        }
        else if(status == AVAuthorizationStatusDenied) {
            [self shootVideoBtnStartAction:NO];
        }
        else{
            [self shootVideoBtnStartAction:YES];
        }
    }
    _recording = !_recording;
}

- (void)shootVideoBtnStartAction:(BOOL)enableAudioTrack {
    if(self.videoRecorder.isRecording) {
        return ;
    }
    [self.videoRecorder startRecordingWithAudioTrack:YES];
    [self.arController setRenderMovieWriter:self.videoRecorder.movieWriter];
}

//停止视频录制
- (void)stopShootVideo:(id)sender {
    [self.videoRecorder stopRecording:^{
        [self.arController setRenderMovieWriter:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"videoDuration %f",self.videoRecorder.videoDuration);
            NSString *videoPath = [BARSDKPro getVideoPath];
            NSLog(@"videoPath %@",videoPath);
            [self save:nil videoPath:videoPath];

        });
    }];
    
}

//拍照
- (void)takePic:(id)sender {
    
    if (!_loadARFinished) {
        
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:nil message:@"还没有加载AR" delegate:nil
                                                  cancelButtonTitle:nil otherButtonTitles:@"OK", nil];
        [alertView show];
        
        return;
    }
    
    
    [self.arController takePicture:^(UIImage *image) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) {
                [self save:image videoPath:nil];
            }
        });
    }];
}

//关闭AR
- (void)closeAR:(id)sender {
    [self closeARView];
}

//相机前后摄像头切换
- (void)cameraSwitchBtnClick:(id)resp {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        //        [self.renderVC stopCapture];
        [self.renderVC rotateCamera];
        [self.arController setDevicePosition:[self.renderVC devicePosition]];
        
        __weak typeof(self)weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            CATransition* anim = [CATransition animation];
            anim.type = @"oglFlip";
            anim.subtype = @"fromLeft";
            anim.duration = .5f;
            [weakSelf.view.layer addAnimation:anim forKey:@"rotate"];
        });
        
        //        [self.renderVC startCapture];
        
        [self.arController sendMsgToLuaWithMapData:@{@"id":[NSNumber numberWithInteger:10200],
                                                     @"front_camera": [NSNumber numberWithInteger:[self.renderVC devicePosition]]}];
        
    });
}

#pragma mark - BARRenderViewControllerDataSource


- (void)save:(UIImage*)image videoPath:(NSString *)videoPath {
    
    __weak typeof(self) weakSelf = self;
    PHAuthorizationStatus authorStatus = [PHPhotoLibrary authorizationStatus];
    
    if (authorStatus == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized) {
                [weakSelf save:image videoPath:videoPath];
                return ;
            }
        }];
        return;
        
    } else if (authorStatus == PHAuthorizationStatusRestricted || authorStatus == PHAuthorizationStatusDenied) {
        [self showtoast:@"请设置相册访问权限"];
        return;
    }
    
    if(image){
        UIImageWriteToSavedPhotosAlbum(image, self, @selector(sender:didFinishSavingWithError:contextInfo:), NULL);
    }
    else if(videoPath &&videoPath.length>0){
        UISaveVideoAtPathToSavedPhotosAlbum(videoPath, self, @selector(sender:didFinishSavingWithError:contextInfo:), nil);
    }
}

- (void)showalert:(NSString *)alertinfo{
    UIAlertController *vc = [UIAlertController alertControllerWithTitle:@"提示" message:alertinfo
                                                                preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [vc dismissViewControllerAnimated:YES completion:^{
            
        }];
    }];
    [vc addAction:cancelAction];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self presentViewController:vc animated:YES completion:NULL];
    });

    
}


- (void)showtoast:(NSString *)alert{
    UIAlertController *alertview = [UIAlertController alertControllerWithTitle:@"提示" message:alert
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    
    
    [self presentViewController:alertview animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [alertview dismissViewControllerAnimated:YES completion:^{
                
            }];
        });
    }];

}
                                             
                                             
- (void)sender:(id )sender didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
     if (!error) {
         [self showtoast:@"保存成功"];
     } else {
         [self showtoast:@"保存失败"];
         
    }
}
/**
 Render DataSource
 @param srcBuffer 相机buffer源
 */
- (void)updateSampleBuffer:(CMSampleBufferRef)srcBuffer {
    
    if (_sameSearching) {
        [[BARRouter sharedInstance] imageSearch_setBufferFrame:(__bridge id _Nonnull)(srcBuffer) withCaller:self.searchModule];
    }else if (_logoInRecognition && self.logoRecogHandler){
        [[BARRouter sharedInstance] logo_updateSampleBuffer:(__bridge id)(srcBuffer) withCaller:self.logoRecogHandler];
    }else {
        [self.arController updateSampleBuffer:srcBuffer];
    }
}

- (void)updateAudioSampleBuffer:(CMSampleBufferRef)audioBuffer {
    if(self.videoRecorder.isRecording){
        [self.videoRecorder.movieWriter processAudioBuffer:audioBuffer];
    }
}

#pragma mark - Gesture

- (void)onViewGesture:(UIGestureRecognizer *)gesture{
    [self.arController onViewGesture:gesture];
}
- (void)touchesBegan:(CGPoint)point scale:(CGFloat)scale{
    [self.arController touchesBegan:point scale:scale];
}
- (void)touchesMoved:(CGPoint)point scale:(CGFloat)scale{
    [self.arController touchesMoved:point scale:scale];
}
- (void)touchesEnded:(CGPoint)point scale:(CGFloat)scale{
    [self.arController touchesEnded:point scale:scale];
}
- (void)touchesCancelled:(CGPoint)point scale:(CGFloat)scale{
    [self.arController touchesCancelled:point scale:scale];
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex != alertView.cancelButtonIndex) {
        self.arKey = [alertView textFieldAtIndex:0].text;
        self.arType = [alertView textFieldAtIndex:1].text;
    }
}

#pragma mark - Voice

- (void)setupARVoice{
    self.voiceConfigure = [[BARRouter sharedInstance] voice_createVoiceConfigure];
    [[BARRouter sharedInstance] voice_setStopBlock:^{
        NSLog(@"voiceStop");
    } withConfigure:self.voiceConfigure];
    
    
    [[BARRouter sharedInstance] voice_setStartBlock:^(BOOL success){
        NSLog(@"voiceStart");
    } withConfigure:self.voiceConfigure];
    
    [[BARRouter sharedInstance] voice_setStatusBlock:^(int status, id aObj) {
        switch (status) {
            case BARVoiceUIState_ShowLoading:
            {
                break;
            }
            case BARVoiceUIState_StopLoading:
            {
                break;
            }
            case BARVoiceUIState_ShowWave:
            {
                break;
            }
            case BARVoiceUIState_StopWave:
            {
                break;
            }
            case BARVoiceUIState_WaveChangeVolume:
            {
                NSLog(@"volume %li",(long)[aObj integerValue]);
                break;
            }
            case BARVoiceUIState_ShowTips:
            {
                NSLog(@"tips %@",aObj);
                break;
            }
            case BARVoiceUIState_HideVoice:
            {
                break;
            }
            default:
                break;
        }
    } withConfigure:self.voiceConfigure];
    
    [[BARRouter sharedInstance] voice_setUpWithConfigure:self.voiceConfigure];
}

//开启语音识别
- (void)startVoice:(id)sender {
    [[BARRouter sharedInstance] voice_startVoiceWithConfigure:self.voiceConfigure];
}

//结束语音识别
- (void)stopVoice:(id)sender {
    [[BARRouter sharedInstance] voice_stopVoiceWithConfigure:self.voiceConfigure];
}

#pragma mark - TTS Component

//设置TTS
- (void)setupTTS {
    [[BARRouter sharedInstance] setUpTTS];
}

#pragma mark - SameSearch Component

//设置识图组件
- (void)setUpSameSearch {
    __weak typeof(self) weakSelf = self;
    
    //没有设置过,则初始化 否则changeType:本地识图或者语段识图
    if(!self.searchModule)
    {
        self.searchModule = [[BARRouter sharedInstance] imageSearch_initWithARType:kBARTypeCloudSameSearch];//kBARTypeLocalSameSearch本地识图 kBARTypeCloudSameSearch云端识图
        [[BARRouter sharedInstance] imageSearch_loadSameSearchWithCaller:self.searchModule];
        [[BARRouter sharedInstance] imageSearch_setResultBlock:^(id  _Nonnull result) {
            if (result && [result isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dic = result;
                NSString *arKey = dic[@"arKey"];
                NSString *arType = dic[@"arType"];
                if (arKey && arType && weakSelf) {
                    //识别到ARKey&ARType，加载AR
                    weakSelf.arKey = arKey;
                    weakSelf.arType = arType;
                    [weakSelf stopSameSearch];//停止识图模块
                    [weakSelf loadAR:nil];//开始加载AR
                }
            }
        } withCaller:self.searchModule];
        
        [[BARRouter sharedInstance] imageSearch_setErrorBlock:^(NSError * _Nonnull error) {
            
            NSDictionary *userInfo = error.userInfo;
            switch(error.code){
                case BARImageSearchError_NetWrong:
                {
                    dispatch_block_t ensurreBlock = userInfo[@"ensureBlock"];
                    NSLog(@"网络错误，继续访问");
                    if(ensurreBlock){
                        ensurreBlock();
                    }
                }
                    break;
                case BARImageSearchError_DataWrong:
                {
                    NSLog(@"参数错误");
                }
                    break;
                case BARImageSearchError_DownLoadFeaWrong:
                {
                    NSLog(@"下载错误，继续下载");
                    dispatch_block_t ensurreBlock = userInfo[@"ensureBlock"];
                    if(ensurreBlock){
                        ensurreBlock();
                    }
                }
                    break;
                case BARImageSearchError_ImageSearchTimeout:{
                    NSLog(@"没有识别出case，继续识别");
                    dispatch_block_t dismissBlock = userInfo[@"dismissBlock"];
                    if(dismissBlock){
                        dismissBlock();
                    }
                }
                    break;
            }
            
        } withCaller:self.searchModule];
    }else{
        [[BARRouter sharedInstance] imageSearch_switchARType:kBARTypeCloudSameSearch withCaller:self.searchModule];
    }
}

//开始识图
- (void)startSameSearch {
    self.renderVC.videoPreviewView.enabled = NO;
    [self unLoadCase];//卸载当前case
    _loadARFinished = NO;
    
    __weak typeof(self) weakSelf = self;
    [self.arController destroyCaseForSameSearch:^{
        if(weakSelf){
            dispatch_async(dispatch_get_main_queue(), ^{
                if(weakSelf){
                    [weakSelf setUpSameSearch];
                    self->_sameSearching = YES;
                    [[BARRouter sharedInstance] imageSearch_startImageSearchWithCaller:weakSelf.searchModule];
                }
            });
        }
    }];
}

//停止识图
- (void)stopSameSearch {
    _sameSearching = NO;
    [[BARRouter sharedInstance] imageSearch_stopImageSearchWithCaller:self.searchModule];
}

//卸载当前case，以及当前case使用的组件能力
- (void)unLoadCase {
    [self.arController cancelDownLoadArCase];
    [self changeToBackCamera];
    [[BARRouter sharedInstance] cancelTTS];
    [[BARRouter sharedInstance] voice_stopVoiceWithConfigure:self.voiceConfigure];
    [[BARRouter sharedInstance] logo_startLogoRecog:NO withCaller:self.logoRecogHandler];
}

#pragma mark - Logo Components

- (void)setupLogoRecog {
    if (!self.logoRecogHandler) {
        self.logoRecogHandler = [[BARRouter sharedInstance] logo_init];
        __weak typeof(self) weakSelf = self;
        [[BARRouter sharedInstance] logo_setLogoRecogErrorBlock:^(NSError *error) {
            //Error
            
        } withCaller:self.logoRecogHandler];
    }
}

- (void)logoRecogChanged:(BOOL)start {
    if (!self.logoRecogHandler) {
        return;
    }
    if (start) {
        _logoInRecognition = YES;
        [[BARRouter sharedInstance] logo_startLogoRecog:YES withCaller:self.logoRecogHandler];
    } else {
        _logoInRecognition = NO;
        [[BARRouter sharedInstance] logo_startLogoRecog:NO withCaller:self.logoRecogHandler];
    }
}

#pragma mark - Orientations

- (BOOL)shouldAutorotate {
    return self.isLandscape;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (self.isLandscape) {
        return UIInterfaceOrientationMaskLandscape;
    }else {
        return UIInterfaceOrientationMaskPortrait;
    }
}

- (UIInterfaceOrientationMask)navigationControllerSupportedInterfaceOrientations:(UINavigationController *)navigationController {
    if (self.isLandscape) {
        return UIInterfaceOrientationMaskLandscape;
    }else {
        return UIInterfaceOrientationMaskPortrait;
    }
}

- (void)orientationChanged:(NSNotification *)notification{
    [self adjustViewsForOrientation:[[UIApplication sharedApplication] statusBarOrientation]];
}

- (void) adjustViewsForOrientation:(UIInterfaceOrientation) orientation {
    if (!self.isLandscape) {
        return;
    }
    switch (orientation)
    {
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationPortraitUpsideDown:
            break;
        case UIInterfaceOrientationLandscapeLeft:
        {
            self.cameraButton.layer.position = CGPointMake(30, self.view.frame.size.height - 30);
            self.recorderButton.layer.position = CGPointMake(30, self.view.frame.size.height/2);
            self.screenShotButton.layer.position = CGPointMake(30, self.view.frame.size.height/2 + 60);
        }
            break;
        case UIInterfaceOrientationLandscapeRight:
        {
            self.cameraButton.layer.position = CGPointMake(self.view.frame.size.width - 30, 50);
            self.recorderButton.layer.position = CGPointMake(self.view.frame.size.width - 30, self.view.frame.size.height/2);
            self.screenShotButton.layer.position = CGPointMake(self.view.frame.size.width - 30, self.view.frame.size.height/2 + 60);
        }
            break;
        case UIInterfaceOrientationUnknown:break;
    }
}

#pragma mark - CaseTaskDelegate

- (void)caseTask:(BARCaseTask *)task downloadProgress:(float)downloadProgress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressLabel.text = [NSString stringWithFormat:@"%.2f",downloadProgress];
        [self.progressLabel sizeToFit];
    });
}

- (void)caseTask:(BARCaseTask *)task taskResult:(NSDictionary *)taskResult error:(NSError *)error {
    
    [self removeCaseTasking:task];
    if (error) {
        
    }else {
        //下载完成后，可以从本地加载AR
        /*
         dispatch_async(dispatch_get_main_queue(), ^{
         [self.indicatorView startAnimating];
         self.renderVC.videoPreviewView.enabled = NO;
         [self unLoadCase];
         [self.renderVC changeToSystemCamera];
         __weak typeof(self) weakSelf = self;
         NSString *arPath = [taskResult objectForKey:@"path"];
         NSDictionary *queryresult = [taskResult objectForKey:@"queryresult"];
         NSDictionary *queryresultRet = [queryresult objectForKey:@"ret"];
         NSString *arTypeInServer = [queryresultRet objectForKey:@"ar_type"];
         [self.arController loadARFromFilePath:arPath arType:arTypeInServer success:^(NSString *arKey, kBARType arType) {
         [weakSelf handleARKey:arKey arType:arType];
         } failure:^{
         
         }];
         });*/
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.indicatorView stopAnimating];
        self.progressLabel.text = @"";
        [self.progressLabel removeFromSuperview];
        self.progressLabel = nil;
    });
}

- (void)caseTaskQueryArResourceSuccess:(BARCaseTask *)task {
}

- (void)caseTaskDealloc:(BARCaseTask *)task {
    [self removeCaseTasking:task];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.indicatorView stopAnimating];
        self.progressLabel.text = @"";
        [self.progressLabel removeFromSuperview];
        self.progressLabel = nil;
        
    });
}

- (void) removeCaseTasking:(BARCaseTask*) task {
    if(![task.arkey length]){
        return;
    }
    [task removeDelegate:self];
    @synchronized (self.tasks) {
        [self.tasks removeObjectForKey:task.arkey];
    }
}

@end

#endif
