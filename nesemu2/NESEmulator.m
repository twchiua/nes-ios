//
//  NESEmulator.m
//  NES
//
//  Created by Conrad Kramer on 4/26/15.
//  Copyright (c) 2015 Kramer Software Productions, LLC. All rights reserved.
//

#import "NESAvailability.h"

#import <UIKit/UIKit.h>
#import <libkern/OSAtomic.h>
#if METAL_ENABLED
#import <Metal/Metal.h>
#endif

#import "NESEmulator.h"

#include "emu.h"
#include "emu/events.h"
#include "log.h"
#include "config.h"

char configfilename[1024];
char *exepath = NULL;

static vars_t *vars_from_dictionary(NSDictionary *dictionary) {
    vars_t *vs = vars_create();
    [dictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        vars_add_var(vs, F_CONFIG, (char *)[key UTF8String], (char *)[obj UTF8String]);
    }];
    vs->changed = 0;
    return vs;
}

@interface NESEmulator ()

@property (nonatomic, weak) NSThread *thread;

- (void)log:(NSString *)line;

@end

__weak NESEmulator *emulator = nil;

static void emulator_log(char *str) {
    [emulator log:@(str)];
}

@implementation NESEmulator

@synthesize layer = _layer;

+ (void)load {
    log_sethook(emulator_log);
}

- (instancetype)init {
    return [self initWithConfigurationURL:nil dataDirectoryURL:nil];
}

- (instancetype)initWithConfigurationURL:(NSURL *)configurationURL dataDirectoryURL:(NSURL *)dataDirectoryURL {
    BOOL directory;
    NSParameterAssert(configurationURL && [[NSFileManager defaultManager] isWritableFileAtPath:configurationURL.path]);
    NSParameterAssert(dataDirectoryURL && [[NSFileManager defaultManager] fileExistsAtPath:dataDirectoryURL.path isDirectory:&directory] && directory);
    NSAssert(emulator == nil, @"Cannot instantiate multiple instances of NESEmulator");
    self = [super init];
    if (self) {
        emulator = self;
        
        strcpy(configfilename, [configurationURL fileSystemRepresentation]);
        vars_t *config = vars_load(configfilename);
        
        vars_t *paths = vars_from_dictionary(@{@"path.data": [[NSBundle bundleForClass:[self class]] pathForResource:@"data" ofType:nil],
                                               @"path.user": dataDirectoryURL.path});

        vars_merge(config, paths);
        vars_destroy(paths);
        
        vars_save(config, configfilename);
        vars_destroy(config);
        
        if (emu_init() != 0) {
            NSLog(@"%@: Failed to initialize nesemu2", NSStringFromClass([self class]));
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    emu_kill();
    strcpy(configfilename, "");
}

- (void)main {
    emu_mainloop();
}

- (void)loadRomAtURL:(NSURL *)romURL {
    if ([romURL isFileURL]) {
        emu_event(E_LOADROM, (char *)[romURL fileSystemRepresentation]);
    }
}

- (BOOL)isRunning {
    return (quit == 0 && _thread != nil);
}

- (void)start {
    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(main) object:nil];
    [thread setQualityOfService:NSQualityOfServiceUserInteractive];
    [thread setName:[[NSBundle bundleForClass:[self class]] bundleIdentifier]];
    [thread start];
    _thread = thread;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.player1 = NESControllerStateStart;
    });
}

- (void)stop {
    emu_event(E_QUIT, NULL);
}

- (BOOL)isPaused {
    return (running == 0);
}

- (void)pause {
    emu_event(E_PAUSE, NULL);
}

- (void)unpause {
    emu_event(E_UNPAUSE, NULL);
}

#if __has_include(<GameController/GameController.h>)
- (void)configureController:(GCController *)controller forPlayerAtIndex:(GCControllerPlayerIndex)index {
    if (index == GCControllerPlayerIndexUnset)
        return;
    
    __weak __typeof__(self) weakSelf = self;
    void (^set)(NESControllerState, NESControllerState) = ^(NESControllerState state, NESControllerState mask) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        NESControllerState *player = NULL;
        switch (index) {
            case GCControllerPlayerIndex1:
                player = &strongSelf->_player1;
                break;
            case GCControllerPlayerIndex2:
                player = &strongSelf->_player2;
                break;
            case GCControllerPlayerIndex3:
                player = &strongSelf->_player3;
                break;
            case GCControllerPlayerIndex4:
                player = &strongSelf->_player4;
                break;
            default:
                return;
        }
        
        OSAtomicAnd32(~mask, player);
        OSAtomicOr32(state, player);
    };
    
    [controller setControllerPausedHandler:^(GCController *controller) {
        set(NESControllerStateStart, NESControllerStateStart);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            set(0, NESControllerStateStart);
        });
    }];
    [controller.microGamepad setValueChangedHandler:^(GCMicroGamepad *gamepad, GCControllerElement *element) {
        GCControllerDirectionPad *dpad = gamepad.dpad;
        
        NESControllerState state = 0;
        state |= (dpad.up.pressed ? NESControllerStateUp : 0);
        state |= (dpad.down.pressed ? NESControllerStateDown : 0);
        state |= (dpad.left.pressed ? NESControllerStateLeft : 0);
        state |= (dpad.right.pressed ? NESControllerStateRight : 0);
        state |= (gamepad.buttonA.pressed ? NESControllerStateA : 0);
        state |= (gamepad.buttonX.pressed ? NESControllerStateB : 0);
        set(state, ~(NESControllerStateSelect | NESControllerStateStart));
    }];
    [controller.gamepad setValueChangedHandler:^(GCGamepad *gamepad, GCControllerElement *element) {
        GCControllerDirectionPad *dpad = gamepad.dpad;
        
        NESControllerState state = 0;
        state |= (dpad.up.pressed ? NESControllerStateUp : 0);
        state |= (dpad.down.pressed ? NESControllerStateDown : 0);
        state |= (dpad.left.pressed ? NESControllerStateLeft : 0);
        state |= (dpad.right.pressed ? NESControllerStateRight : 0);
        state |= (gamepad.buttonA.pressed | gamepad.buttonY.pressed ? NESControllerStateA : 0);
        state |= (gamepad.buttonB.pressed | gamepad.buttonX.pressed ? NESControllerStateB : 0);
        set(state, ~(NESControllerStateSelect | NESControllerStateStart));
    }];
    [controller setPlayerIndex:index];
}
#endif

- (void)log:(NSString *)line {

}

- (CALayer *)layer {
#if METAL_ENABLED
    if (!_layer) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device && [device supportsFeatureSet:MTLFeatureSet_iOS_GPUFamily1_v1]) {
            CAMetalLayer *metalLayer = [CAMetalLayer layer];
            metalLayer.device = device;
            metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            metalLayer.framebufferOnly = YES;
            _layer = metalLayer;
        }
    }
#endif
    
#if OPENGL_ENABLED
    if (!_layer) {
        EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        if (context) {
            CAEAGLLayer *eaglLayer = [CAEAGLLayer layer];
            eaglLayer.opaque = YES;
            eaglLayer.contentsScale = [[UIScreen mainScreen] scale];
            _layer = eaglLayer;
        }
    }
#endif
    
    if (!_layer) {
        _layer = [CALayer layer];
    }
    
    return _layer;
}

@end
