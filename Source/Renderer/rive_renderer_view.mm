#include "rive_renderer_view.hh"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#if TARGET_OS_IPHONE || TARGET_VISION_OS || TARGET_OS_TV
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

#import "RivePrivateHeaders.h"
#import <RenderContext.h>
#import <RenderContextManager.h>
// We manually need to provide this as our build-time config isn't shared with
// xcode.
#define WITH_RIVE_AUDIO
#include "rive/audio/audio_engine.hpp"

#if TARGET_OS_VISION
@implementation RiveMTKView
{
    id<CAMetalDrawable> _currentDrawable;
}

@synthesize enableSetNeedsDisplay;

@synthesize paused;

@synthesize sampleCount;

@synthesize depthStencilPixelFormat;

- (instancetype)initWithFrame:(CGRect)frameRect device:(id<MTLDevice>)device
{
    self = [super initWithFrame:frameRect];
    self.device = device;
    return self;
}

+ (Class)layerClass
{
    return [CAMetalLayer class];
}

- (nullable id<MTLDevice>)device
{
    return [self metalLayer].device;
}

- (void)setDevice:(nullable id<MTLDevice>)device
{
    [self metalLayer].device = device;
}

- (CAMetalLayer*)metalLayer
{
    return (CAMetalLayer*)self.layer;
}

- (void)setFramebufferOnly:(BOOL)framebufferOnly
{
    [self metalLayer].framebufferOnly = framebufferOnly;
}

- (BOOL)framebufferOnly
{
    return [self metalLayer].framebufferOnly;
}

- (void)setCurrentDrawable:(id<CAMetalDrawable> _Nullable)currentDrawable
{
    return;
}

- (nullable id<CAMetalDrawable>)currentDrawable
{
    if (_currentDrawable == nil)
    {
        _currentDrawable = [self metalLayer].nextDrawable;
    }
    return _currentDrawable;
}

- (void)setColorPixelFormat:(MTLPixelFormat)colorPixelFormat
{
    [self metalLayer].pixelFormat = colorPixelFormat;
}

- (MTLPixelFormat)colorPixelFormat
{
    return [self metalLayer].pixelFormat;
}

- (void)setDrawableSize:(CGSize)drawableSize
{
    [self metalLayer].drawableSize = drawableSize;
}

- (CGSize)drawableSize
{
    return [self metalLayer].drawableSize;
}

- (void)_updateDrawableSizeFromBounds
{
    CGSize newSize = self.bounds.size;
    newSize.width *= self.traitCollection.displayScale;
    newSize.height *= self.traitCollection.displayScale;
    self.drawableSize = newSize;
}

- (void)setContentScaleFactor:(CGFloat)contentScaleFactor
{
    [super setContentScaleFactor:contentScaleFactor];
    [self _updateDrawableSizeFromBounds];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self _updateDrawableSizeFromBounds];
}

- (void)setFrame:(CGRect)frame
{
    [super setFrame:frame];
    [self _updateDrawableSizeFromBounds];
}

- (void)setBounds:(CGRect)bounds
{
    [super setBounds:bounds];
    [self _updateDrawableSizeFromBounds];
}

// For some reason, when setNeedsDisplay is called, drawRect is not called
// But, we get a delegate callback when the layer should be displayed,
// so we'll just piggyback off of that and draw for now.
- (void)displayLayer:(CALayer*)layer
{
    _currentDrawable = [self metalLayer].nextDrawable;
    [self drawRect:self.bounds];
}

@end
#else
@implementation RiveMTKView
@end
#endif

@implementation RiveRendererView
{
    RenderContext* _renderContext;
    rive::Renderer* _renderer;
    dispatch_queue_t _renderQueue;
    CADisplayLink* _displayLink;
    NSMutableArray<id<CAMetalDrawable>>* _drawablePool;
    dispatch_semaphore_t _drawableSemaphore;
    NSLock* _drawableLock;
}

- (void)didEnterBackground:(NSNotification*)notification
{
    auto engine = rive::AudioEngine::RuntimeEngine(false);
    if (engine != nil)
    {
        engine->stop();
    }
}

- (void)didEnterForeground:(NSNotification*)notification
{
    auto engine = rive::AudioEngine::RuntimeEngine(false);
    if (engine != nil)
    {
        engine->start();
    }
}

- (instancetype)initWithCoder:(NSCoder*)decoder
{
#if TARGET_OS_IPHONE || TARGET_OS_VISION || TARGET_OS_TV
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(didEnterBackground:)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(didEnterForeground:)
               name:UIApplicationWillEnterForegroundNotification
             object:nil];
#else
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(didEnterBackground:)
               name:NSApplicationDidResignActiveNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(didEnterForeground:)
               name:NSApplicationWillBecomeActiveNotification
             object:nil];
#endif
    self = [super initWithCoder:decoder];

    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frameRect
{
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(didEnterBackground:)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(didEnterForeground:)
               name:UIApplicationWillEnterForegroundNotification
             object:nil];
#else
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(didEnterBackground:)
               name:NSApplicationDidResignActiveNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(didEnterForeground:)
               name:NSApplicationWillBecomeActiveNotification
             object:nil];
#endif
    _renderQueue = dispatch_queue_create("com.rive.renderQueue", DISPATCH_QUEUE_SERIAL);
    _renderContext = [[RenderContextManager shared] getDefaultContext];
    assert(_renderContext);

    auto value = [super initWithFrame:frameRect
                               device:_renderContext.metalDevice];

    [self setDepthStencilPixelFormat:_renderContext.depthStencilPixelFormat];
    [self setColorPixelFormat:MTLPixelFormatBGRA8Unorm];
    [self setFramebufferOnly:_renderContext.framebufferOnly];
    [self setSampleCount:1];

    [self commonInit];

    return value;
}

- (void)commonInit 
{
    _renderQueue = dispatch_queue_create("com.rive.renderQueue", DISPATCH_QUEUE_SERIAL);
    _renderContext = [[RenderContextManager shared] getDefaultContext];
    assert(_renderContext);
    self.device = [_renderContext metalDevice];

    [self setDepthStencilPixelFormat:_renderContext.depthStencilPixelFormat];
    [self setColorPixelFormat:MTLPixelFormatBGRA8Unorm];
    [self setFramebufferOnly:_renderContext.framebufferOnly];
    [self setSampleCount:1];
    
    // Initialize drawable management
    _drawablePool = [NSMutableArray arrayWithCapacity:3];
    _drawableSemaphore = dispatch_semaphore_create(3);
    _drawableLock = [[NSLock alloc] init];
    
    // Disable automatic drawing
    self.enableSetNeedsDisplay = NO;
    self.paused = YES;
    
    // Set up display link
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)prefetchDrawables {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (int i = 0; i < 3; i++) {
            id<CAMetalDrawable> drawable = [self metalLayer].nextDrawable;
            if (drawable) {
                [_drawableLock lock];
                [_drawablePool addObject:drawable];
                [_drawableLock unlock];
            }
        }
    });
}

- (nullable id<CAMetalDrawable>)currentDrawable
{
    // Try to get a drawable from the pool first
    [_drawableLock lock];
    id<CAMetalDrawable> drawable = [_drawablePool firstObject];
    if (drawable) {
        [_drawablePool removeObjectAtIndex:0];
        [_drawableLock unlock];
        
        // Prefetch a new drawable to replace the one we just took
        dispatch_async(dispatch_get_main_queue(), ^{
            id<CAMetalDrawable> newDrawable = [self metalLayer].nextDrawable;
            if (newDrawable) {
                [_drawableLock lock];
                [_drawablePool addObject:newDrawable];
                [_drawableLock unlock];
            }
        });
        
        return drawable;
    }
    [_drawableLock unlock];
    
    // If pool is empty, try to get a new drawable with a short timeout
    __block id<CAMetalDrawable> newDrawable = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        newDrawable = [self metalLayer].nextDrawable;
        dispatch_semaphore_signal(semaphore);
    });
    
    // Wait with a very short timeout
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC)) == 0) {
        return newDrawable;
    }
    
    return nil;
}

- (void)startAnimation 
{
    // Prefetch drawables before starting animation
    [self prefetchDrawables];
    _displayLink.paused = NO;
}

- (void)stopAnimation 
{
    _displayLink.paused = YES;
    
    // Clear the drawable pool
    [_drawableLock lock];
    [_drawablePool removeAllObjects];
    [_drawableLock unlock];
}

- (void)handleDisplayLink:(CADisplayLink*)displayLink 
{
    // Check if we have drawables available before dispatching
    if (_drawablePool.count > 0) {
        dispatch_async(_renderQueue, ^{
            [self drawInRect:self.bounds withCompletion:NULL];
        });
    }
}

- (void)drawInRect:(CGRect)rect
    withCompletion:(_Nullable MTLCommandBufferHandler)completionHandler
{
    if ([NSThread isMainThread]) {
        return; // Don't draw on main thread
    }

    CGFloat scale = -1;
#if TARGET_OS_IPHONE
    scale = self.traitCollection.displayScale;
#else
    scale = self.window.backingScaleFactor;
#endif

    if ([_renderContext canDrawInRect:rect
                        drawableSize:self.drawableSize
                               scale:scale] == NO)
    {
        return;
    }

    id<CAMetalDrawable> drawable = [self currentDrawable];
    if (!drawable) {
        return;
    }

    _renderer = [_renderContext beginFrame:self];
    if (_renderer != nil)
    {
        _renderer->save();
        [self drawRive:rect size:self.drawableSize];
        _renderer->restore();
        
        [_renderContext endFrame:self withCompletion:^(id<MTLCommandBuffer> buffer) {
            if (completionHandler) {
                completionHandler(buffer);
            }
        }];
    }
    
    _renderer = nil;
}

- (void)drawRect:(CGRect)rect
{
    // Do nothing - we handle drawing via display link
}

- (void)dealloc 
{
    [self stopAnimation];
    [_displayLink invalidate];
    _displayLink = nil;
    _drawableLock = nil;
    _drawablePool = nil;
}

- (void)alignWithRect:(CGRect)rect
          contentRect:(CGRect)contentRect
            alignment:(RiveAlignment)alignment
                  fit:(RiveFit)fit
{
    // Uses 1 as the scale factor since that is equivalent to the c++ default
    // parameter.
    [self alignWithRect:rect
            contentRect:contentRect
              alignment:alignment
                    fit:fit
            scaleFactor:1];
}

- (void)alignWithRect:(CGRect)rect
          contentRect:(CGRect)contentRect
            alignment:(RiveAlignment)alignment
                  fit:(RiveFit)fit
          scaleFactor:(CGFloat)scaleFactor
{
    rive::AABB frame(rect.origin.x,
                     rect.origin.y,
                     rect.size.width + rect.origin.x,
                     rect.size.height + rect.origin.y);

    rive::AABB content(contentRect.origin.x,
                       contentRect.origin.y,
                       contentRect.size.width + contentRect.origin.x,
                       contentRect.size.height + contentRect.origin.y);

    auto riveFit = [self riveFit:fit];
    auto riveAlignment = [self riveAlignment:alignment];

    _renderer->align(riveFit, riveAlignment, frame, content, scaleFactor);
}
- (void)save
{
    assert(_renderer != nil);
    _renderer->save();
}

- (void)restore
{
    assert(_renderer != nil);
    _renderer->restore();
}

- (void)transform:(float)xx
               xy:(float)xy
               yx:(float)yx
               yy:(float)yy
               tx:(float)tx
               ty:(float)ty
{
    assert(_renderer != nil);
    _renderer->transform(rive::Mat2D{xx, xy, yx, yy, tx, ty});
}

- (void)drawWithArtboard:(RiveArtboard*)artboard
{
    assert(_renderer != nil);
    [artboard artboardInstance]->draw(_renderer);
}

- (void)drawRive:(CGRect)rect size:(CGSize)size
{
    // Intended to be overridden.
}

- (bool)isPaused
{
    return true;
}

- (rive::Fit)riveFit:(RiveFit)fit
{
    rive::Fit riveFit;

    switch (fit)
    {
        case fill:
            riveFit = rive::Fit::fill;
            break;
        case contain:
            riveFit = rive::Fit::contain;
            break;
        case cover:
            riveFit = rive::Fit::cover;
            break;
        case fitHeight:
            riveFit = rive::Fit::fitHeight;
            break;
        case fitWidth:
            riveFit = rive::Fit::fitWidth;
            break;
        case scaleDown:
            riveFit = rive::Fit::scaleDown;
            break;
        case layout:
            riveFit = rive::Fit::layout;
            break;
        case noFit:
            riveFit = rive::Fit::none;
            break;
    }

    return riveFit;
}

- (rive::Alignment)riveAlignment:(RiveAlignment)alignment
{
    rive::Alignment riveAlignment = rive::Alignment::center;

    switch (alignment)
    {
        case topLeft:
            riveAlignment = rive::Alignment::topLeft;
            break;
        case topCenter:
            riveAlignment = rive::Alignment::topCenter;
            break;
        case topRight:
            riveAlignment = rive::Alignment::topRight;
            break;
        case centerLeft:
            riveAlignment = rive::Alignment::centerLeft;
            break;
        case center:
            riveAlignment = rive::Alignment::center;
            break;
        case centerRight:
            riveAlignment = rive::Alignment::centerRight;
            break;
        case bottomLeft:
            riveAlignment = rive::Alignment::bottomLeft;
            break;
        case bottomCenter:
            riveAlignment = rive::Alignment::bottomCenter;
            break;
        case bottomRight:
            riveAlignment = rive::Alignment::bottomRight;
            break;
    }

    return riveAlignment;
}

- (CGPoint)artboardLocationFromTouchLocation:(CGPoint)touchLocation
                                  inArtboard:(CGRect)artboardRect
                                         fit:(RiveFit)fit
                                   alignment:(RiveAlignment)alignment
{
    // Note, we've offset the frame by the frame.origin before
    // but in testing our touch location seems to already take this into account
    rive::AABB frame(0, 0, self.frame.size.width, self.frame.size.height);

    rive::AABB content(artboardRect.origin.x,
                       artboardRect.origin.y,
                       artboardRect.size.width + artboardRect.origin.x,
                       artboardRect.size.height + artboardRect.origin.y);

    auto riveFit = [self riveFit:fit];
    auto riveAlignment = [self riveAlignment:alignment];
    auto sf = 1.0;
    if (riveFit == rive::Fit::layout)
    {
        sf = frame.width() / artboardRect.size.width;
    }
    rive::Mat2D forward =
        rive::computeAlignment(riveFit, riveAlignment, frame, content, sf);

    rive::Mat2D inverse = forward.invertOrIdentity();

    rive::Vec2D frameLocation(touchLocation.x, touchLocation.y);
    rive::Vec2D convertedLocation = inverse * frameLocation;

    return CGPointMake(convertedLocation.x, convertedLocation.y);
}

@end
