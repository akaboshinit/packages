// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_avfoundation/FVPVideoPlayerPlugin.h"
#import "./include/video_player_avfoundation/FVPVideoPlayerPlugin_Test.h"

#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

#import "./include/video_player_avfoundation/FVPAVFactory.h"
#import "./include/video_player_avfoundation/FVPDisplayLink.h"
#import "./include/video_player_avfoundation/FVPFrameUpdater.h"
#import "./include/video_player_avfoundation/FVPNativeVideoViewFactory.h"
#import "./include/video_player_avfoundation/FVPTextureBasedVideoPlayer.h"
#import "./include/video_player_avfoundation/FVPVideoPlayer.h"
// Relative path is needed for messages.g.h. See
// https://github.com/flutter/packages/pull/6675/#discussion_r1591210702
#import "./include/video_player_avfoundation/messages.g.h"

#if !__has_feature(objc_arc)
#error Code Requires ARC.
#endif

/// Non-test implementation of the diplay link factory.
@interface FVPDefaultDisplayLinkFactory : NSObject <FVPDisplayLinkFactory>
@end

@implementation FVPDefaultDisplayLinkFactory
- (NSObject<FVPDisplayLink> *)displayLinkWithRegistrar:(id<FlutterPluginRegistrar>)registrar
                                              callback:(void (^)(void))callback {
#if TARGET_OS_IOS
  return [[FVPCADisplayLink alloc] initWithRegistrar:registrar callback:callback];
#else
  if (@available(macOS 14.0, *)) {
    return [[FVPCADisplayLink alloc] initWithRegistrar:registrar callback:callback];
  }
  return [[FVPCoreVideoDisplayLink alloc] initWithRegistrar:registrar callback:callback];
#endif
}

@end

#pragma mark -

@interface FVPVideoPlayerPlugin ()
@property(readonly, weak, nonatomic) NSObject<FlutterTextureRegistry> *registry;
@property(readonly, weak, nonatomic) NSObject<FlutterBinaryMessenger> *messenger;
@property(readonly, strong, nonatomic) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, strong) id<FVPDisplayLinkFactory> displayLinkFactory;
@property(nonatomic, strong) id<FVPAVFactory> avFactory;
@property(nonatomic, strong) NSObject<FVPViewProvider> *viewProvider;
// TODO(stuartmorgan): Decouple identifiers for platform views and texture views.
@property(nonatomic, assign) int64_t nextNonTexturePlayerIdentifier;
@end

@implementation FVPVideoPlayerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FVPVideoPlayerPlugin *instance = [[FVPVideoPlayerPlugin alloc] initWithRegistrar:registrar];
  [registrar publish:instance];
  FVPNativeVideoViewFactory *factory = [[FVPNativeVideoViewFactory alloc]
               initWithMessenger:registrar.messenger
      playerByIdentifierProvider:^FVPVideoPlayer *(NSNumber *playerIdentifier) {
        return instance->_playersByIdentifier[playerIdentifier];
      }];
  [registrar registerViewFactory:factory withId:@"plugins.flutter.dev/video_player_ios"];
  SetUpFVPAVFoundationVideoPlayerApi(registrar.messenger, instance);
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  return [self initWithAVFactory:[[FVPDefaultAVFactory alloc] init]
              displayLinkFactory:[[FVPDefaultDisplayLinkFactory alloc] init]
                    viewProvider:[[FVPDefaultViewProvider alloc] initWithRegistrar:registrar]
                       registrar:registrar];
}

- (instancetype)initWithAVFactory:(id<FVPAVFactory>)avFactory
               displayLinkFactory:(id<FVPDisplayLinkFactory>)displayLinkFactory
                     viewProvider:(NSObject<FVPViewProvider> *)viewProvider
                        registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = [registrar textures];
  _messenger = [registrar messenger];
  _registrar = registrar;
  _viewProvider = viewProvider;
  _displayLinkFactory = displayLinkFactory ?: [[FVPDefaultDisplayLinkFactory alloc] init];
  _avFactory = avFactory ?: [[FVPDefaultAVFactory alloc] init];
  _viewProvider = viewProvider ?: [[FVPDefaultViewProvider alloc] initWithRegistrar:registrar];
  _playersByIdentifier = [NSMutableDictionary dictionaryWithCapacity:1];
  // Initialized to a high number to avoid collisions with texture identifiers (which are generated
  // separately).
  _nextNonTexturePlayerIdentifier = INT_MAX;
  return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [self.playersByIdentifier.allValues
      makeObjectsPerformSelector:@selector(disposeSansEventChannel)];
  [self.playersByIdentifier removeAllObjects];
  SetUpFVPAVFoundationVideoPlayerApi(registrar.messenger, nil);
}

- (int64_t)onPlayerSetup:(FVPVideoPlayer *)player {
  FVPTextureBasedVideoPlayer *textureBasedPlayer =
      [player isKindOfClass:[FVPTextureBasedVideoPlayer class]]
          ? (FVPTextureBasedVideoPlayer *)player
          : nil;

  int64_t playerIdentifier;
  if (textureBasedPlayer) {
    playerIdentifier = [self.registry registerTexture:textureBasedPlayer];
    [textureBasedPlayer setTextureIdentifier:playerIdentifier];
  } else {
    playerIdentifier = self.nextNonTexturePlayerIdentifier--;
  }

  NSObject<FlutterBinaryMessenger> *messenger = self.messenger;
  NSString *channelSuffix = [NSString stringWithFormat:@"%lld", playerIdentifier];
  // Set up the player-specific API handler, and its onDispose unregistration.
  SetUpFVPVideoPlayerInstanceApiWithSuffix(messenger, player, channelSuffix);
  __weak typeof(self) weakSelf = self;
  BOOL isTextureBased = textureBasedPlayer != nil;
  player.onDisposed = ^() {
    SetUpFVPVideoPlayerInstanceApiWithSuffix(messenger, nil, channelSuffix);
    if (isTextureBased) {
      [weakSelf.registry unregisterTexture:playerIdentifier];
    }
  };
  // Set up the event channel.
  FlutterEventChannel *eventChannel = [FlutterEventChannel
      eventChannelWithName:[NSString stringWithFormat:@"flutter.io/videoPlayer/videoEvents%@",
                                                      channelSuffix]
           binaryMessenger:messenger];
  [eventChannel setStreamHandler:player];
  player.eventChannel = eventChannel;

  self.playersByIdentifier[@(playerIdentifier)] = player;

  // Ensure that the first frame is drawn once available, even if the video isn't played, since
  // the engine is now expecting the texture to be populated.
  [textureBasedPlayer expectFrame];

  return playerIdentifier;
}

// This function, although slightly modified, is also in camera_avfoundation.
// Both need to do the same thing and run on the same thread (for example main thread).
// Do not overwrite PlayAndRecord with Playback which causes inability to record
// audio, do not overwrite all options.
// Only change category if it is considered an upgrade which means it can only enable
// ability to play in silent mode or ability to record audio but never disables it,
// that could affect other plugins which depend on this global state. Only change
// category or options if there is change to prevent unnecessary lags and silence.
#if TARGET_OS_IOS
static void upgradeAudioSessionCategory(AVAudioSessionCategory requestedCategory,
                                        AVAudioSessionCategoryOptions options,
                                        AVAudioSessionCategoryOptions clearOptions) {
  NSSet *playCategories = [NSSet
      setWithObjects:AVAudioSessionCategoryPlayback, AVAudioSessionCategoryPlayAndRecord, nil];
  NSSet *recordCategories =
      [NSSet setWithObjects:AVAudioSessionCategoryRecord, AVAudioSessionCategoryPlayAndRecord, nil];
  NSSet *requiredCategories =
      [NSSet setWithObjects:requestedCategory, AVAudioSession.sharedInstance.category, nil];
  BOOL requiresPlay = [requiredCategories intersectsSet:playCategories];
  BOOL requiresRecord = [requiredCategories intersectsSet:recordCategories];
  if (requiresPlay && requiresRecord) {
    requestedCategory = AVAudioSessionCategoryPlayAndRecord;
  } else if (requiresPlay) {
    requestedCategory = AVAudioSessionCategoryPlayback;
  } else if (requiresRecord) {
    requestedCategory = AVAudioSessionCategoryRecord;
  }
  options = (AVAudioSession.sharedInstance.categoryOptions & ~clearOptions) | options;
  if ([requestedCategory isEqualToString:AVAudioSession.sharedInstance.category] &&
      options == AVAudioSession.sharedInstance.categoryOptions) {
    return;
  }
  [AVAudioSession.sharedInstance setCategory:requestedCategory withOptions:options error:nil];
}
#endif

- (void)initialize:(FlutterError *__autoreleasing *)error {
#if TARGET_OS_IOS
  // Allow audio playback when the Ring/Silent switch is set to silent
  upgradeAudioSessionCategory(AVAudioSessionCategoryPlayback, 0, 0);
#endif

  [self.playersByIdentifier.allValues makeObjectsPerformSelector:@selector(dispose)];
  [self.playersByIdentifier removeAllObjects];
}

- (nullable NSNumber *)createWithOptions:(nonnull FVPCreationOptions *)options
                                   error:(FlutterError **)error {
  BOOL textureBased = options.viewType == FVPPlatformVideoViewTypeTextureView;

  @try {
    FVPVideoPlayer *player = textureBased ? [self texturePlayerWithOptions:options]
                                          : [self platformViewPlayerWithOptions:options];

    if (player == nil) {
      *error = [FlutterError errorWithCode:@"video_player" message:@"not implemented" details:nil];
      return nil;
    }

    return @([self onPlayerSetup:player]);
  } @catch (NSException *exception) {
    *error = [FlutterError errorWithCode:@"video_player" message:exception.reason details:nil];
    return nil;
  }
}

- (nullable FVPTextureBasedVideoPlayer *)texturePlayerWithOptions:
    (nonnull FVPCreationOptions *)options {
  FVPFrameUpdater *frameUpdater = [[FVPFrameUpdater alloc] initWithRegistry:_registry];
  NSObject<FVPDisplayLink> *displayLink =
      [self.displayLinkFactory displayLinkWithRegistrar:_registrar
                                               callback:^() {
                                                 [frameUpdater displayLinkFired];
                                               }];

  if (options.asset) {
    NSString *assetPath = [self assetPathFromCreationOptions:options];
    return [[FVPTextureBasedVideoPlayer alloc] initWithAsset:assetPath
                                                frameUpdater:frameUpdater
                                                 displayLink:displayLink
                                                   avFactory:self.avFactory
                                                viewProvider:self.viewProvider];
  } else if (options.uri) {
    return [[FVPTextureBasedVideoPlayer alloc] initWithURL:[NSURL URLWithString:options.uri]
                                              frameUpdater:frameUpdater
                                               displayLink:displayLink
                                               httpHeaders:options.httpHeaders
                                                 avFactory:self.avFactory
                                              viewProvider:self.viewProvider];
  }

  return nil;
}

- (nullable FVPVideoPlayer *)platformViewPlayerWithOptions:(nonnull FVPCreationOptions *)options {
  // FVPVideoPlayer contains all required logic for platform views.
  if (options.asset) {
    NSString *assetPath = [self assetPathFromCreationOptions:options];
    return [[FVPVideoPlayer alloc] initWithAsset:assetPath
                                       avFactory:self.avFactory
                                    viewProvider:self.viewProvider];
  } else if (options.uri) {
    return [[FVPVideoPlayer alloc] initWithURL:[NSURL URLWithString:options.uri]
                                   httpHeaders:options.httpHeaders
                                     avFactory:self.avFactory
                                  viewProvider:self.viewProvider];
  }

  return nil;
}

- (NSString *)assetPathFromCreationOptions:(nonnull FVPCreationOptions *)options {
  NSString *assetPath;
  if (options.packageName) {
    assetPath = [self.registrar lookupKeyForAsset:options.asset fromPackage:options.packageName];
  } else {
    assetPath = [self.registrar lookupKeyForAsset:options.asset];
  }
  return assetPath;
}

- (void)disposePlayer:(NSInteger)playerIdentifier error:(FlutterError **)error {
  NSNumber *playerKey = @(playerIdentifier);
  FVPVideoPlayer *player = self.playersByIdentifier[playerKey];
  [self.playersByIdentifier removeObjectForKey:playerKey];
  [player dispose];
}

- (void)setLooping:(BOOL)isLooping forPlayer:(NSInteger)playerId error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByIdentifier[@(playerId)];
  if (!player) {
    *error = [FlutterError errorWithCode:@"video_player"
                                 message:@"No video player found"
                                 details:nil];
    return;
  }
  [player setLooping:isLooping error:error];
}

- (void)setVolume:(double)volume forPlayer:(NSInteger)playerId error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByIdentifier[@(playerId)];
  if (!player) {
    *error = [FlutterError errorWithCode:@"video_player"
                                 message:@"No video player found"
                                 details:nil];
    return;
  }
  [player setVolume:volume error:error];
}

- (void)setPlaybackSpeed:(double)speed forPlayer:(NSInteger)playerId error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByIdentifier[@(playerId)];
  if (!player) {
    *error = [FlutterError errorWithCode:@"video_player"
                                 message:@"No video player found"
                                 details:nil];
    return;
  }
  [player setPlaybackSpeed:speed error:error];
}

- (void)playPlayer:(NSInteger)playerId error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByIdentifier[@(playerId)];
  if (!player) {
    *error = [FlutterError errorWithCode:@"video_player"
                                 message:@"No video player found"
                                 details:nil];
    return;
  }
  [player playWithError:error];
}

- (nullable NSNumber *)positionForPlayer:(NSInteger)playerId error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByIdentifier[@(playerId)];
  if (!player) {
    *error = [FlutterError errorWithCode:@"video_player"
                                 message:@"No video player found"
                                 details:nil];
    return nil;
  }
  return [player position:error];
}

- (void)seekTo:(NSInteger)position forPlayer:(NSInteger)playerId completion:(void (^)(FlutterError *_Nullable))completion {
  FVPVideoPlayer *player = self.playersByIdentifier[@(playerId)];
  if (!player) {
    if (completion) {
      completion([FlutterError errorWithCode:@"video_player"
                                     message:@"No video player found"
                                     details:nil]);
    }
    return;
  }
  [player seekTo:position completion:completion];
}

- (void)pausePlayer:(NSInteger)playerId error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByIdentifier[@(playerId)];
  if (!player) {
    *error = [FlutterError errorWithCode:@"video_player"
                                 message:@"No video player found"
                                 details:nil];
    return;
  }
  [player pauseWithError:error];
}

- (void)setMixWithOthers:(BOOL)mixWithOthers
                   error:(FlutterError *_Nullable __autoreleasing *)error {
#if TARGET_OS_OSX
  // AVAudioSession doesn't exist on macOS, and audio always mixes, so just no-op.
#else
  if (mixWithOthers) {
    upgradeAudioSessionCategory(AVAudioSession.sharedInstance.category,
                                AVAudioSessionCategoryOptionMixWithOthers, 0);
  } else {
    upgradeAudioSessionCategory(AVAudioSession.sharedInstance.category, 0,
                                AVAudioSessionCategoryOptionMixWithOthers);
  }
#endif
}

- (nullable NSNumber *)isPictureInPictureSupported:
    (FlutterError *_Nullable __autoreleasing *_Nonnull)error {
  if (@available(macOS 10.15, *)) {
#if TARGET_OS_OSX
    return @(AVPictureInPictureController.isPictureInPictureSupported);
#else
    return @((BOOL) (AVPictureInPictureController.isPictureInPictureSupported &&
             [self configuredPictureInPictureBackgroundMode]));
#endif
  } else {
    return @NO;
  }
}

- (BOOL)configuredPictureInPictureBackgroundMode {
  id backgroundModes = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
  return
      [backgroundModes isKindOfClass:[NSArray class]] && [backgroundModes containsObject:@"audio"];
}

- (void)enterPipMode:(NSInteger)playerId completion:(void (^)(BOOL))completion {
  NSLog(@"VideoPlayerPip: enterPipMode called for playerId: %ld", (long)playerId);

  if (![self isPictureInPictureSupported:nil].boolValue) {
    NSLog(@"VideoPlayerPip: PiP not supported by the device");
    completion(NO);
    return;
  }

  // First try to find the player in our registry
  FVPVideoPlayer *player = self.playersByIdentifier[@(playerId)];
  AVPlayerLayer *playerLayer = nil;

  if (player) {
    NSLog(@"VideoPlayerPip: Found player in registry for ID: %ld", (long)playerId);

    // For texture-based players, get the playerLayer
    if ([player isKindOfClass:[FVPTextureBasedVideoPlayer class]]) {
      FVPTextureBasedVideoPlayer *texturePlayer = (FVPTextureBasedVideoPlayer *)player;
      playerLayer = texturePlayer.playerLayer;
    } else {
      // For platform view players, get the playerLayer
      playerLayer = player.playerLayer;
    }
  }

  // If we couldn't find the player or its layer, search the view hierarchy
  if (!playerLayer) {
    NSLog(@"VideoPlayerPip: Searching for AVPlayerLayer in view hierarchy for playerId: %ld", (long)playerId);
    playerLayer = [self findAVPlayerLayerForPlayerId:playerId];
  }

  if (!playerLayer) {
    NSLog(@"VideoPlayerPip: Could not find player layer for ID: %ld", (long)playerId);
    completion(NO);
    return;
  }

  NSLog(@"VideoPlayerPip: Found AVPlayerLayer: %@", playerLayer);

  // Check if player is ready
  AVPlayer *avPlayer = playerLayer.player;
  if (avPlayer) {
    NSLog(@"VideoPlayerPip: Player status: %ld, currentItem: %@, error: %@",
          (long)avPlayer.status,
          avPlayer.currentItem ? @"exists" : @"nil",
          avPlayer.error.localizedDescription ?: @"none");

    // Ensure the player is playing
    if (@available(iOS 10.0, macOS 10.12, *)) {
      if (avPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
        NSLog(@"VideoPlayerPip: Player is not currently playing, trying to play");
        [avPlayer play];
      }
    }

    // Wait a moment to ensure player is properly prepared
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (player) {
        [self continueEnterPipMode:player completion:completion];
      } else {
        // Create a temporary wrapper for the found playerLayer
        [self continueEnterPipModeWithPlayerLayer:playerLayer completion:completion];
      }
    });
  } else {
    NSLog(@"VideoPlayerPip: AVPlayerLayer has no player set");
    completion(NO);
  }
}

- (AVPlayerLayer *)findAVPlayerLayerForPlayerId:(NSInteger)playerId {
  NSLog(@"VideoPlayerPip: Finding AVPlayerLayer for playerId: %ld", (long)playerId);

  // Get the key window
  UIWindow *keyWindow = [self getKeyWindow];
  NSLog(@"VideoPlayerPip: keyWindow found: %@", keyWindow ? @"YES" : @"NO");

  if (keyWindow && keyWindow.rootViewController) {
    NSLog(@"VideoPlayerPip: Starting search from rootViewController: %@", NSStringFromClass([keyWindow.rootViewController class]));
    // Start with the root view and search recursively
    return [self findAVPlayerLayerInView:keyWindow.rootViewController.view depth:0];
  }

  NSLog(@"VideoPlayerPip: No rootViewController found");
  return nil;
}

- (UIWindow *)getKeyWindow {
#if TARGET_OS_IOS
  if (@available(iOS 13.0, *)) {
    NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
    NSArray<UIWindowScene *> *windowScenes = [scenes objectsPassingTest:^BOOL(UIScene *scene, BOOL *stop) {
      return [scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive;
    }].allObjects;

    NSLog(@"VideoPlayerPip: Found %lu active window scenes", (unsigned long)windowScenes.count);

    UIWindowScene *windowScene = windowScenes.firstObject;
    if (windowScene) {
      NSArray<UIWindow *> *windows = [windowScene.windows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIWindow *window, NSDictionary *bindings) {
        return window.isKeyWindow;
      }]];
      NSLog(@"VideoPlayerPip: Found %lu key windows in the first scene", (unsigned long)windows.count);
      return windows.firstObject;
    }
    return nil;
  } else {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    NSLog(@"VideoPlayerPip: Using legacy keyWindow approach: %@", window ? @"YES" : @"NO");
    return window;
  }
#else
  // macOS implementation would be different
  return nil;
#endif
}

- (AVPlayerLayer *)findAVPlayerLayerInView:(id)view depth:(NSInteger)depth {
#if TARGET_OS_IOS
  UIView *uiView = (UIView *)view;
  NSString *indentation = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
  NSString *className = NSStringFromClass([uiView class]);
  NSLog(@"%@VideoPlayerPip: Checking view: %@", indentation, className);

  // Check if this view's layer is an AVPlayerLayer
  if ([uiView.layer isKindOfClass:[AVPlayerLayer class]]) {
    AVPlayerLayer *playerLayer = (AVPlayerLayer *)uiView.layer;
    NSLog(@"%@VideoPlayerPip: Found AVPlayerLayer directly as view's layer", indentation);
    if (playerLayer.player) {
      NSLog(@"%@VideoPlayerPip: AVPlayerLayer has player: %@", indentation, playerLayer.player);
      return playerLayer;
    } else {
      NSLog(@"%@VideoPlayerPip: AVPlayerLayer has no player set", indentation);
    }
  }

  // Check for FVPPlayerView which has an AVPlayerLayer as its layer
  if ([className containsString:@"FVPPlayerView"]) {
    NSLog(@"%@VideoPlayerPip: Found FVPPlayerView", indentation);
    if ([uiView.layer isKindOfClass:[AVPlayerLayer class]]) {
      AVPlayerLayer *playerLayer = (AVPlayerLayer *)uiView.layer;
      NSLog(@"%@VideoPlayerPip: FVPPlayerView's layer is AVPlayerLayer", indentation);
      if (playerLayer.player) {
        NSLog(@"%@VideoPlayerPip: FVPPlayerView's AVPlayerLayer has player: %@", indentation, playerLayer.player);
      } else {
        NSLog(@"%@VideoPlayerPip: FVPPlayerView's AVPlayerLayer has no player set", indentation);
      }
      return playerLayer;
    } else {
      NSLog(@"%@VideoPlayerPip: FVPPlayerView's layer is not AVPlayerLayer: %@", indentation, NSStringFromClass([uiView.layer class]));
    }
  }

  // Check sublayers
  if (uiView.layer.sublayers) {
    NSLog(@"%@VideoPlayerPip: Checking %lu sublayers", indentation, (unsigned long)uiView.layer.sublayers.count);
    for (CALayer *sublayer in uiView.layer.sublayers) {
      if ([sublayer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayerLayer *playerLayer = (AVPlayerLayer *)sublayer;
        NSLog(@"%@VideoPlayerPip: Found AVPlayerLayer as a sublayer", indentation);
        if (playerLayer.player) {
          NSLog(@"%@VideoPlayerPip: Sublayer AVPlayerLayer has player: %@", indentation, playerLayer.player);
          return playerLayer;
        } else {
          NSLog(@"%@VideoPlayerPip: Sublayer AVPlayerLayer has no player set", indentation);
        }
      }
    }
  }

  // Recursively check subviews
  NSLog(@"%@VideoPlayerPip: Checking %lu subviews", indentation, (unsigned long)uiView.subviews.count);
  for (UIView *subview in uiView.subviews) {
    AVPlayerLayer *layer = [self findAVPlayerLayerInView:subview depth:depth + 1];
    if (layer) {
      return layer;
    }
  }
#endif

  return nil;
}

- (void)continueEnterPipMode:(FVPVideoPlayer *)player completion:(void (^)(BOOL))completion {
  // Ensure PiP controller is set up
  [player setUpPictureInPictureController];

  AVPictureInPictureController *pipController = player.pictureInPictureController;

  if (@available(iOS 14.0, macOS 10.15, *)) {
    if (pipController) {
      NSLog(@"VideoPlayerPip: PiP controller exists: %@", pipController);
      NSLog(@"VideoPlayerPip: PiP controller delegate: %@", pipController.delegate);
      NSLog(@"VideoPlayerPip: PiP controller isPictureInPicturePossible: %@", pipController.isPictureInPicturePossible ? @"YES" : @"NO");
      NSLog(@"VideoPlayerPip: PiP controller isPictureInPictureActive: %@", pipController.isPictureInPictureActive ? @"YES" : @"NO");
      NSLog(@"VideoPlayerPip: Background mode configured: %@", [self configuredPictureInPictureBackgroundMode] ? @"YES" : @"NO");

      // Enable PiP to start from inline (foreground)
#if TARGET_OS_IOS
      if (@available(iOS 14.2, *)) {
        NSLog(@"VideoPlayerPip: Setting canStartPictureInPictureAutomaticallyFromInline to true");
        pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
      }

      // Allow PiP during interactive playback
      if (@available(iOS 15.0, *)) {
        NSLog(@"VideoPlayerPip: Setting requiresLinearPlayback to false");
        pipController.requiresLinearPlayback = NO;
      }
#endif

      // Check if PiP is possible before starting
      if (!pipController.isPictureInPicturePossible) {
        NSLog(@"VideoPlayerPip: WARNING - isPictureInPicturePossible is false, waiting...");
        // Wait a bit for the player to be ready
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          NSLog(@"VideoPlayerPip: Checking isPictureInPicturePossible again: %@",
                pipController.isPictureInPicturePossible ? @"YES" : @"NO");
          if (pipController.isPictureInPicturePossible) {
            NSLog(@"VideoPlayerPip: Now possible, attempting to start PiP");
            [pipController startPictureInPicture];
          } else {
            NSLog(@"VideoPlayerPip: Still not possible, giving up");
            completion(NO);
          }
        });
      } else {
        // Start PiP
        NSLog(@"VideoPlayerPip: Attempting to start PiP");
        [pipController startPictureInPicture];
      }

      // Also try after a short delay as a fallback
#if TARGET_OS_IOS
      if (@available(iOS 15.0, *)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          if (!pipController.isPictureInPictureActive) {
            NSLog(@"VideoPlayerPip: Trying to start PiP again after delay (iOS 15+)");
            [pipController startPictureInPicture];
          }
        });
      }
#endif

      player.pictureInPictureStarted = YES;
      completion(YES);
    } else {
      NSLog(@"VideoPlayerPip: Cannot create PiP controller");
      completion(NO);
    }
  } else {
    NSLog(@"VideoPlayerPip: iOS/macOS version too old for PiP");
    completion(NO);
  }
}

- (void)continueEnterPipModeWithPlayerLayer:(AVPlayerLayer *)playerLayer completion:(void (^)(BOOL))completion {
  if (@available(macOS 10.15, *)) {
    if (AVPictureInPictureController.isPictureInPictureSupported && playerLayer && playerLayer.player) {
      NSLog(@"VideoPlayerPip: Creating AVPictureInPictureController with found playerLayer");

      AVPictureInPictureController *pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:playerLayer];

      if (pipController) {
        NSLog(@"VideoPlayerPip: PiP controller created successfully");

        // Enable PiP to start from inline (foreground)
        if (@available(iOS 14.2, *)) {
          NSLog(@"VideoPlayerPip: Setting canStartPictureInPictureAutomaticallyFromInline to true");
          pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        }

        // Allow PiP during interactive playback
        if (@available(iOS 15.0, *)) {
          NSLog(@"VideoPlayerPip: Setting requiresLinearPlayback to false");
          pipController.requiresLinearPlayback = NO;
        }

        // Start PiP
        NSLog(@"VideoPlayerPip: Attempting to start PiP");
        [pipController startPictureInPicture];

        // Also try after a short delay as a fallback
        if (@available(iOS 15.0, *)) {
          if (!pipController.isPictureInPictureActive) {
              NSLog(@"VideoPlayerPip: Trying to start PiP again after delay (iOS 15+)");
              [pipController startPictureInPicture];
          }
        }

        completion(YES);
      } else {
        NSLog(@"VideoPlayerPip: Failed to create PiP controller");
        completion(NO);
      }
    } else {
      NSLog(@"VideoPlayerPip: Cannot create PiP controller - either not supported or playerLayer/player is nil");
      completion(NO);
    }
  } else {
    NSLog(@"VideoPlayerPip: iOS/macOS version too old for PiP");
    completion(NO);
  }
}

- (void)startPictureInPicture:(FVPStartPictureInPictureMessage *)input
                        error:(FlutterError **)error {
  // Simply call enterPipMode directly
  [self enterPipMode:input.playerId completion:^(BOOL success) {
    if (!success && error) {
      *error = [FlutterError errorWithCode:@"video_player"
                                   message:@"Failed to start picture-in-picture"
                                   details:nil];
    }
  }];
}

- (void)stopPictureInPicture:(FVPStopPictureInPictureMessage *)input error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByIdentifier[@(input.playerId)];
  if (player) {
    player.pictureInPictureStarted = NO;
  }
}

@end
