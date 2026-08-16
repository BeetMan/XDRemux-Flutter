#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface XDRemuxTracingMetadataDictionary : NSDictionary
@property(nonatomic, strong) NSDictionary *backing;
@property(nonatomic, strong) NSMutableArray<NSString *> *requestedKeys;
- (instancetype)initWithBacking:(NSDictionary *)backing;
@end

@implementation XDRemuxTracingMetadataDictionary
- (instancetype)initWithBacking:(NSDictionary *)backing {
    self = [super init];
    if (self) {
        _backing = [backing copy];
        _requestedKeys = [NSMutableArray array];
    }
    return self;
}
- (NSUInteger)count { return self.backing.count; }
- (NSEnumerator *)keyEnumerator { return self.backing.keyEnumerator; }
- (id)objectForKey:(id)key { return [self.backing objectForKey:key]; }
- (id)objectForKeyedSubscript:(id)key {
    [self.requestedKeys addObject:[key description] ?: @"<nil>"];
    return [self.backing objectForKeyedSubscript:key];
}
@end

static void ReportProducerStage(NSString *stage, size_t width, size_t height) {
    fprintf(
        stderr,
        "apple_style_scene_payload_probe stage=%s dimensions=%zux%zu\n",
        stage.UTF8String,
        width,
        height
    );
    fflush(stderr);
}

static id SendId(id object, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSMutableArray<NSDictionary *> *gMetalTrace;
static NSMutableDictionary<NSString *, NSValue *> *gMetalOriginals;

static IMP OriginalMetalIMP(SEL selector) {
    return [gMetalOriginals[NSStringFromSelector(selector)] pointerValue];
}

static int TraceMetalNoArgumentStatus(id object, SEL selector) {
    int status = ((int (*)(id, SEL))OriginalMetalIMP(selector))(object, selector);
    [gMetalTrace addObject:@{
        @"selector": NSStringFromSelector(selector),
        @"status": @(status),
    }];
    return status;
}

static void TraceMetalNoArgumentVoid(id object, SEL selector) {
    ((void (*)(id, SEL))OriginalMetalIMP(selector))(object, selector);
    [gMetalTrace addObject:@{
        @"selector": NSStringFromSelector(selector),
        @"status": @"void-return",
    }];
}

static int TraceMetalBoolStatus(id object, SEL selector, BOOL value) {
    int status = ((int (*)(id, SEL, BOOL))OriginalMetalIMP(selector))(
        object, selector, value
    );
    [gMetalTrace addObject:@{
        @"selector": NSStringFromSelector(selector),
        @"argument": @(value),
        @"status": @(status),
    }];
    return status;
}

static int TraceMetalTwoObjectsStatus(id object, SEL selector, id first, id second) {
    int status = ((int (*)(id, SEL, id, id))OriginalMetalIMP(selector))(
        object, selector, first, second
    );
    [gMetalTrace addObject:@{
        @"selector": NSStringFromSelector(selector),
        @"firstAvailable": @(first != nil),
        @"secondAvailable": @(second != nil),
        @"status": @(status),
    }];
    return status;
}

static int TraceMetalThreeObjectsStatus(
    id object, SEL selector, id first, id second, id third
) {
    int status = ((int (*)(id, SEL, id, id, id))OriginalMetalIMP(selector))(
        object, selector, first, second, third
    );
    [gMetalTrace addObject:@{
        @"selector": NSStringFromSelector(selector),
        @"firstAvailable": @(first != nil),
        @"secondAvailable": @(second != nil),
        @"thirdAvailable": @(third != nil),
        @"status": @(status),
    }];
    return status;
}

static int TraceMetalFourObjectsStatus(
    id object, SEL selector, id first, id second, id third, id fourth
) {
    int status = ((int (*)(id, SEL, id, id, id, id))OriginalMetalIMP(selector))(
        object, selector, first, second, third, fourth
    );
    [gMetalTrace addObject:@{
        @"selector": NSStringFromSelector(selector),
        @"firstAvailable": @(first != nil),
        @"secondAvailable": @(second != nil),
        @"thirdAvailable": @(third != nil),
        @"fourthAvailable": @(fourth != nil),
        @"status": @(status),
    }];
    return status;
}

static void InstallMetalTraceHooks(Class cls) {
    gMetalTrace = [NSMutableArray array];
    gMetalOriginals = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSValue *> *hooks = @{
        @"process": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_updateColorManagementForInputs": [NSValue valueWithPointer:TraceMetalNoArgumentVoid],
        @"_convertLinearYCbCrToRGB:inputChromaTexture:outputRGBTexture:":
            [NSValue valueWithPointer:TraceMetalThreeObjectsStatus],
        @"_setupStatsAndRenderParamBuffer": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_populateStaticRenderParametersFromTuning:inputStatisticsByStatsKey:":
            [NSValue valueWithPointer:TraceMetalTwoObjectsStatus],
        @"_runImageReductionAndUpdateBaseGain:": [NSValue valueWithPointer:TraceMetalBoolStatus],
        @"_calculateHistogramStatsWithImageTexture:linearImageTexture:personMaskTexture:skinMaskTexture:":
            [NSValue valueWithPointer:TraceMetalFourObjectsStatus],
        @"_updateRenderPipelineConfigForInputs": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_calculateDynamicRenderParameters": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_createGuideImage": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_processSegmentationMasks": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_processLTMGainMap": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_upsampleLightMap": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_applyFinalRendering": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_encodeLinear": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
        @"_releaseIntermediateResources": [NSValue valueWithPointer:TraceMetalNoArgumentStatus],
    };
    [hooks enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSValue *replacement, BOOL *stop) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
        if (!method) return;
        gMetalOriginals[name] = [NSValue valueWithPointer:method_getImplementation(method)];
        method_setImplementation(method, [replacement pointerValue]);
    }];
}

static void RestoreMetalTraceHooks(Class cls) {
    [gMetalOriginals enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSValue *original, BOOL *stop) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
        if (method) method_setImplementation(method, [original pointerValue]);
    }];
}

static int SendStatus(id object, SEL selector) {
    return ((int (*)(id, SEL))objc_msgSend)(object, selector);
}

static void SendObject(id object, SEL selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static void SendPixelBuffer(id object, SEL selector, CVPixelBufferRef value) {
    ((void (*)(id, SEL, CVPixelBufferRef))objc_msgSend)(object, selector, value);
}

static id DynamicObjectConstant(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (!symbol) {
        return nil;
    }
    return *(__unsafe_unretained id *)symbol;
}

static NSData *IdentityGlobalToneCurve(void) {
    NSMutableData *data = [NSMutableData dataWithCapacity:516];
    uint16_t count = CFSwapInt16HostToLittle(257);
    [data appendBytes:&count length:sizeof(count)];
    for (NSUInteger index = 0; index < 256; index++) {
        double linear = (double)index / 255.0;
        double encoded = linear <= 0.0031308
            ? linear * 12.92
            : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
        uint16_t value = (uint16_t)llround(fmin(fmax(encoded, 0.0), 1.0) * 65534.0);
        if (index == 0) value = 0;
        if (index == 255) value = 65534;
        value = CFSwapInt16HostToLittle(value);
        [data appendBytes:&value length:sizeof(value)];
    }
    uint16_t endpoint = CFSwapInt16HostToLittle(65534);
    [data appendBytes:&endpoint length:sizeof(endpoint)];
    return data;
}

static CVPixelBufferRef CreatePixelBuffer(size_t width, size_t height, OSType format) {
    NSDictionary *attributes = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        (__bridge CFDictionaryRef)attributes,
        &buffer
    );
    return status == kCVReturnSuccess ? buffer : NULL;
}

static void AttachLinearDisplayP3(CVPixelBufferRef buffer) {
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_P3_D65,
        kCVAttachmentMode_ShouldPropagate
    );
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_Linear,
        kCVAttachmentMode_ShouldPropagate
    );
}

static void FillHalfRGBA(CVPixelBufferRef buffer, BOOL expanded) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    for (size_t y = 0; y < height; y++) {
        uint16_t *row = (uint16_t *)(base + y * rowBytes);
        for (size_t x = 0; x < width; x++) {
            float xf = width > 1 ? (float)x / (float)(width - 1) : 0;
            float yf = height > 1 ? (float)y / (float)(height - 1) : 0;
            float scale = expanded ? 1.5f : 0.75f;
            float values[4] = {
                scale * (0.05f + 0.80f * xf),
                scale * (0.05f + 0.80f * yf),
                scale * (0.05f + 0.40f * (xf + yf)),
                1.0f,
            };
            for (size_t component = 0; component < 4; component++) {
                __fp16 half = (__fp16)values[component];
                memcpy(&row[x * 4 + component], &half, sizeof(half));
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

static void FillUnorm16RGBA(CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    for (size_t y = 0; y < height; y++) {
        uint16_t *row = (uint16_t *)(base + y * rowBytes);
        for (size_t x = 0; x < width; x++) {
            double xf = width > 1 ? (double)x / (double)(width - 1) : 0;
            double yf = height > 1 ? (double)y / (double)(height - 1) : 0;
            double values[4] = {
                0.05 + 0.80 * xf,
                0.05 + 0.80 * yf,
                0.05 + 0.40 * (xf + yf),
                1.0,
            };
            for (size_t component = 0; component < 4; component++) {
                row[x * 4 + component] = (uint16_t)llround(
                    fmin(fmax(values[component], 0.0), 1.0) * 65535.0
                );
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

static NSDictionary *HalfPlaneSummary(CVPixelBufferRef buffer) {
    if (!buffer) return @{ @"available": @NO };
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    double minimum = INFINITY;
    double maximum = -INFINITY;
    double sum = 0;
    NSUInteger finiteCount = 0;
    for (size_t y = 0; y < height; y++) {
        const uint16_t *row = (const uint16_t *)(base + y * rowBytes);
        for (size_t x = 0; x < width; x++) {
            __fp16 half;
            memcpy(&half, &row[x], sizeof(half));
            double value = (double)half;
            if (!isfinite(value)) continue;
            minimum = fmin(minimum, value);
            maximum = fmax(maximum, value);
            sum += value;
            finiteCount++;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return @{
        @"available": @YES,
        @"width": @(width),
        @"height": @(height),
        @"pixelFormat": @(CVPixelBufferGetPixelFormatType(buffer)),
        @"minimum": finiteCount ? @(minimum) : (id)[NSNull null],
        @"maximum": finiteCount ? @(maximum) : (id)[NSNull null],
        @"mean": finiteCount ? @(sum / (double)finiteCount) : (id)[NSNull null],
        @"finiteCount": @(finiteCount),
    };
}

static NSDictionary *TextureSummary(id texture) {
    if (!texture) return @{ @"available": @NO };
    SEL widthSelector = NSSelectorFromString(@"width");
    SEL heightSelector = NSSelectorFromString(@"height");
    SEL formatSelector = NSSelectorFromString(@"pixelFormat");
    return @{
        @"available": @YES,
        @"class": NSStringFromClass([texture class]),
        @"width": [texture respondsToSelector:widthSelector]
            ? @(((NSUInteger (*)(id, SEL))objc_msgSend)(texture, widthSelector))
            : (id)[NSNull null],
        @"height": [texture respondsToSelector:heightSelector]
            ? @(((NSUInteger (*)(id, SEL))objc_msgSend)(texture, heightSelector))
            : (id)[NSNull null],
        @"pixelFormat": [texture respondsToSelector:formatSelector]
            ? @(((NSUInteger (*)(id, SEL))objc_msgSend)(texture, formatSelector))
            : (id)[NSNull null],
    };
}

static NSDictionary *MetalRendererTextureSummary(id renderer) {
    id metalRenderer = renderer
        ? SendId(renderer, NSSelectorFromString(@"metalRenderer"))
        : nil;
    if (!metalRenderer) return @{ @"available": @NO };
    NSMutableDictionary *result = [@{ @"available": @YES } mutableCopy];
    Ivar internalTuningIvar = class_getInstanceVariable(
        [metalRenderer class], "_internalTuningParams"
    );
    id internalTuning = internalTuningIvar
        ? object_getIvar(metalRenderer, internalTuningIvar)
        : nil;
    result[@"internalTuningParameters"] = internalTuning
        ? @{
            @"available": @YES,
            @"class": NSStringFromClass([internalTuning class]),
            @"description": [internalTuning description] ?: @"",
        }
        : @{ @"available": @NO };
    for (NSString *selectorName in @[
        @"inputImageTexture",
        @"inputImageThumbnailTexture",
        @"inputLinearImageTexture",
        @"inputGlobalToneCurveTexture",
        @"outputSmallLightMapTexture",
        @"outputSmallLinearLightMapTexture",
        @"outputCodedLinearTexture",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        result[selectorName] = [metalRenderer respondsToSelector:selector]
            ? TextureSummary(SendId(metalRenderer, selector))
            : @{ @"available": @NO, @"selectorUnavailable": @YES };
    }
    for (NSString *selectorName in @[
        @"inputStyle",
        @"tuningParameters",
        @"tuningParameterVariant",
        @"outputImageStatistics",
        @"outputImageStatisticsExtended",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        id value = [metalRenderer respondsToSelector:selector]
            ? SendId(metalRenderer, selector)
            : nil;
        result[selectorName] = value
            ? @{
                @"available": @YES,
                @"class": NSStringFromClass([value class]),
                @"description": [value description] ?: @"",
            }
            : @{ @"available": @NO };
    }
    return result;
}

static BOOL FillPackedPixelBuffer(CVPixelBufferRef buffer, NSData *data, size_t bytesPerPixel) {
    if (!buffer || !data) return NO;
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const size_t packedRowBytes = width * bytesPerPixel;
    if (data.length != packedRowBytes * height) return NO;
    CVPixelBufferLockBaseAddress(buffer, 0);
    const size_t destinationRowBytes = CVPixelBufferGetBytesPerRow(buffer);
    uint8_t *destination = CVPixelBufferGetBaseAddress(buffer);
    const uint8_t *source = data.bytes;
    for (size_t row = 0; row < height; row++) {
        memcpy(
            destination + row * destinationRowBytes,
            source + row * packedRowBytes,
            packedRowBytes
        );
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return YES;
}

static NSData *PackedPixelBufferData(CVPixelBufferRef buffer, size_t bytesPerPixel) {
    if (!buffer) return nil;
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const size_t packedRowBytes = width * bytesPerPixel;
    NSMutableData *data = [NSMutableData dataWithLength:packedRowBytes * height];
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const size_t sourceRowBytes = CVPixelBufferGetBytesPerRow(buffer);
    const uint8_t *source = CVPixelBufferGetBaseAddress(buffer);
    uint8_t *destination = data.mutableBytes;
    for (size_t row = 0; row < height; row++) {
        memcpy(
            destination + row * packedRowBytes,
            source + row * sourceRowBytes,
            packedRowBytes
        );
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return data;
}

static CVPixelBufferRef MaskPixelBuffer(NSString *path, size_t width, size_t height) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return NULL;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    CVPixelBufferRef buffer = CreatePixelBuffer(
        width,
        height,
        kCVPixelFormatType_OneComponent8
    );
    if (!buffer || !FillPackedPixelBuffer(buffer, data, 1)) {
        if (buffer) CFRelease(buffer);
        return NULL;
    }
    return buffer;
}

static BOOL WriteData(NSData *data, NSString *path, NSString **failure) {
    NSError *error = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        if (failure) *failure = error.localizedDescription ?: @"unknown write error";
        return NO;
    }
    return YES;
}

static NSDictionary *RunPhotoDerivedProducer(NSString *requestPath) {
    NSError *error = nil;
    NSData *requestData = [NSData dataWithContentsOfFile:requestPath
                                                 options:NSDataReadingMappedIfSafe
                                                   error:&error];
    NSDictionary *request = requestData
        ? [NSJSONSerialization JSONObjectWithData:requestData options:0 error:&error]
        : nil;
    if (![request isKindOfClass:[NSDictionary class]]) {
        return @{
            @"status": @"invalid_request",
            @"error": error.localizedDescription ?: @"request root is not a dictionary",
        };
    }

    const size_t width = [request[@"width"] unsignedIntegerValue];
    const size_t height = [request[@"height"] unsignedIntegerValue];
    const size_t thumbnailWidth = request[@"thumbnailWidth"]
        ? [request[@"thumbnailWidth"] unsignedIntegerValue]
        : width;
    const size_t thumbnailHeight = request[@"thumbnailHeight"]
        ? [request[@"thumbnailHeight"] unsignedIntegerValue]
        : height;
    ReportProducerStage(@"request-decoded", width, height);
    NSString *tonePath = request[@"toneRGBAHalfPath"];
    NSString *thumbnailPath = request[@"thumbnailRGBAHalfPath"] ?: tonePath;
    NSString *linearPath = request[@"normalizedLinearRGBA16Path"];
    NSString *gtcPath = request[@"globalToneCurvePath"];
    NSString *outputDirectory = request[@"outputDirectory"];
    if (width < 2 || height < 2 || thumbnailWidth < 2 || thumbnailHeight < 2 ||
        !tonePath.length || !thumbnailPath.length || !linearPath.length ||
        !gtcPath.length || !outputDirectory.length) {
        return @{
            @"status": @"invalid_request",
            @"error": @"width, height, input paths, and outputDirectory are required",
        };
    }
    NSData *toneData = [NSData dataWithContentsOfFile:tonePath
                                              options:NSDataReadingMappedIfSafe
                                                error:&error];
    NSData *thumbnailData = [NSData dataWithContentsOfFile:thumbnailPath
                                                   options:NSDataReadingMappedIfSafe
                                                     error:&error];
    NSData *linearData = [NSData dataWithContentsOfFile:linearPath
                                                options:NSDataReadingMappedIfSafe
                                                  error:&error];
    NSData *gtc = [NSData dataWithContentsOfFile:gtcPath
                                         options:NSDataReadingMappedIfSafe
                                           error:&error];
    if (toneData.length != width * height * 8 ||
        thumbnailData.length != thumbnailWidth * thumbnailHeight * 8 ||
        linearData.length != width * height * 8 || gtc.length != 516) {
        return @{
            @"status": @"invalid_request",
            @"error": @"tone/linear rasters or 516-byte GTC have an unexpected byte count",
            @"toneBytes": @(toneData.length),
            @"thumbnailBytes": @(thumbnailData.length),
            @"linearBytes": @(linearData.length),
            @"gtcBytes": @(gtc.length),
        };
    }
    if (![[NSFileManager defaultManager] createDirectoryAtPath:outputDirectory
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:&error]) {
        return @{
            @"status": @"output_directory_failed",
            @"error": error.localizedDescription ?: @"cannot create output directory",
        };
    }
    ReportProducerStage(@"inputs-loaded", width, height);

    Class rendererClass = NSClassFromString(@"CMISmartStylePixelBufferRendererV1");
    Class styleClass = NSClassFromString(@"CMISmartStyleV1");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!rendererClass || !styleClass || !queue) {
        return @{
            @"status": @"unavailable",
            @"rendererAvailable": @(rendererClass != Nil),
            @"styleAvailable": @(styleClass != Nil),
            @"metalAvailable": @(queue != nil),
        };
    }

    CVPixelBufferRef tone = CreatePixelBuffer(width, height, kCVPixelFormatType_64RGBAHalf);
    CVPixelBufferRef thumbnail = CreatePixelBuffer(
        thumbnailWidth,
        thumbnailHeight,
        kCVPixelFormatType_64RGBAHalf
    );
    CVPixelBufferRef linear = CreatePixelBuffer(width, height, kCVPixelFormatType_64RGBALE);
    CVPixelBufferRef output = CreatePixelBuffer(width, height, kCVPixelFormatType_64RGBAHalf);
    CVPixelBufferRef small = CreatePixelBuffer(32, 32, kCVPixelFormatType_OneComponent16Half);
    CVPixelBufferRef smallLinear = CreatePixelBuffer(32, 32, kCVPixelFormatType_OneComponent16Half);
    CVPixelBufferRef codedLinear = CreatePixelBuffer(width, height, kCVPixelFormatType_64RGBAHalf);
    CVPixelBufferRef person = MaskPixelBuffer(request[@"personMaskPath"], width, height);
    CVPixelBufferRef skin = MaskPixelBuffer(request[@"skinMaskPath"], width, height);
    CVPixelBufferRef sky = MaskPixelBuffer(request[@"skyMaskPath"], width, height);
    if (!tone || !thumbnail || !linear || !output || !small || !smallLinear || !codedLinear ||
        !FillPackedPixelBuffer(tone, toneData, 8) ||
        !FillPackedPixelBuffer(thumbnail, thumbnailData, 8) ||
        !FillPackedPixelBuffer(linear, linearData, 8)) {
        if (tone) CFRelease(tone);
        if (thumbnail) CFRelease(thumbnail);
        if (linear) CFRelease(linear);
        if (output) CFRelease(output);
        if (small) CFRelease(small);
        if (smallLinear) CFRelease(smallLinear);
        if (codedLinear) CFRelease(codedLinear);
        if (person) CFRelease(person);
        if (skin) CFRelease(skin);
        if (sky) CFRelease(sky);
        return @{ @"status": @"pixel_buffer_setup_failed" };
    }
    ReportProducerStage(@"pixel-buffers-ready", width, height);
    AttachLinearDisplayP3(tone);
    AttachLinearDisplayP3(thumbnail);
    AttachLinearDisplayP3(linear);

    id renderer = ((id (*)(id, SEL, id, id))objc_msgSend)(
        SendId((id)rendererClass, sel_registerName("alloc")),
        NSSelectorFromString(@"initWithOptionalMetalCommandQueue:allocator:"),
        queue,
        nil
    );
    int setupStatus = renderer ? SendStatus(renderer, NSSelectorFromString(@"setup")) : -1;
    ReportProducerStage(@"renderer-setup-returned", width, height);
    NSString *rendererTuningPath =
        @"/System/Library/PrivateFrameworks/CMImaging.framework/Versions/A/Resources/RendererTuning.plist";
    NSDictionary *rendererTuningDictionary = [NSDictionary dictionaryWithContentsOfFile:rendererTuningPath];
    Class rendererPlistClass = NSClassFromString(@"SmartStyleRendererPlist");
    id rendererTuning = rendererPlistClass
        ? SendId(SendId((id)rendererPlistClass, sel_registerName("alloc")), sel_registerName("init"))
        : nil;
    int rendererTuningReadStatus = rendererTuning && rendererTuningDictionary
        ? ((int (*)(id, SEL, id))objc_msgSend)(
            rendererTuning,
            NSSelectorFromString(@"readPlist:"),
            rendererTuningDictionary
        )
        : -1;
    id metalRenderer = renderer
        ? SendId(renderer, NSSelectorFromString(@"metalRenderer"))
        : nil;
    if (rendererTuningReadStatus == 0 && metalRenderer) {
        SendObject(metalRenderer, NSSelectorFromString(@"setTuningParameters:"), rendererTuning);
    }
    id defaultTuningVariant = DynamicObjectConstant("CMISmartStyleTuningParameterVariant_Default");
    if (renderer && defaultTuningVariant) {
        SendObject(renderer, NSSelectorFromString(@"setTuningParameterVariant:"), defaultTuningVariant);
    }

    id standardCast = DynamicObjectConstant("CMISmartStyleCastTypeStandard");
    id style = ((id (*)(id, SEL, id, float, float, float))objc_msgSend)(
        SendId((id)styleClass, sel_registerName("alloc")),
        NSSelectorFromString(@"initWithCastType:castIntensity:toneBias:colorBias:"),
        standardCast ?: @"Standard",
        1.0f,
        0.0f,
        0.0f
    );
    const float ltmRelativeBrightness = request[@"ltmRelativeBrightness"]
        ? [request[@"ltmRelativeBrightness"] floatValue]
        : 1.0f;
    const float encodingGain = request[@"encodingGain"]
        ? [request[@"encodingGain"] floatValue]
        : 1.0f;
    const NSInteger hrGainDownRatioQ12 = request[@"hrGainDownRatioQ12"]
        ? [request[@"hrGainDownRatioQ12"] integerValue]
        : (NSInteger)llround(fmax(encodingGain, 1.0f) * 4096.0f);
    const float brightnessValue = request[@"brightnessValue"]
        ? [request[@"brightnessValue"] floatValue]
        : 0.0f;
    const int sceneType = request[@"sceneType"]
        ? [request[@"sceneType"] intValue]
        : 0;
    const float personMasksValidHint = request[@"personMasksValidHint"]
        ? [request[@"personMasksValidHint"] floatValue]
        : (person ? 1.0f : -1.0f);
    const float faceBoost = request[@"faceBasedGlobalExposureBoostRatio"]
        ? [request[@"faceBasedGlobalExposureBoostRatio"] floatValue]
        : 1.0f;
    const unsigned int processingType = request[@"processingType"]
        ? [request[@"processingType"] unsignedIntValue]
        : 1u;

    id ltmKey = DynamicObjectConstant("kFigCaptureSampleBufferMetadata_LTMRelativeBrightness");
    id gainDownKey = DynamicObjectConstant("kFigCaptureStreamMetadata_HRGainDownRatio");
    id gtcKey = DynamicObjectConstant("kFigCaptureStreamMetadata_GlobalToneCurveLookUpTable");
    id brightnessKey = DynamicObjectConstant("kFigCaptureStreamMetadata_BrightnessValue");
    NSMutableDictionary *linearMetadata = [NSMutableDictionary dictionary];
    if (ltmKey) linearMetadata[ltmKey] = @(ltmRelativeBrightness);
    if (gainDownKey) linearMetadata[gainDownKey] = @(hrGainDownRatioQ12);
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    if (gtcKey) metadata[gtcKey] = gtc;
    if (brightnessKey) metadata[brightnessKey] = @(brightnessValue);
    NSMutableDictionary *statistics = [NSMutableDictionary dictionary];
    NSMutableDictionary *extendedStatistics = [NSMutableDictionary dictionary];
    NSMutableDictionary *codedMetadata = [NSMutableDictionary dictionary];

    if (renderer && setupStatus == 0) {
        SendPixelBuffer(renderer, NSSelectorFromString(@"setInputPixelBuffer:"), tone);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setInputThumbnailPixelBuffer:"), thumbnail);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setInputLinearPixelBuffer:"), linear);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setOutputPixelBuffer:"), output);
        SendObject(renderer, NSSelectorFromString(@"setInputMetadataDict:"), metadata);
        SendObject(renderer, NSSelectorFromString(@"setInputLinearMetadataDict:"), linearMetadata);
        SendObject(renderer, NSSelectorFromString(@"setInputStyle:"), style);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setOutputSmallLightMapPixelBuffer:"), small);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setOutputSmallLinearLightMapPixelBuffer:"), smallLinear);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setOutputCodedLinearPixelBuffer:"), codedLinear);
        SendObject(renderer, NSSelectorFromString(@"setOutputImageStatistics:"), statistics);
        SendObject(renderer, NSSelectorFromString(@"setOutputImageStatisticsExtended:"), extendedStatistics);
        SendObject(renderer, NSSelectorFromString(@"setOutputCodedLinearMetadata:"), codedMetadata);
        ((void (*)(id, SEL, int))objc_msgSend)(
            renderer, NSSelectorFromString(@"setSemanticStyleSceneType:"), sceneType
        );
        ((void (*)(id, SEL, float))objc_msgSend)(
            renderer, NSSelectorFromString(@"setPersonMasksValidHint:"), personMasksValidHint
        );
        if (metalRenderer &&
            [metalRenderer respondsToSelector:NSSelectorFromString(@"setFaceBasedGlobalExposureBoostRatio:")]) {
            ((void (*)(id, SEL, float))objc_msgSend)(
                metalRenderer,
                NSSelectorFromString(@"setFaceBasedGlobalExposureBoostRatio:"),
                faceBoost
            );
        }
        if (person) {
            SendPixelBuffer(renderer, NSSelectorFromString(@"setInputPersonMaskPixelBuffer:"), person);
            ((void (*)(id, SEL, CGRect))objc_msgSend)(
                renderer, NSSelectorFromString(@"setInputPersonMaskCropRect:"),
                CGRectMake(0, 0, width, height)
            );
        }
        if (skin) {
            SendPixelBuffer(renderer, NSSelectorFromString(@"setInputSkinMaskPixelBuffer:"), skin);
            ((void (*)(id, SEL, CGRect))objc_msgSend)(
                renderer, NSSelectorFromString(@"setInputSkinMaskCropRect:"),
                CGRectMake(0, 0, width, height)
            );
        }
        if (sky) {
            SendPixelBuffer(renderer, NSSelectorFromString(@"setInputSkyMaskPixelBuffer:"), sky);
            ((void (*)(id, SEL, CGRect))objc_msgSend)(
                renderer, NSSelectorFromString(@"setInputSkyMaskCropRect:"),
                CGRectMake(0, 0, width, height)
            );
        }
        ((void (*)(id, SEL, CGRect))objc_msgSend)(
            renderer,
            NSSelectorFromString(@"setStatsComputationRect:"),
            CGRectMake(0, 0, 1, 1)
        );
    }
    ReportProducerStage(@"renderer-inputs-bound", width, height);

    ReportProducerStage(@"prepare-begin", width, height);
    int prepareStatus = setupStatus == 0
        ? ((int (*)(id, SEL, unsigned int))objc_msgSend)(
            renderer, NSSelectorFromString(@"prepareToProcess:"), processingType
        )
        : -1;
    ReportProducerStage(@"prepare-returned", width, height);
    ReportProducerStage(@"process-begin", width, height);
    int processStatus = prepareStatus == 0
        ? SendStatus(renderer, NSSelectorFromString(@"process"))
        : -1;
    ReportProducerStage(@"process-returned", width, height);
    ReportProducerStage(@"finish-begin", width, height);
    int finishStatus = processStatus == 0
        ? SendStatus(renderer, NSSelectorFromString(@"finishProcessing"))
        : -1;
    ReportProducerStage(@"finish-returned", width, height);

    NSString *toneMapPath = [outputDirectory stringByAppendingPathComponent:@"small-light-map.f16le"];
    NSString *linearMapPath = [outputDirectory stringByAppendingPathComponent:@"small-linear-light-map.f16le"];
    NSString *codedLinearPath = [outputDirectory stringByAppendingPathComponent:@"coded-linear.rgba16f"];
    NSString *writeFailure = nil;
    BOOL writeSucceeded = setupStatus == 0 && prepareStatus == 0 &&
        processStatus == 0 && finishStatus == 0 &&
        WriteData(PackedPixelBufferData(small, 2), toneMapPath, &writeFailure) &&
        WriteData(PackedPixelBufferData(smallLinear, 2), linearMapPath, &writeFailure) &&
        WriteData(PackedPixelBufferData(codedLinear, 8), codedLinearPath, &writeFailure);
    ReportProducerStage(@"outputs-written", width, height);

    NSDictionary *result = @{
        @"schema": @"xdremux-native-photo-derived-style-scene-v1",
        @"status": writeSucceeded ? @"success" : @"failed",
        @"setupStatus": @(setupStatus),
        @"rendererTuningReadStatus": @(rendererTuningReadStatus),
        @"prepareStatus": @(prepareStatus),
        @"processStatus": @(processStatus),
        @"finishStatus": @(finishStatus),
        @"writeError": writeFailure ?: (id)[NSNull null],
        @"width": @(width),
        @"height": @(height),
        @"thumbnailWidth": @(thumbnailWidth),
        @"thumbnailHeight": @(thumbnailHeight),
        @"processingType": @(processingType),
        @"sceneType": @(sceneType),
        @"personMasksValidHint": @(personMasksValidHint),
        @"faceBasedGlobalExposureBoostRatio": @(faceBoost),
        @"ltmRelativeBrightness": @(ltmRelativeBrightness),
        @"hrGainDownRatioQ12": @(hrGainDownRatioQ12),
        @"requestedEncodingGain": @(encodingGain),
        @"smallLightMap": HalfPlaneSummary(small),
        @"smallLinearLightMap": HalfPlaneSummary(smallLinear),
        @"codedLinearFirstPlane": HalfPlaneSummary(codedLinear),
        @"statistics": statistics,
        @"extendedStatistics": extendedStatistics,
        @"codedLinearMetadata": codedMetadata,
        @"outputs": @{
            @"smallLightMapPath": toneMapPath,
            @"smallLinearLightMapPath": linearMapPath,
            @"codedLinearPath": codedLinearPath,
        },
        @"inputAvailability": @{
            @"personMask": @(person != NULL),
            @"skinMask": @(skin != NULL),
            @"skyMask": @(sky != NULL),
        },
    };
    CFRelease(tone);
    CFRelease(thumbnail);
    CFRelease(linear);
    CFRelease(output);
    CFRelease(small);
    CFRelease(smallLinear);
    CFRelease(codedLinear);
    if (person) CFRelease(person);
    if (skin) CFRelease(skin);
    if (sky) CFRelease(sky);
    return result;
}

static NSDictionary *RunSyntheticProducer(unsigned int processingType) {
    Class rendererClass = NSClassFromString(@"CMISmartStylePixelBufferRendererV1");
    Class styleClass = NSClassFromString(@"CMISmartStyleV1");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!rendererClass || !styleClass || !queue) {
        return @{
            @"status": @"unavailable",
            @"rendererAvailable": @(rendererClass != Nil),
            @"styleAvailable": @(styleClass != Nil),
            @"metalAvailable": @(queue != nil),
        };
    }

    const size_t width = 256;
    const size_t height = 192;
    CVPixelBufferRef tone = CreatePixelBuffer(width, height, kCVPixelFormatType_64RGBAHalf);
    CVPixelBufferRef linear = CreatePixelBuffer(width, height, kCVPixelFormatType_64RGBALE);
    CVPixelBufferRef output = CreatePixelBuffer(width, height, kCVPixelFormatType_64RGBAHalf);
    CVPixelBufferRef small = CreatePixelBuffer(32, 32, kCVPixelFormatType_OneComponent16Half);
    CVPixelBufferRef smallLinear = CreatePixelBuffer(32, 32, kCVPixelFormatType_OneComponent16Half);
    CVPixelBufferRef codedLinear = CreatePixelBuffer(width, height, kCVPixelFormatType_64RGBAHalf);
    if (!tone || !linear || !output || !small || !smallLinear || !codedLinear) {
        if (tone) CFRelease(tone);
        if (linear) CFRelease(linear);
        if (output) CFRelease(output);
        if (small) CFRelease(small);
        if (smallLinear) CFRelease(smallLinear);
        if (codedLinear) CFRelease(codedLinear);
        return @{ @"status": @"pixel_buffer_allocation_failed" };
    }
    AttachLinearDisplayP3(tone);
    AttachLinearDisplayP3(linear);
    FillHalfRGBA(tone, NO);
    FillUnorm16RGBA(linear);

    id renderer = ((id (*)(id, SEL, id, id))objc_msgSend)(
        SendId((id)rendererClass, sel_registerName("alloc")),
        NSSelectorFromString(@"initWithOptionalMetalCommandQueue:allocator:"),
        queue,
        nil
    );
    int setupStatus = renderer ? SendStatus(renderer, NSSelectorFromString(@"setup")) : -1;
    NSString *rendererTuningPath =
        @"/System/Library/PrivateFrameworks/CMImaging.framework/Versions/A/Resources/RendererTuning.plist";
    NSDictionary *rendererTuningDictionary = [NSDictionary dictionaryWithContentsOfFile:rendererTuningPath];
    Class rendererPlistClass = NSClassFromString(@"SmartStyleRendererPlist");
    id rendererTuning = rendererPlistClass
        ? SendId(SendId((id)rendererPlistClass, sel_registerName("alloc")), sel_registerName("init"))
        : nil;
    int rendererTuningReadStatus = rendererTuning && rendererTuningDictionary
        ? ((int (*)(id, SEL, id))objc_msgSend)(
            rendererTuning,
            NSSelectorFromString(@"readPlist:"),
            rendererTuningDictionary
        )
        : -1;
    id metalRenderer = renderer
        ? SendId(renderer, NSSelectorFromString(@"metalRenderer"))
        : nil;
    if (rendererTuningReadStatus == 0 && metalRenderer) {
        SendObject(
            metalRenderer,
            NSSelectorFromString(@"setTuningParameters:"),
            rendererTuning
        );
    }
    id defaultTuningVariant = DynamicObjectConstant(
        "CMISmartStyleTuningParameterVariant_Default"
    );
    if (renderer && defaultTuningVariant) {
        SendObject(
            renderer,
            NSSelectorFromString(@"setTuningParameterVariant:"),
            defaultTuningVariant
        );
    }

    id standardCast = DynamicObjectConstant("CMISmartStyleCastTypeStandard");
    id style = ((id (*)(id, SEL, id, float, float, float))objc_msgSend)(
        SendId((id)styleClass, sel_registerName("alloc")),
        NSSelectorFromString(@"initWithCastType:castIntensity:toneBias:colorBias:"),
        standardCast ?: @"Standard",
        1.0f,
        0.0f,
        0.0f
    );
    id ltmKey = DynamicObjectConstant("kFigCaptureSampleBufferMetadata_LTMRelativeBrightness");
    id gainDownKey = DynamicObjectConstant("kFigCaptureStreamMetadata_HRGainDownRatio");
    id gtcKey = DynamicObjectConstant("kFigCaptureStreamMetadata_GlobalToneCurveLookUpTable");
    id brightnessKey = DynamicObjectConstant("kFigCaptureStreamMetadata_BrightnessValue");
    NSMutableDictionary *linearMetadata = [NSMutableDictionary dictionary];
    if (ltmKey) linearMetadata[ltmKey] = @1.0f;
    if (gainDownKey) linearMetadata[gainDownKey] = @4096;
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    if (gtcKey) metadata[gtcKey] = IdentityGlobalToneCurve();
    if (brightnessKey) metadata[brightnessKey] = @0.0f;
    NSMutableDictionary *statistics = [NSMutableDictionary dictionary];
    NSMutableDictionary *extendedStatistics = [NSMutableDictionary dictionary];
    NSMutableDictionary *codedMetadata = [NSMutableDictionary dictionary];

    if (renderer && setupStatus == 0) {
        SendPixelBuffer(renderer, NSSelectorFromString(@"setInputPixelBuffer:"), tone);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setInputThumbnailPixelBuffer:"), tone);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setInputLinearPixelBuffer:"), linear);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setOutputPixelBuffer:"), output);
        SendObject(renderer, NSSelectorFromString(@"setInputMetadataDict:"), metadata);
        SendObject(renderer, NSSelectorFromString(@"setInputLinearMetadataDict:"), linearMetadata);
        SendObject(renderer, NSSelectorFromString(@"setInputStyle:"), style);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setOutputSmallLightMapPixelBuffer:"), small);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setOutputSmallLinearLightMapPixelBuffer:"), smallLinear);
        SendPixelBuffer(renderer, NSSelectorFromString(@"setOutputCodedLinearPixelBuffer:"), codedLinear);
        SendObject(renderer, NSSelectorFromString(@"setOutputImageStatistics:"), statistics);
        SendObject(renderer, NSSelectorFromString(@"setOutputImageStatisticsExtended:"), extendedStatistics);
        SendObject(renderer, NSSelectorFromString(@"setOutputCodedLinearMetadata:"), codedMetadata);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(
            renderer,
            NSSelectorFromString(@"setStatsComputationRect:"),
            CGRectMake(0, 0, 1, 1)
        );
    }

    int diagnosticGTCStatus = setupStatus == 0
        ? SendStatus(renderer, NSSelectorFromString(@"_createGlobalToneCurveTexture"))
        : -1;
    int diagnosticROIStatus = setupStatus == 0
        ? SendStatus(renderer, NSSelectorFromString(@"_calculateROIShift"))
        : -1;
    NSDictionary *texturesBeforePrepare = MetalRendererTextureSummary(renderer);

    int prepareStatus = setupStatus == 0
        ? ((int (*)(id, SEL, unsigned int))objc_msgSend)(
            renderer,
            NSSelectorFromString(@"prepareToProcess:"),
            processingType
        )
        : -1;
    Class metalRendererClass = NSClassFromString(@"CMISmartStyleMetalRendererV1");
    if (prepareStatus == 0 && metalRendererClass) {
        InstallMetalTraceHooks(metalRendererClass);
    }
    int processStatus = -1;
    @try {
        if (prepareStatus == 0) {
            processStatus = SendStatus(renderer, NSSelectorFromString(@"process"));
        }
    } @finally {
        if (prepareStatus == 0 && metalRendererClass) {
            RestoreMetalTraceHooks(metalRendererClass);
        }
    }
    int finishStatus = processStatus == 0
        ? SendStatus(renderer, NSSelectorFromString(@"finishProcessing"))
        : -1;

    NSDictionary *result = @{
        @"status": setupStatus == 0 && prepareStatus == 0 &&
                processStatus == 0 && finishStatus == 0
            ? @"success"
            : @"failed",
        @"processingType": @(processingType),
        @"setupStatus": @(setupStatus),
        @"rendererTuningReadStatus": @(rendererTuningReadStatus),
        @"rendererTuningClass": rendererTuning
            ? NSStringFromClass([rendererTuning class])
            : (id)[NSNull null],
        @"diagnosticGTCStatus": @(diagnosticGTCStatus),
        @"diagnosticROIStatus": @(diagnosticROIStatus),
        @"prepareStatus": @(prepareStatus),
        @"processStatus": @(processStatus),
        @"finishStatus": @(finishStatus),
        @"metadataKeys": metadata.allKeys,
        @"linearMetadataKeys": linearMetadata.allKeys,
        @"smallLightMap": HalfPlaneSummary(small),
        @"smallLinearLightMap": HalfPlaneSummary(smallLinear),
        @"codedLinearFirstPlane": HalfPlaneSummary(codedLinear),
        @"statistics": statistics,
        @"extendedStatistics": extendedStatistics,
        @"codedLinearMetadata": codedMetadata,
        @"metalTrace": gMetalTrace ?: @[],
        @"texturesBeforePrepare": texturesBeforePrepare,
        @"texturesAfterProcess": MetalRendererTextureSummary(renderer),
    };
    CFRelease(tone);
    CFRelease(linear);
    CFRelease(output);
    CFRelease(small);
    CFRelease(smallLinear);
    CFRelease(codedLinear);
    return result;
}

static NSArray<NSDictionary *> *MethodsForClass(Class cls, BOOL classMethods) {
    Class target = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        Method method = methods[index];
        const char *types = method_getTypeEncoding(method);
        [result addObject:@{
            @"selector": NSStringFromSelector(method_getName(method)),
            @"types": types ? [NSString stringWithUTF8String:types] : @"",
        }];
    }
    free(methods);
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"selector"] compare:right[@"selector"]];
    }];
    return result;
}

static NSArray<NSDictionary *> *IvarsForClass(Class cls) {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        Ivar ivar = ivars[index];
        const char *name = ivar_getName(ivar);
        const char *types = ivar_getTypeEncoding(ivar);
        [result addObject:@{
            @"name": name ? [NSString stringWithUTF8String:name] : @"",
            @"types": types ? [NSString stringWithUTF8String:types] : @"",
            @"offset": @(ivar_getOffset(ivar)),
        }];
    }
    free(ivars);
    return result;
}

static NSArray<NSDictionary *> *PropertiesForClass(Class cls) {
    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        objc_property_t property = properties[index];
        const char *name = property_getName(property);
        const char *attributes = property_getAttributes(property);
        [result addObject:@{
            @"name": name ? [NSString stringWithUTF8String:name] : @"",
            @"attributes": attributes ? [NSString stringWithUTF8String:attributes] : @"",
        }];
    }
    free(properties);
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] compare:right[@"name"]];
    }];
    return result;
}

static NSDictionary *DescribeClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        return @{
            @"class": className,
            @"available": @NO,
        };
    }
    return @{
        @"class": className,
        @"available": @YES,
        @"superclass": class_getSuperclass(cls)
            ? NSStringFromClass(class_getSuperclass(cls))
            : @"",
        @"instanceMethods": MethodsForClass(cls, NO),
        @"classMethods": MethodsForClass(cls, YES),
        @"ivars": IvarsForClass(cls),
        @"properties": PropertiesForClass(cls),
    };
}

static NSArray<NSDictionary *> *StyleGeometryByUseCase(void) {
    Class utilities = NSClassFromString(@"CMISmartStyleUtilitiesV1");
    if (!utilities) return @[];
    SEL styleSelector = NSSelectorFromString(@"styleEngineThumbnailSizeForUseCase:");
    SEL intermediateSelector = NSSelectorFromString(
        @"intermediateStyleRendererThumbnailSizeForUseCase:"
    );
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSUInteger useCase = 0; useCase <= 16; useCase++) {
        CGSize styleSize = ((CGSize (*)(id, SEL, NSUInteger))objc_msgSend)(
            (id)utilities,
            styleSelector,
            useCase
        );
        CGSize intermediateSize = ((CGSize (*)(id, SEL, NSUInteger))objc_msgSend)(
            (id)utilities,
            intermediateSelector,
            useCase
        );
        [result addObject:@{
            @"useCase": @(useCase),
            @"styleEngine": @{
                @"width": @(styleSize.width),
                @"height": @(styleSize.height),
            },
            @"intermediateRenderer": @{
                @"width": @(intermediateSize.width),
                @"height": @(intermediateSize.height),
            },
        }];
    }
    return result;
}

static NSDictionary *RunLinearMetadataProbe(
    float ltmRelativeBrightness,
    NSInteger hrGainDownRatioQ12,
    float brightnessValue,
    float ltmDigitalGain,
    NSInteger ispDGain,
    float ispDGainRangeExpansionFactor
) {
    Class utilities = NSClassFromString(@"CMISmartStyleUtilitiesV1");
    if (!utilities) {
        return @{
            @"status": @"unavailable",
            @"utilitiesAvailable": @NO,
        };
    }
    id ltmKey = DynamicObjectConstant("kFigCaptureSampleBufferMetadata_LTMRelativeBrightness");
    id gainDownKey = DynamicObjectConstant("kFigCaptureStreamMetadata_HRGainDownRatio");
    id brightnessKey = DynamicObjectConstant("kFigCaptureStreamMetadata_BrightnessValue");
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    if (ltmKey) metadata[ltmKey] = @(ltmRelativeBrightness);
    if (gainDownKey) metadata[gainDownKey] = @(hrGainDownRatioQ12);
    if (brightnessKey) metadata[brightnessKey] = @(brightnessValue);
    if (isfinite(ltmDigitalGain) && ltmDigitalGain > 0) {
        metadata[@"LTMDigitalGain"] = @(ltmDigitalGain);
    }
    if (ispDGain >= 0) {
        metadata[@"ispDGain"] = @(ispDGain);
    }
    if (isfinite(ispDGainRangeExpansionFactor) && ispDGainRangeExpansionFactor > 0) {
        metadata[@"ispDGainRangeExpansionFactor"] = @(ispDGainRangeExpansionFactor);
    }

    const SEL encodingSelector = NSSelectorFromString(
        @"computeLinearImageEncodingGainWithMetadata:"
    );
    const SEL exposureSelector = NSSelectorFromString(
        @"computeLinearImageExposureWithMetadata:outputBaseGain:outputBaselineExposure:"
    );
    XDRemuxTracingMetadataDictionary *tracingMetadata =
        [[XDRemuxTracingMetadataDictionary alloc] initWithBacking:metadata];
    float encodingGain = ((float (*)(id, SEL, id))objc_msgSend)(
        (id)utilities,
        encodingSelector,
        tracingMetadata
    );
    float baseGain = NAN;
    float baselineExposure = NAN;
    int exposureStatus = ((int (*)(id, SEL, id, float *, float *))objc_msgSend)(
        (id)utilities,
        exposureSelector,
        tracingMetadata,
        &baseGain,
        &baselineExposure
    );
    return @{
        @"schema": @"xdremux-apple-style-linear-metadata-probe-v1",
        @"status": @"success",
        @"inputs": @{
            @"ltmRelativeBrightness": @(ltmRelativeBrightness),
            @"hrGainDownRatioQ12": @(hrGainDownRatioQ12),
            @"brightnessValue": @(brightnessValue),
            @"ltmDigitalGain": isfinite(ltmDigitalGain) && ltmDigitalGain > 0
                ? @(ltmDigitalGain)
                : (id)[NSNull null],
            @"ispDGain": ispDGain >= 0 ? @(ispDGain) : (id)[NSNull null],
            @"ispDGainRangeExpansionFactor":
                isfinite(ispDGainRangeExpansionFactor) && ispDGainRangeExpansionFactor > 0
                    ? @(ispDGainRangeExpansionFactor)
                    : (id)[NSNull null],
        },
        @"resolvedKeys": @{
            @"ltmRelativeBrightness": ltmKey ?: (id)[NSNull null],
            @"hrGainDownRatio": gainDownKey ?: (id)[NSNull null],
            @"brightnessValue": brightnessKey ?: (id)[NSNull null],
        },
        @"metadata": metadata,
        @"requestedKeys": tracingMetadata.requestedKeys,
        @"encodingGain": @(encodingGain),
        @"baseGain": @(baseGain),
        @"baselineExposure": @(baselineExposure),
        @"exposureStatus": @(exposureStatus),
    };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if ((argc == 5 || argc == 7 || argc == 8) &&
            strcmp(argv[1], "--linear-metadata") == 0) {
            NSString *frameworkPath =
                @"/System/Library/PrivateFrameworks/CMImaging.framework/CMImaging";
            void *framework = dlopen(frameworkPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
            NSDictionary *result = framework
                ? RunLinearMetadataProbe(
                    strtof(argv[2], NULL),
                    (NSInteger)strtoll(argv[3], NULL, 10),
                    strtof(argv[4], NULL),
                    argc >= 7 ? strtof(argv[5], NULL) : NAN,
                    argc >= 7 ? (NSInteger)strtoll(argv[6], NULL, 10) : -1,
                    argc == 8 ? strtof(argv[7], NULL) : NAN
                )
                : @{
                    @"status": @"framework_load_failed",
                    @"error": [NSString stringWithUTF8String:dlerror() ?: ""],
                };
            NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                           options:NSJSONWritingPrettyPrinted |
                                                                   NSJSONWritingSortedKeys
                                                             error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return [result[@"status"] isEqual:@"success"] ? 0 : 1;
        }
        if (argc == 3 && strcmp(argv[1], "--produce-photo-derived-scene") == 0) {
            NSString *frameworkPath =
                @"/System/Library/PrivateFrameworks/CMImaging.framework/CMImaging";
            void *framework = dlopen(frameworkPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
            NSDictionary *result = framework
                ? RunPhotoDerivedProducer([NSString stringWithUTF8String:argv[2]])
                : @{
                    @"status": @"framework_load_failed",
                    @"error": [NSString stringWithUTF8String:dlerror() ?: ""],
                };
            NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                           options:NSJSONWritingPrettyPrinted |
                                                                   NSJSONWritingSortedKeys
                                                             error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return [result[@"status"] isEqual:@"success"] ? 0 : 1;
        }
        if (argc >= 2 && strcmp(argv[1], "--synthetic-producer") == 0) {
            unsigned int processingType = argc >= 3
                ? (unsigned int)strtoul(argv[2], NULL, 10)
                : 5;
            NSString *frameworkPath =
                @"/System/Library/PrivateFrameworks/CMImaging.framework/CMImaging";
            void *framework = dlopen(frameworkPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
            NSDictionary *result = framework
                ? RunSyntheticProducer(processingType)
                : @{
                    @"status": @"framework_load_failed",
                    @"error": [NSString stringWithUTF8String:dlerror() ?: ""],
                };
            NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                           options:NSJSONWritingPrettyPrinted |
                                                                   NSJSONWritingSortedKeys
                                                             error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return [result[@"status"] isEqual:@"success"] ? 0 : 1;
        }
        if (argc < 2 || strcmp(argv[1], "--runtime-contract") != 0) {
            fprintf(
                stderr,
                "usage: %s --runtime-contract [class ...] | --linear-metadata ltm-relative-brightness hr-gain-down-ratio-q12 brightness [ltm-digital-gain isp-dgain [isp-dgain-range-expansion-factor]] | --synthetic-producer [processing-type] | --produce-photo-derived-scene request.json\n",
                argv[0]
            );
            return 64;
        }

        NSString *frameworkPath =
            @"/System/Library/PrivateFrameworks/CMImaging.framework/CMImaging";
        void *framework = dlopen(frameworkPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        NSString *loadError = framework ? @"" : [NSString stringWithUTF8String:dlerror() ?: ""];

        NSMutableArray<NSString *> *classNames = [NSMutableArray array];
        for (int index = 2; index < argc; index++) {
            [classNames addObject:[NSString stringWithUTF8String:argv[index]]];
        }
        if (classNames.count == 0) {
            [classNames addObjectsFromArray:@[
                @"CMISmartStylePixelBufferRendererV1",
                @"CMISmartStyleMetalRendererV1",
                @"CMISmartStyleUtilitiesV1",
                @"CMISmartStyleV1",
            ]];
        }

        NSMutableArray<NSDictionary *> *classes = [NSMutableArray array];
        for (NSString *className in classNames) {
            [classes addObject:DescribeClass(className)];
        }
        NSDictionary *result = @{
            @"schema": @"xdremux-apple-style-scene-payload-runtime-contract-v1",
            @"framework": frameworkPath,
            @"frameworkLoaded": @(framework != NULL),
            @"frameworkLoadError": loadError,
            @"styleGeometryByUseCase": framework ? StyleGeometryByUseCase() : @[],
            @"classes": classes,
        };
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                       options:NSJSONWritingPrettyPrinted |
                                                               NSJSONWritingSortedKeys
                                                         error:&error];
        if (!json) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return framework ? 0 : 1;
    }
}
