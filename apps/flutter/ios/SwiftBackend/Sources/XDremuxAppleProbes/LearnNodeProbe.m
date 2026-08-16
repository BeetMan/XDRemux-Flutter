#import <CoreImage/CoreImage.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif
#import <Foundation/Foundation.h>
#import "XDremuxAppleProbes.h"
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <zlib.h>

// NSStringFromRect is AppKit-only; UIKit exposes NSStringFromCGRect.
#if TARGET_OS_OSX
#define XDRemuxRectToString(rect) NSStringFromRect(NSRectFromCGRect(rect))
#else
#define XDRemuxRectToString(rect) NSStringFromCGRect(rect)
#endif

// Private ABI mirror used by NUStyleTransferNode on this macOS build.
typedef struct {
    int64_t first;
    int64_t second;
} NUIntegerPair;

static IMP gOriginalLearnProcess;
static IMP gOriginalCMIProcess;
static IMP gOriginalSemanticProcess;
static IMP gOriginalUsingSharedRenderer;
static IMP gOriginalGuidedFilterEncode;
static IMP gOriginalAllocatorNewTexture;
static NSMutableDictionary<NSString *, NSValue *> *gOriginalSmartStyleMethods;
static NSMutableArray<NSDictionary *> *gEvents;
static id gLastCMIProcessor;
static NSMutableDictionary<NSString *, id> *gCapturedCMIResources;
static NSMutableDictionary<NSString *, NSData *> *gCapturedCMISnapshots;
static NSMutableDictionary<NSString *, NSDictionary *> *gCapturedCMIDescriptors;

static id SendId(id object, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static double SendDouble(id object, SEL selector) {
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSInteger SendInteger(id object, SEL selector) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGSize SendSize(id object, SEL selector) {
    return ((CGSize (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGRect SendRect(id object, SEL selector) {
    return ((CGRect (*)(id, SEL))objc_msgSend)(object, selector);
}

static void SendObject(id object, SEL selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static void SendDoubleValue(id object, SEL selector, double value) {
    ((void (*)(id, SEL, double))objc_msgSend)(object, selector, value);
}

static void SendFloatValue(id object, SEL selector, float value) {
    ((void (*)(id, SEL, float))objc_msgSend)(object, selector, value);
}

static void SendBoolValue(id object, SEL selector, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static id SendClassObjectError(Class cls, SEL selector, id value, NSError **error) {
    return ((id (*)(id, SEL, id, NSError **))objc_msgSend)((id)cls, selector, value, error);
}

static id SendClassPairPair(Class cls, SEL selector, NUIntegerPair first, NUIntegerPair second) {
    return ((id (*)(id, SEL, NUIntegerPair, NUIntegerPair))objc_msgSend)(
        (id)cls, selector, first, second
    );
}

static id SendClassCastFloats(
    Class cls,
    SEL selector,
    id cast,
    float tone,
    float color,
    float intensity,
    float priorStrength
) {
    return ((id (*)(id, SEL, id, float, float, float, float))objc_msgSend)(
        (id)cls, selector, cast, tone, color, intensity, priorStrength
    );
}

static id SendClassLearn(
    Class cls,
    SEL selector,
    id input,
    id target,
    id colorSpace,
    id configuration,
    id tuning,
    NSError **error
) {
    return ((id (*)(id, SEL, id, id, id, id, id, NSError **))objc_msgSend)(
        (id)cls,
        selector,
        input,
        target,
        colorSpace,
        configuration,
        tuning,
        error
    );
}

static id SendClassThumbnail(
    Class cls,
    SEL selector,
    id image,
    NUIntegerPair targetSize,
    id colorSpace,
    id configuration,
    id tuning,
    NSError **error
) {
    return ((id (*)(id, SEL, id, NUIntegerPair, id, id, id, NSError **))objc_msgSend)(
        (id)cls,
        selector,
        image,
        targetSize,
        colorSpace,
        configuration,
        tuning,
        error
    );
}

static id SendClassApply(
    Class cls,
    SEL selector,
    id style,
    id image,
    id thumbnail,
    id target,
    id deltaMap,
    id colorSpace,
    id configuration,
    id tuning,
    id noiseModel,
    NSError **error
) {
    return ((id (*)(id, SEL, id, id, id, id, id, id, id, id, id, NSError **))objc_msgSend)(
        (id)cls,
        selector,
        style,
        image,
        thumbnail,
        target,
        deltaMap,
        colorSpace,
        configuration,
        tuning,
        noiseModel,
        error
    );
}

static int SendSmartStyleUtilityLearn(
    id utility,
    SEL selector,
    CVPixelBufferRef source,
    CVPixelBufferRef target,
    CVPixelBufferRef outputCoefficients,
    id *outputIntegratedCoefficients
) {
    return ((int (*)(id, SEL, CVPixelBufferRef, CVPixelBufferRef, CVPixelBufferRef, id *))
        objc_msgSend)(
            utility,
            selector,
            source,
            target,
            outputCoefficients,
            outputIntegratedCoefficients
        );
}

static CGSize SendClassDictionarySize(Class cls, SEL selector, id dictionary) {
    return ((CGSize (*)(id, SEL, id))objc_msgSend)((id)cls, selector, dictionary);
}

static id JSONSafe(id value);
static id IvarObjectValue(id object, NSString *name);

static NSDictionary *ObjectIvarSummary(id object) {
    if (!object) {
        return @{};
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *name = ivar_getName(ivars[index]);
            const char *type = ivar_getTypeEncoding(ivars[index]);
            NSString *key = [NSString stringWithFormat:@"%@.%s", NSStringFromClass(cls), name ?: ""];
            if (type && type[0] == '@') {
                id child = object_getIvar(object, ivars[index]);
                if (!child) {
                    result[key] = [NSNull null];
                } else {
                    NSMutableDictionary *summary = [@{
                        @"class": NSStringFromClass([child class]),
                    } mutableCopy];
                    if ([child isKindOfClass:[NSString class]] ||
                        [child isKindOfClass:[NSNumber class]]) {
                        summary[@"description"] = [child description] ?: @"";
                    } else if ([child isKindOfClass:[NSData class]]) {
                        summary[@"length"] = @([(NSData *)child length]);
                    } else if ([child isKindOfClass:[NSArray class]] ||
                               [child isKindOfClass:[NSDictionary class]] ||
                               [child isKindOfClass:[NSSet class]]) {
                        @try {
                            summary[@"count"] = @([(id)child count]);
                        } @catch (__unused NSException *exception) {
                            summary[@"count"] = [NSNull null];
                        }
                    }
                    result[key] = summary;
                }
            } else {
                result[key] = @{
                    @"encoding": type ? [NSString stringWithUTF8String:type] : @"",
                    @"offset": @(ivar_getOffset(ivars[index])),
                };
            }
        }
        free(ivars);
    }
    return result;
}

static NSDictionary *TextureSummary(id<MTLTexture> texture) {
    if (!texture) {
        return @{};
    }
    return @{
        @"class": NSStringFromClass([(id)texture class]),
        @"width": @(texture.width),
        @"height": @(texture.height),
        @"depth": @(texture.depth),
        @"arrayLength": @(texture.arrayLength),
        @"mipmapLevelCount": @(texture.mipmapLevelCount),
        @"pixelFormat": @((NSUInteger)texture.pixelFormat),
        @"textureType": @((NSUInteger)texture.textureType),
        @"storageMode": @((NSUInteger)texture.storageMode),
        @"cpuCacheMode": @((NSUInteger)texture.cpuCacheMode),
        @"hazardTrackingMode": @((NSUInteger)texture.hazardTrackingMode),
        @"usage": @((NSUInteger)texture.usage),
        @"framebufferOnly": @(texture.framebufferOnly),
        @"allocatedSize": @(texture.allocatedSize),
        @"iosurfacePlane": @(texture.iosurfacePlane),
        @"hasIOSurface": @(texture.iosurface != NULL),
        @"label": texture.label ?: [NSNull null],
    };
}

static NSDictionary *BufferSummary(id<MTLBuffer> buffer) {
    if (!buffer) {
        return @{};
    }
    NSMutableDictionary *result = [@{
        @"class": NSStringFromClass([(id)buffer class]),
        @"length": @(buffer.length),
        @"storageMode": @((NSUInteger)buffer.storageMode),
        @"cpuCacheMode": @((NSUInteger)buffer.cpuCacheMode),
        @"hazardTrackingMode": @((NSUInteger)buffer.hazardTrackingMode),
        @"allocatedSize": @(buffer.allocatedSize),
        @"hasContents": @(buffer.contents != NULL),
        @"label": buffer.label ?: [NSNull null],
    } mutableCopy];
    if ([NSProcessInfo processInfo].environment[@"LEARNNODE_BUFFER_NUMERICS"].boolValue &&
        buffer.contents && buffer.length > 0 && buffer.length <= 2 * 1024 * 1024 &&
        buffer.length % sizeof(float) == 0) {
        const float *values = buffer.contents;
        NSUInteger count = buffer.length / sizeof(float);
        double sum = 0;
        float minimum = INFINITY;
        float maximum = -INFINITY;
        NSUInteger finiteCount = 0;
        NSUInteger zeroCount = 0;
        NSMutableArray *prefix = [NSMutableArray arrayWithCapacity:MIN(count, 32)];
        for (NSUInteger index = 0; index < count; index++) {
            float value = values[index];
            if (index < 32) {
                [prefix addObject:@(value)];
            }
            if (isfinite(value)) {
                minimum = MIN(minimum, value);
                maximum = MAX(maximum, value);
                sum += value;
                finiteCount++;
            }
            if (value == 0) {
                zeroCount++;
            }
        }
        result[@"float32Numerics"] = @{
            @"count": @(count),
            @"finiteCount": @(finiteCount),
            @"zeroCount": @(zeroCount),
            @"minimum": finiteCount ? @(minimum) : (id)[NSNull null],
            @"maximum": finiteCount ? @(maximum) : (id)[NSNull null],
            @"mean": finiteCount ? @(sum / finiteCount) : (id)[NSNull null],
            @"prefix": prefix,
        };
    }
    return result;
}

static NSString *CaptureFileName(NSString *stage, NSString *name, NSString *extension) {
    NSString *raw = [NSString stringWithFormat:@"%@_%@.%@", stage, name, extension];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."
    ];
    return [[raw componentsSeparatedByCharactersInSet:allowed.invertedSet]
        componentsJoinedByString:@"_"];
}

static void RetainCMIResources(id processor, NSString *stage, BOOL snapshotBuffers) {
    if (!processor) {
        return;
    }
    for (NSString *ivarName in @[
        @"_coefficientsBuffer",
        @"_rhsBuffer",
        @"_linSysStatusBuffer",
        @"_linSysStatusFlagBuffer",
        @"_outputLinearSystemCoefficientsBuffer",
        @"_outputLinearSystemCoefficientsTexture",
        @"_integratedCoefficientsTexture",
    ]) {
        id resource = IvarObjectValue(processor, ivarName);
        if (![resource conformsToProtocol:@protocol(MTLBuffer)] &&
            ![resource conformsToProtocol:@protocol(MTLTexture)]) {
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%@.%@", stage, ivarName];
        gCapturedCMIResources[key] = resource;
        if ([resource conformsToProtocol:@protocol(MTLBuffer)]) {
            id<MTLBuffer> buffer = resource;
            gCapturedCMIDescriptors[key] = @{
                @"captureStage": stage,
                @"source": @"CMIStyleEngineProcessor ivar",
                @"sourceName": ivarName,
                @"kind": @"MTLBuffer",
                @"length": @(buffer.length),
                @"storageMode": @((NSUInteger)buffer.storageMode),
                @"cpuCacheMode": @((NSUInteger)buffer.cpuCacheMode),
            };
            if (snapshotBuffers && buffer.contents && buffer.length > 0) {
                gCapturedCMISnapshots[key] = [NSData dataWithBytes:buffer.contents
                                                            length:buffer.length];
            }
        } else {
            id<MTLTexture> texture = resource;
            gCapturedCMIDescriptors[key] = @{
                @"captureStage": stage,
                @"source": @"CMIStyleEngineProcessor ivar",
                @"sourceName": ivarName,
                @"kind": @"MTLTexture",
                @"width": @(texture.width),
                @"height": @(texture.height),
                @"pixelFormat": @((NSUInteger)texture.pixelFormat),
                @"storageMode": @((NSUInteger)texture.storageMode),
            };
        }
    }
}

static NSArray<NSDictionary *> *WriteCapturedCMIResources(
    NSString *outputDirectory,
    NSError **error
) {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSArray<NSString *> *snapshotKeys = [gCapturedCMISnapshots.allKeys
        sortedArrayUsingSelector:@selector(compare:)
    ];
    for (NSString *key in snapshotKeys) {
        NSData *data = gCapturedCMISnapshots[key];
        NSDictionary *descriptor = gCapturedCMIDescriptors[key] ?: @{};
        NSString *path = [outputDirectory stringByAppendingPathComponent:
            CaptureFileName(descriptor[@"captureStage"] ?: @"unknown",
                            descriptor[@"sourceName"] ?: key,
                            @"snapshot.bin")
        ];
        NSError *writeError = nil;
        BOOL written = [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
        NSMutableDictionary *row = [descriptor mutableCopy];
        row[@"captureTiming"] = @"immediate CPU snapshot around process call";
        row[@"path"] = written ? path : (id)[NSNull null];
        row[@"byteLength"] = @(data.length);
        row[@"writeError"] = JSONSafe(writeError);
        [rows addObject:row];
        if (!written && error && !*error) {
            *error = writeError;
        }
    }

    NSArray<NSString *> *resourceKeys = [gCapturedCMIResources.allKeys
        sortedArrayUsingSelector:@selector(compare:)
    ];
    for (NSString *key in resourceKeys) {
        id resource = gCapturedCMIResources[key];
        NSDictionary *descriptor = gCapturedCMIDescriptors[key] ?: @{};
        NSMutableData *data = nil;
        NSUInteger bytesPerRow = 0;
        NSString *extension = @"final.bin";
        NSError *captureError = nil;
        if ([resource conformsToProtocol:@protocol(MTLBuffer)]) {
            id<MTLBuffer> buffer = resource;
            if (buffer.contents && buffer.length > 0) {
                data = [NSMutableData dataWithBytes:buffer.contents length:buffer.length];
            }
        } else if ([resource conformsToProtocol:@protocol(MTLTexture)]) {
            id<MTLTexture> texture = resource;
            NSUInteger bytesPerPixel = 0;
            if (texture.pixelFormat == MTLPixelFormatR16Float) {
                bytesPerPixel = sizeof(uint16_t);
                extension = @"final.f16.bin";
            } else if (texture.pixelFormat == MTLPixelFormatR32Float) {
                bytesPerPixel = sizeof(float);
                extension = @"final.f32.bin";
            } else if (texture.pixelFormat == MTLPixelFormatRGBA16Float) {
                bytesPerPixel = sizeof(uint16_t) * 4;
                extension = @"final.rgba16f.bin";
            }
            if (bytesPerPixel > 0 && texture.width > 0 && texture.height > 0) {
                bytesPerRow = texture.width * bytesPerPixel;
                data = [NSMutableData dataWithLength:bytesPerRow * texture.height];
                @try {
                    [texture getBytes:data.mutableBytes
                          bytesPerRow:bytesPerRow
                           fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height)
                          mipmapLevel:0];
                } @catch (NSException *exception) {
                    data = nil;
                    captureError = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                                        code:6
                                                    userInfo:@{
                        NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                    }];
                }
            }
        }
        NSString *path = [outputDirectory stringByAppendingPathComponent:
            CaptureFileName([NSString stringWithFormat:@"after_core_image_render_%@",
                                                        descriptor[@"captureStage"] ?: @"unknown"],
                            descriptor[@"sourceName"] ?: key,
                            extension)
        ];
        NSError *writeError = nil;
        BOOL written = data && [data writeToFile:path
                                         options:NSDataWritingAtomic
                                           error:&writeError];
        NSMutableDictionary *row = [descriptor mutableCopy];
        row[@"captureTiming"] = @"after learned CIImage was rendered and GPU work completed";
        row[@"path"] = written ? path : (id)[NSNull null];
        row[@"byteLength"] = data ? @(data.length) : (id)[NSNull null];
        row[@"bytesPerRow"] = bytesPerRow ? @(bytesPerRow) : (id)[NSNull null];
        row[@"captureError"] = JSONSafe(captureError ?: writeError);
        [rows addObject:row];
        if (!written && error && !*error && (captureError || writeError)) {
            *error = captureError ?: writeError;
        }
    }
    return rows;
}

static NSDictionary *ProcessorSummary(id processor) {
    if (!processor) {
        return @{};
    }
    NSMutableDictionary *result = [@{
        @"class": NSStringFromClass([processor class]),
        @"description": [processor description] ?: @"",
    } mutableCopy];
    for (NSString *selectorName in @[
        @"outputLinearSystemCoefficients",
        @"outputLinearSystemCoefficientsBuffer",
        @"outputLinearSystemCoefficientsTexture",
        @"inputThumbnailTexture",
        @"targetThumbnailTexture",
        @"configuration",
        @"tuningParameters",
        @"metalCommandQueue",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![processor respondsToSelector:selector]) {
            continue;
        }
        id child = SendId(processor, selector);
        if ([child conformsToProtocol:@protocol(MTLTexture)]) {
            result[selectorName] = TextureSummary(child);
        } else if ([child conformsToProtocol:@protocol(MTLBuffer)]) {
            result[selectorName] = BufferSummary(child);
        } else {
            result[selectorName] = JSONSafe(child);
        }
    }
    Ivar coefficientsIvar = class_getInstanceVariable(
        [processor class], "_coefficientsBuffer"
    );
    if (coefficientsIvar) {
        id coefficients = object_getIvar(processor, coefficientsIvar);
        if ([coefficients conformsToProtocol:@protocol(MTLBuffer)]) {
            result[@"internalCoefficientsBuffer"] = BufferSummary(coefficients);
        }
    }
    result[@"ivars"] = ObjectIvarSummary(processor);
    return result;
}

static NSDictionary *ProcessorOutputSummary(id output) {
    if (!output) {
        return @{};
    }
    NSMutableDictionary *result = [@{
        @"class": NSStringFromClass([output class]),
        @"description": [output description] ?: @"",
        @"ivars": ObjectIvarSummary(output),
    } mutableCopy];
    SEL regionSelector = NSSelectorFromString(@"region");
    if ([output respondsToSelector:regionSelector]) {
        CGRect region = ((CGRect (*)(id, SEL))objc_msgSend)(output, regionSelector);
        result[@"region"] = @{
            @"x": @(region.origin.x),
            @"y": @(region.origin.y),
            @"width": @(region.size.width),
            @"height": @(region.size.height),
        };
    }
    SEL formatSelector = NSSelectorFromString(@"format");
    if ([output respondsToSelector:formatSelector]) {
        result[@"format"] = @(((int (*)(id, SEL))objc_msgSend)(output, formatSelector));
    }
    SEL bytesPerRowSelector = NSSelectorFromString(@"bytesPerRow");
    if ([output respondsToSelector:bytesPerRowSelector]) {
        result[@"bytesPerRow"] = @(((size_t (*)(id, SEL))objc_msgSend)(
            output, bytesPerRowSelector
        ));
    }
    SEL baseAddressSelector = NSSelectorFromString(@"baseAddress");
    if ([output respondsToSelector:baseAddressSelector]) {
        result[@"hasBaseAddress"] = @(
            ((void *(*)(id, SEL))objc_msgSend)(output, baseAddressSelector) != NULL
        );
    }
    SEL metalTextureSelector = NSSelectorFromString(@"metalTexture");
    if ([output respondsToSelector:metalTextureSelector]) {
        result[@"metalTexture"] = TextureSummary(SendId(output, metalTextureSelector));
    }
    return result;
}

static NSDictionary *CompactObjectSummary(id object) {
    if (!object) {
        return @{};
    }
    if ([object conformsToProtocol:@protocol(MTLTexture)]) {
        return TextureSummary(object);
    }
    if ([object conformsToProtocol:@protocol(MTLBuffer)]) {
        return BufferSummary(object);
    }
    if ([object isKindOfClass:[NSData class]]) {
        return @{
            @"class": NSStringFromClass([object class]),
            @"length": @([(NSData *)object length]),
        };
    }
    if ([object isKindOfClass:[NSDictionary class]] ||
        [object isKindOfClass:[NSArray class]] ||
        [object isKindOfClass:[NSSet class]]) {
        return @{
            @"class": NSStringFromClass([object class]),
            @"count": @([(id)object count]),
        };
    }
    return @{
        @"class": NSStringFromClass([object class]),
        @"description": [object description] ?: @"",
    };
}

static NSDictionary *TextureDescriptorSummary(id descriptorWrapper) {
    if (!descriptorWrapper) {
        return @{};
    }
    id descriptor = descriptorWrapper;
    SEL descSelector = NSSelectorFromString(@"desc");
    if ([descriptor respondsToSelector:descSelector]) {
        descriptor = SendId(descriptor, descSelector) ?: descriptor;
    }
    if (![descriptor isKindOfClass:[MTLTextureDescriptor class]]) {
        return CompactObjectSummary(descriptorWrapper);
    }
    MTLTextureDescriptor *textureDescriptor = descriptor;
    return @{
        @"wrapperClass": NSStringFromClass([descriptorWrapper class]),
        @"class": NSStringFromClass([textureDescriptor class]),
        @"width": @(textureDescriptor.width),
        @"height": @(textureDescriptor.height),
        @"depth": @(textureDescriptor.depth),
        @"arrayLength": @(textureDescriptor.arrayLength),
        @"mipmapLevelCount": @(textureDescriptor.mipmapLevelCount),
        @"pixelFormat": @((NSUInteger)textureDescriptor.pixelFormat),
        @"textureType": @((NSUInteger)textureDescriptor.textureType),
        @"storageMode": @((NSUInteger)textureDescriptor.storageMode),
        @"cpuCacheMode": @((NSUInteger)textureDescriptor.cpuCacheMode),
        @"hazardTrackingMode": @((NSUInteger)textureDescriptor.hazardTrackingMode),
        @"usage": @((NSUInteger)textureDescriptor.usage),
        @"resourceOptions": @((NSUInteger)textureDescriptor.resourceOptions),
    };
}

static id IvarObjectValue(id object, NSString *name) {
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (ivar && ivar_getTypeEncoding(ivar)[0] == '@') {
            return object_getIvar(object, ivar);
        }
    }
    return nil;
}

static NSNumber *IvarInt32Value(id object, NSString *name) {
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        if (ivar && type && strcmp(type, @encode(int)) == 0) {
            int value = 0;
            const uint8_t *bytes = (__bridge const void *)object;
            memcpy(&value, bytes + ivar_getOffset(ivar), sizeof(value));
            return @(value);
        }
    }
    return nil;
}

static NSDictionary *SmartStyleRendererCompactSummary(id renderer) {
    if (!renderer) {
        return @{};
    }
    NSMutableDictionary *result = [@{
        @"class": NSStringFromClass([renderer class]),
    } mutableCopy];
    for (NSString *selectorName in @[
        @"inputImageTexture",
        @"inputImageThumbnailTexture",
        @"inputLinearImageTexture",
        @"inputLinearImageLumaTexture",
        @"inputLinearImageChromaTexture",
        @"inputPersonMaskTexture",
        @"inputSkinMaskTexture",
        @"inputSkyMaskTexture",
        @"inputGainMapTexture",
        @"inputGlobalToneCurveTexture",
        @"inputLightMapTexture",
        @"inputLinearLightMapTexture",
        @"inputSmallLightMapTexture",
        @"inputSmallLinearLightMapTexture",
        @"inputStyle",
        @"inputStatisticsByStatsKey",
        @"inputStatisticsByStatsType",
        @"tuningParameterVariant",
        @"tuningParameters",
        @"outputImageTexture",
        @"outputGainMapTexture",
        @"outputSmallLightMapTexture",
        @"outputSmallLinearLightMapTexture",
        @"outputCodedLinearTexture",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([renderer respondsToSelector:selector]) {
            result[selectorName] = CompactObjectSummary(SendId(renderer, selector));
        }
    }
    SEL codedLinearMetadataSelector = NSSelectorFromString(@"outputCodedLinearMetadata");
    if ([renderer respondsToSelector:codedLinearMetadataSelector]) {
        result[@"outputCodedLinearMetadata"] = JSONSafe(
            SendId(renderer, codedLinearMetadataSelector)
        );
    }
    for (NSString *selectorName in @[
        @"baselineExposure",
        @"castIntensity",
        @"colorBias",
        @"faceBasedGlobalExposureBoostRatio",
        @"inputLinearBaseGain",
        @"inputLinearEncodingGain",
        @"inputLinearImageGainDownRatio",
        @"inputSRLCurveParameter",
        @"personMasksValidHint",
        @"toneBias",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([renderer respondsToSelector:selector]) {
            result[selectorName] = @(((float (*)(id, SEL))objc_msgSend)(renderer, selector));
        }
    }
    SEL sceneTypeSelector = NSSelectorFromString(@"semanticStyleSceneType");
    if ([renderer respondsToSelector:sceneTypeSelector]) {
        result[@"semanticStyleSceneType"] = @(((int (*)(id, SEL))objc_msgSend)(
            renderer, sceneTypeSelector
        ));
    }
    NSNumber *internalProcessingType = IvarInt32Value(renderer, @"_processingType");
    if (internalProcessingType) {
        result[@"internalProcessingType"] = internalProcessingType;
    }
    for (NSString *selectorName in @[
        @"logicalImageSize",
        @"logicalImageToInputImageScale",
        @"logicalImageToInputLinearImageScale",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([renderer respondsToSelector:selector]) {
            CGSize value = SendSize(renderer, selector);
            result[selectorName] = @{
                @"width": @(value.width),
                @"height": @(value.height),
            };
        }
    }
    for (NSString *selectorName in @[
        @"renderRegionRect",
        @"inputImageTextureMappedRegion",
        @"inputLinearImageTextureMappedRegion",
        @"outputImageTextureMappedRegion",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([renderer respondsToSelector:selector]) {
            CGRect value = SendRect(renderer, selector);
            result[selectorName] = @{
                @"x": @(value.origin.x),
                @"y": @(value.origin.y),
                @"width": @(value.size.width),
                @"height": @(value.size.height),
            };
        }
    }
    result[@"internalTuningParameters"] = CompactObjectSummary(
        IvarObjectValue(renderer, @"_internalTuningParams")
    );
    return result;
}

static void RetainSmartStyleRendererResources(id renderer, NSString *stage) {
    if (!renderer) {
        return;
    }
    for (NSString *name in @[
        @"_inputImageTexture",
        @"_inputImageThumbnailTexture",
        @"_inputLinearImageTexture",
        @"_inputLinearImageRGBTexture",
        @"_outputCodedLinearTexture",
        @"_outputImageTexture",
        @"_outputSmallLightMapTexture",
        @"_outputSmallLinearLightMapTexture",
    ]) {
        id resource = IvarObjectValue(renderer, name);
        if (![resource conformsToProtocol:@protocol(MTLTexture)]) {
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%@.%@", stage, name];
        id<MTLTexture> texture = resource;
        gCapturedCMIResources[key] = texture;
        gCapturedCMIDescriptors[key] = @{
            @"captureStage": stage,
            @"source": @"CMISmartStyleMetalRendererV1 ivar",
            @"sourceName": name,
            @"kind": @"MTLTexture",
            @"width": @(texture.width),
            @"height": @(texture.height),
            @"arrayLength": @(texture.arrayLength),
            @"pixelFormat": @((NSUInteger)texture.pixelFormat),
            @"textureType": @((NSUInteger)texture.textureType),
            @"storageMode": @((NSUInteger)texture.storageMode),
        };
    }
}

static void EnsureSmartStyleCodedLinearOutput(id renderer) {
    SEL outputSelector = NSSelectorFromString(@"outputCodedLinearTexture");
    if ([renderer respondsToSelector:outputSelector] && SendId(renderer, outputSelector)) {
        return;
    }
    id<MTLTexture> reference = nil;
    for (NSString *selectorName in @[
        @"outputImageTexture",
        @"inputImageTexture",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([renderer respondsToSelector:selector]) {
            reference = SendId(renderer, selector);
        }
        if (reference) {
            break;
        }
    }
    id<MTLCommandQueue> commandQueue = [renderer
        respondsToSelector:NSSelectorFromString(@"metalCommandQueue")]
        ? SendId(renderer, NSSelectorFromString(@"metalCommandQueue"))
        : nil;
    if (!reference || !commandQueue.device) {
        return;
    }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                    width:reference.width
                                   height:reference.height
                                mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> output = [commandQueue.device newTextureWithDescriptor:descriptor];
    output.label = @"LearnNodeCoefficientProbe coded linear output";
    if (output &&
        [renderer respondsToSelector:NSSelectorFromString(@"setOutputCodedLinearTexture:")]) {
        SendObject(
            renderer,
            NSSelectorFromString(@"setOutputCodedLinearTexture:"),
            output
        );
    }
    if ([renderer respondsToSelector:NSSelectorFromString(@"setOutputCodedLinearMetadata:")]) {
        SendObject(
            renderer,
            NSSelectorFromString(@"setOutputCodedLinearMetadata:"),
            [NSMutableDictionary dictionary]
        );
    }
}

static id JSONSafe(id value) {
    if (!value) {
        return [NSNull null];
    }
    if ([value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSNull class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
            isfinite([value doubleValue])) {
            return value;
        }
        return @{
            @"nonfiniteNumber": [value description] ?: @"unknown",
        };
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSMutableDictionary *summary = [@{
            @"class": NSStringFromClass([value class]),
            @"length": @([(NSData *)value length]),
        } mutableCopy];
        if ([(NSData *)value length] <= 64) {
            summary[@"base64"] = [(NSData *)value base64EncodedStringWithOptions:0];
        }
        return summary;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (id key in value) {
            result[[key description] ?: @"<nil>"] = JSONSafe(value[key]);
        }
        return result;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id child in value) {
            [result addObject:JSONSafe(child)];
        }
        return result;
    }
    if ([value conformsToProtocol:@protocol(MTLTexture)]) {
        return TextureSummary(value);
    }
    if ([value conformsToProtocol:@protocol(MTLBuffer)]) {
        return BufferSummary(value);
    }
    return @{
        @"class": NSStringFromClass([value class]),
        @"description": [value description] ?: @"",
    };
}

static void AppendEvent(NSDictionary *event) {
    @synchronized (gEvents) {
        [gEvents addObject:event];
    }
}

static BOOL RecordingLearnProcess(
    id cls,
    SEL selector,
    NSArray *inputs,
    NSDictionary *arguments,
    id output,
    NSError **error
) {
    NSMutableArray *inputRows = [NSMutableArray array];
    for (id input in inputs) {
        [inputRows addObject:@{
            @"class": NSStringFromClass([input class]),
            @"description": [input description] ?: @"",
            @"ivars": ObjectIvarSummary(input),
        }];
    }
    NSDictionary *before = @{
        @"event": @"_NUStyleTransferLearnProcessor.process.before",
        @"inputs": inputRows,
        @"arguments": JSONSafe(arguments),
        @"output": ProcessorOutputSummary(output),
    };
    AppendEvent(before);
    BOOL result = ((BOOL (*)(id, SEL, NSArray *, NSDictionary *, id, NSError **))
        gOriginalLearnProcess)(cls, selector, inputs, arguments, output, error);
    AppendEvent(@{
        @"event": @"_NUStyleTransferLearnProcessor.process.after",
        @"result": @(result),
        @"error": error && *error ? JSONSafe(*error) : [NSNull null],
        @"output": ProcessorOutputSummary(output),
    });
    return result;
}

static BOOL RecordingSemanticProcess(
    id cls,
    SEL selector,
    NSArray *inputs,
    NSDictionary *arguments,
    id output,
    NSError **error
) {
    NSMutableArray *inputRows = [NSMutableArray array];
    for (id input in inputs) {
        [inputRows addObject:@{
            @"class": NSStringFromClass([input class]),
            @"description": [input description] ?: @"",
            @"ivars": ObjectIvarSummary(input),
        }];
    }
    AppendEvent(@{
        @"event": @"PISemanticStyleProcessor.process.before",
        @"inputs": inputRows,
        @"arguments": JSONSafe(arguments),
        @"output": ProcessorOutputSummary(output),
    });
    BOOL result = ((BOOL (*)(id, SEL, NSArray *, NSDictionary *, id, NSError **))
        gOriginalSemanticProcess)(cls, selector, inputs, arguments, output, error);
    AppendEvent(@{
        @"event": @"PISemanticStyleProcessor.process.after",
        @"result": @(result),
        @"error": error && *error ? JSONSafe(*error) : [NSNull null],
        @"output": ProcessorOutputSummary(output),
    });
    return result;
}

static NSDictionary *SemanticRendererSummary(id renderer) {
    if (!renderer) {
        return @{};
    }
    NSMutableDictionary *summary = [@{
        @"class": NSStringFromClass([renderer class]),
        @"description": [renderer description] ?: @"",
        @"ivars": ObjectIvarSummary(renderer),
    } mutableCopy];
    for (NSString *selectorName in @[
        @"processingType", @"useStyleEngine", @"processor", @"metalCommandQueue"
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![renderer respondsToSelector:selector]) {
            continue;
        }
        if ([selectorName isEqualToString:@"processingType"]) {
            summary[selectorName] = @(SendInteger(renderer, selector));
        } else if ([selectorName isEqualToString:@"useStyleEngine"]) {
            summary[selectorName] = @(((BOOL (*)(id, SEL))objc_msgSend)(renderer, selector));
        } else {
            id child = SendId(renderer, selector);
            summary[selectorName] = child ? @{
                @"class": NSStringFromClass([child class]),
                @"description": [child description] ?: @"",
                @"ivars": ObjectIvarSummary(child),
            } : (id)[NSNull null];
        }
    }
    return summary;
}

static BOOL RecordingUsingSharedRenderer(
    id cls,
    SEL selector,
    id commandQueue,
    int processingType,
    BOOL useStyleEngine,
    id blockObject
) {
    BOOL (^originalBlock)(id) = blockObject;
    BOOL (^recordingBlock)(id) = ^BOOL(id renderer) {
        AppendEvent(@{
            @"event": @"PISemanticStyleRenderer.callback.before",
            @"renderer": SemanticRendererSummary(renderer),
        });
        BOOL result = originalBlock(renderer);
        AppendEvent(@{
            @"event": @"PISemanticStyleRenderer.callback.after",
            @"result": @(result),
            @"renderer": SemanticRendererSummary(renderer),
        });
        return result;
    };
    BOOL result = ((BOOL (*)(id, SEL, id, int, BOOL, id))gOriginalUsingSharedRenderer)(
        cls,
        selector,
        commandQueue,
        processingType,
        useStyleEngine,
        recordingBlock
    );
    AppendEvent(@{
        @"event": @"PISemanticStyleRenderer.usingShared.after",
        @"result": @(result),
        @"processingType": @(processingType),
        @"useStyleEngine": @(useStyleEngine),
    });
    return result;
}

static int RecordingSmartStyleStatus(id renderer, SEL selector) {
    NSString *selectorName = NSStringFromSelector(selector);
    NSString *processingTypeOverride = [NSProcessInfo processInfo]
        .environment[@"LEARNNODE_SMARTSTYLE_PROCESSING_TYPE_OVERRIDE"];
    if ([selectorName isEqualToString:@"process"] &&
        processingTypeOverride.length &&
        (processingTypeOverride.intValue & 0x4) != 0) {
        EnsureSmartStyleCodedLinearOutput(renderer);
        NSString *gainOverride = [NSProcessInfo processInfo]
            .environment[@"LEARNNODE_SMARTSTYLE_LINEAR_ENCODING_GAIN_OVERRIDE"];
        SEL gainSelector = NSSelectorFromString(@"setInputLinearEncodingGain:");
        if (gainOverride.length && [renderer respondsToSelector:gainSelector]) {
            SendFloatValue(renderer, gainSelector, gainOverride.floatValue);
        }
    }
    if ([selectorName isEqualToString:@"_encodeLinear"]) {
        RetainSmartStyleRendererResources(renderer, @"smartstyle_encode_linear_before");
    }
    AppendEvent(@{
        @"event": [NSString stringWithFormat:@"CMISmartStyleMetalRendererV1.%@.before",
                                            selectorName],
        @"renderer": SmartStyleRendererCompactSummary(renderer),
    });
    IMP original = [gOriginalSmartStyleMethods[selectorName] pointerValue];
    int result = ((int (*)(id, SEL))original)(renderer, selector);
    if ([selectorName isEqualToString:@"_encodeLinear"]) {
        RetainSmartStyleRendererResources(renderer, @"smartstyle_encode_linear_after");
    }
    if ([selectorName isEqualToString:@"process"]) {
        RetainSmartStyleRendererResources(renderer, @"smartstyle_renderer_process_after");
    }
    AppendEvent(@{
        @"event": [NSString stringWithFormat:@"CMISmartStyleMetalRendererV1.%@.after",
                                            selectorName],
        @"result": @(result),
        @"renderer": SmartStyleRendererCompactSummary(renderer),
    });
    return result;
}

static int RecordingSmartStylePrepare(id renderer, SEL selector, unsigned int processingType) {
    NSString *selectorName = NSStringFromSelector(selector);
    NSString *overrideValue = [NSProcessInfo processInfo]
        .environment[@"LEARNNODE_SMARTSTYLE_PROCESSING_TYPE_OVERRIDE"];
    unsigned int effectiveProcessingType = overrideValue.length
        ? (unsigned int)overrideValue.integerValue
        : processingType;
    AppendEvent(@{
        @"event": @"CMISmartStyleMetalRendererV1.prepareToProcess:.before",
        @"processingType": @(processingType),
        @"effectiveProcessingType": @(effectiveProcessingType),
        @"renderer": SmartStyleRendererCompactSummary(renderer),
    });
    IMP original = [gOriginalSmartStyleMethods[selectorName] pointerValue];
    int result = ((int (*)(id, SEL, unsigned int))original)(
        renderer, selector, effectiveProcessingType
    );
    AppendEvent(@{
        @"event": @"CMISmartStyleMetalRendererV1.prepareToProcess:.after",
        @"processingType": @(processingType),
        @"effectiveProcessingType": @(effectiveProcessingType),
        @"result": @(result),
        @"renderer": SmartStyleRendererCompactSummary(renderer),
    });
    return result;
}

static id RecordingAllocatorNewTexture(id allocator, SEL selector, id descriptor) {
    id result = ((id (*)(id, SEL, id))gOriginalAllocatorNewTexture)(
        allocator, selector, descriptor
    );
    AppendEvent(@{
        @"event": @"CMIGuidedFilter.allocator.newTextureWithDescriptor:",
        @"allocatorClass": NSStringFromClass([allocator class]),
        @"descriptor": TextureDescriptorSummary(descriptor),
        @"result": CompactObjectSummary(result),
        @"returnedNil": @(result == nil),
    });
    return result;
}

static int RecordingGuidedFilterEncode(
    id filter,
    SEL selector,
    id commandBuffer,
    id inputTexture,
    id guideTexture,
    id outputTexture,
    NSUInteger kernelRadius,
    float epsilon
) {
    id metal = IvarObjectValue(filter, @"_metal");
    SEL allocatorSelector = NSSelectorFromString(@"allocator");
    id allocator = [metal respondsToSelector:allocatorSelector]
        ? SendId(metal, allocatorSelector)
        : nil;
    Method allocatorMethod = allocator ? class_getInstanceMethod(
        [allocator class], NSSelectorFromString(@"newTextureWithDescriptor:")
    ) : NULL;
    BOOL allocatorHookInstalled = NO;
    if (allocatorMethod) {
        gOriginalAllocatorNewTexture = method_getImplementation(allocatorMethod);
        method_setImplementation(allocatorMethod, (IMP)RecordingAllocatorNewTexture);
        allocatorHookInstalled = YES;
    }
    AppendEvent(@{
        @"event": @"CMIGuidedFilter.encode.before",
        @"filterClass": NSStringFromClass([filter class]),
        @"commandBuffer": CompactObjectSummary(commandBuffer),
        @"inputTexture": CompactObjectSummary(inputTexture),
        @"guideTexture": CompactObjectSummary(guideTexture),
        @"outputTexture": CompactObjectSummary(outputTexture),
        @"kernelRadius": @(kernelRadius),
        @"epsilon": @(epsilon),
        @"metal": CompactObjectSummary(metal),
        @"allocator": CompactObjectSummary(allocator),
        @"allocatorHookInstalled": @(allocatorHookInstalled),
    });
    int result = 0;
    @try {
        result = ((int (*)(id, SEL, id, id, id, id, NSUInteger, float))
            gOriginalGuidedFilterEncode)(
                filter,
                selector,
                commandBuffer,
                inputTexture,
                guideTexture,
                outputTexture,
                kernelRadius,
                epsilon
            );
    } @finally {
        if (allocatorHookInstalled) {
            method_setImplementation(allocatorMethod, gOriginalAllocatorNewTexture);
        }
    }
    AppendEvent(@{
        @"event": @"CMIGuidedFilter.encode.after",
        @"result": @(result),
        @"allocatorHookRestored": @(!allocatorHookInstalled ||
            method_getImplementation(allocatorMethod) == gOriginalAllocatorNewTexture),
    });
    return result;
}

static int RecordingCMIProcess(id processor, SEL selector) {
    gLastCMIProcessor = processor;
    RetainCMIResources(processor, @"process.before", YES);
    AppendEvent(@{
        @"event": @"CMIStyleEngineProcessor.process.before",
        @"processor": ProcessorSummary(processor),
    });
    int result = ((int (*)(id, SEL))gOriginalCMIProcess)(processor, selector);
    RetainCMIResources(processor, @"process.after", YES);
    AppendEvent(@{
        @"event": @"CMIStyleEngineProcessor.process.after",
        @"result": @(result),
        @"processor": ProcessorSummary(processor),
    });
    return result;
}

static id ValueForDescribedKey(NSDictionary *dictionary, NSString *description) {
    for (id key in dictionary) {
        if ([[key description] isEqualToString:description]) {
            return dictionary[key];
        }
    }
    return nil;
}

static CIImage *LoadImage(NSString *path, BOOL applyOrientation) {
    if (!path || [path isEqualToString:@"-"]) {
        return nil;
    }
    if ([path hasSuffix:@".rgba16f.bin"]) {
        NSString *sidecarPath = [path stringByAppendingString:@".json"];
        NSData *sidecarData = [NSData dataWithContentsOfFile:sidecarPath];
        NSDictionary *sidecar = sidecarData
            ? [NSJSONSerialization JSONObjectWithData:sidecarData options:0 error:nil]
            : nil;
        NSNumber *widthValue = sidecar[@"width"];
        NSNumber *heightValue = sidecar[@"height"];
        NSInteger width = widthValue.integerValue;
        NSInteger height = heightValue.integerValue;
        NSData *pixels = [NSData dataWithContentsOfFile:path];
        NSUInteger expectedLength = (NSUInteger)width * (NSUInteger)height * 8;
        if (width <= 0 || height <= 0 || pixels.length != expectedLength) {
            return nil;
        }
        return [CIImage imageWithBitmapData:pixels
                               bytesPerRow:(NSUInteger)width * 8
                                      size:CGSizeMake(width, height)
                                    format:kCIFormatRGBAh
                                colorSpace:nil];
    }
    return [CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:path]
                                  options:@{
        kCIImageApplyOrientationProperty: @(applyOrientation),
    }];
}

static CIImage *BlackImage(CGRect extent) {
    return [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
        imageByCroppingToRect:extent];
}

static CGSize SemanticStyleRenderSize(CGSize inputSize) {
    return inputSize.width >= inputSize.height
        ? CGSizeMake(256, 192)
        : CGSizeMake(192, 256);
}

static CIImage *ScaleImageToSize(CIImage *image, CGSize targetSize) {
    CGRect extent = image.extent;
    CIImage *originNormalized = [image imageByApplyingTransform:
        CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
    CGFloat scaleY = targetSize.height / extent.size.height;
    CGFloat scaleX = targetSize.width / extent.size.width;
    CIImage *scaled = [originNormalized imageByApplyingFilter:@"CILanczosScaleTransform"
                                         withInputParameters:@{
        kCIInputScaleKey: @(scaleY),
        kCIInputAspectRatioKey: @(scaleX / scaleY),
    }];
    return [scaled imageByCroppingToRect:CGRectMake(
        0, 0, targetSize.width, targetSize.height
    )];
}

static CIImage *NormalizeLinearThumbnail(
    CIImage *image,
    BOOL applyInverseCurve,
    double linearGain,
    double linearRangeMin,
    double linearRangeMax
) {
    CIImage *result = image;
    if (applyInverseCurve) {
        result = [result imageByApplyingFilter:@"CIAppleLogToLinear"];
    }
    double scale = linearGain != 0.0 ? 1.0 / linearGain : 1.0;
    result = [result imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{
        @"inputRVector": [CIVector vectorWithX:scale Y:0 Z:0 W:0],
        @"inputGVector": [CIVector vectorWithX:0 Y:scale Z:0 W:0],
        @"inputBVector": [CIVector vectorWithX:0 Y:0 Z:scale W:0],
        @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:1],
        @"inputBiasVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0],
    }];
    return [result imageByApplyingFilter:@"CIColorClamp" withInputParameters:@{
        @"inputMinComponents": [CIVector vectorWithX:linearRangeMin
                                                   Y:linearRangeMin
                                                   Z:linearRangeMin
                                                   W:0],
        @"inputMaxComponents": [CIVector vectorWithX:linearRangeMax
                                                   Y:linearRangeMax
                                                   Z:linearRangeMax
                                                   W:1],
    }];
}

static BOOL RenderHalfRGBA(
    CIContext *context,
    CIImage *image,
    NSString *path,
    NSError **error
) {
    size_t width = (size_t)llround(image.extent.size.width);
    size_t height = (size_t)llround(image.extent.size.height);
    size_t rowBytes = width * 4 * sizeof(uint16_t);
    NSMutableData *data = [NSMutableData dataWithLength:rowBytes * height];
    @try {
        [context render:image
               toBitmap:data.mutableBytes
               rowBytes:rowBytes
                 bounds:image.extent
                 format:kCIFormatRGBAh
             colorSpace:NULL];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:3
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
            }];
        }
        return NO;
    }
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

static float FloatFromHalfBits(uint16_t bits) {
    _Float16 value;
    memcpy(&value, &bits, sizeof(value));
    return (float)value;
}

static uint16_t HalfBitsFromFloat(float value) {
    _Float16 half = (_Float16)value;
    uint16_t bits;
    memcpy(&bits, &half, sizeof(bits));
    return bits;
}

static NSMutableData *ComposeLearnedWithIdentityRelativeKey1(
    NSData *learned,
    NSData *key1,
    NSDictionary **summary
) {
    if (!learned || learned.length != key1.length || learned.length % sizeof(uint16_t) != 0) {
        return nil;
    }
    NSUInteger count = learned.length / sizeof(uint16_t);
    const uint16_t *learnedValues = learned.bytes;
    const uint16_t *key1Values = key1.bytes;
    NSMutableData *result = [NSMutableData dataWithLength:learned.length];
    uint16_t *output = result.mutableBytes;
    float maximumCorrection = 0.0f;
    NSUInteger nonZeroCorrections = 0;
    for (NSUInteger index = 0; index < count; index++) {
        NSUInteger blockIndex = index % 30;
        float identity = blockIndex == 3 || blockIndex == 7 || blockIndex == 11
            ? 1.0f
            : 0.0f;
        float correction = FloatFromHalfBits(key1Values[index]) - identity;
        float value = FloatFromHalfBits(learnedValues[index]) + correction;
        if (!isfinite(correction) || !isfinite(value)) {
            return nil;
        }
        maximumCorrection = fmaxf(maximumCorrection, fabsf(correction));
        nonZeroCorrections += correction != 0.0f;
        output[index] = HalfBitsFromFloat(value);
    }
    if (summary) {
        *summary = @{
            @"formula": @"composed[i] = learned[i] + embeddedKey1[i] - completeIdentity[i]",
            @"valueCount": @(count),
            @"nonZeroCorrectionCount": @(nonZeroCorrections),
            @"maximumAbsoluteCorrection": @(maximumCorrection),
            @"status": @"experimental local composition; not a recovered camera serializer rule",
        };
    }
    return result;
}

static NSDictionary *CompositionSelfTest(void) {
    const NSUInteger valueCount = 60;
    NSMutableData *learned = [NSMutableData dataWithLength:valueCount * sizeof(uint16_t)];
    NSMutableData *identity = [NSMutableData dataWithLength:learned.length];
    uint16_t *learnedValues = learned.mutableBytes;
    uint16_t *identityValues = identity.mutableBytes;
    for (NSUInteger index = 0; index < valueCount; index++) {
        NSUInteger blockIndex = index % 30;
        float identityValue = blockIndex == 3 || blockIndex == 7 || blockIndex == 11
            ? 1.0f
            : 0.0f;
        learnedValues[index] = HalfBitsFromFloat(identityValue + (float)(index % 7) / 128.0f);
        identityValues[index] = HalfBitsFromFloat(identityValue);
    }

    NSDictionary *identitySummary = nil;
    NSData *identityComposed = ComposeLearnedWithIdentityRelativeKey1(
        learned,
        identity,
        &identitySummary
    );
    NSMutableData *perturbed = [identity mutableCopy];
    ((uint16_t *)perturbed.mutableBytes)[0] = HalfBitsFromFloat(1.0f / 64.0f);
    NSDictionary *perturbedSummary = nil;
    NSData *perturbedComposed = ComposeLearnedWithIdentityRelativeKey1(
        learned,
        perturbed,
        &perturbedSummary
    );
    BOOL identityIsByteIdentical = [identityComposed isEqualToData:learned];
    BOOL perturbationChangesBytes = perturbedComposed &&
        ![perturbedComposed isEqualToData:learned];
    BOOL passed = identityIsByteIdentical && perturbationChangesBytes;
    return @{
        @"schema": @"learnnode-key1-composition-self-test-v1",
        @"passed": @(passed),
        @"identityIsByteIdentical": @(identityIsByteIdentical),
        @"perturbationChangesBytes": @(perturbationChangesBytes),
        @"identitySummary": identitySummary ?: (id)[NSNull null],
        @"perturbedSummary": perturbedSummary ?: (id)[NSNull null],
    };
}

static CIImage *SemanticTarget(
    CIImage *input,
    NSString *imagePath,
    NSString *metadataPath,
    NSString *linearThumbnailPath,
    NSString *subjectMattePath,
    NSString *skinMattePath,
    NSString *skyMattePath,
    NSDictionary **capture,
    NSData **nativeStyleData,
    NSError **error
) {
    NSData *metadata = [NSData dataWithContentsOfFile:metadataPath options:0 error:error];
    if (!metadata) {
        return nil;
    }
    Class propertiesClass = NSClassFromString(@"_NUSemanticStyleProperties");
    id properties = SendClassObjectError(
        propertiesClass,
        NSSelectorFromString(@"semanticStylePropertiesFromImageMetadata:error:"),
        metadata,
        error
    );
    if (!properties) {
        return nil;
    }
    if (nativeStyleData) {
        *nativeStyleData = SendId(properties, NSSelectorFromString(@"styleData"));
    }

    CGImageSourceRef source = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:imagePath],
        NULL
    );
    NSDictionary *imageProperties = source
        ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL))
        : nil;
    if (source) {
        CFRelease(source);
    }
    NSDictionary *makerApple = imageProperties[(NSString *)kCGImagePropertyMakerAppleDictionary];
    id maker84 = ValueForDescribedKey(makerApple, @"84");
    typedef id (*SettingsFromMakerNoteFunction)(id);
    SettingsFromMakerNoteFunction settingsFromMakerNote =
        (SettingsFromMakerNoteFunction)dlsym(
            RTLD_DEFAULT,
            "PISemanticStyleSettingsFromMakerNoteProperties"
        );
    NSDictionary *environment = [NSProcessInfo processInfo].environment;
    NSDictionary *styleSettings = settingsFromMakerNote && maker84
        ? settingsFromMakerNote(maker84)
        : nil;
    if (![styleSettings isKindOfClass:[NSDictionary class]]) {
        if ([environment[@"XDREMUX_STYLE_ALLOW_DEFAULT_SETTINGS"] boolValue]) {
            styleSettings = @{
                @"cast": @"Standard",
                @"tone": @0.0,
                @"color": @0.0,
                @"intensity": @1.0,
            };
        } else {
            if (error) {
                *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                             code:4
                                         userInfo:@{
                    NSLocalizedDescriptionKey: @"failed to derive style settings from MakerApple 84",
                }];
            }
            return nil;
        }
    }

    CIImage *linearThumbnail = LoadImage(linearThumbnailPath, NO);
    if (!linearThumbnail) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:5
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"failed to load linear thumbnail",
            }];
        }
        return nil;
    }
    id version = SendId(properties, NSSelectorFromString(@"version"));
    NSInteger versionMinor = version && [version respondsToSelector:NSSelectorFromString(@"minor")]
        ? SendInteger(version, NSSelectorFromString(@"minor"))
        : 0;
    BOOL applyInverseCurve = versionMinor >= 10;
    NSMutableDictionary *effectiveStyleSettings = [styleSettings mutableCopy];
    NSMutableDictionary *styleSettingOverrides = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSString *> *numericOverrides = @{
        @"tone": @"XDREMUX_STYLE_RENDER_TONE",
        @"color": @"XDREMUX_STYLE_RENDER_COLOR",
        @"intensity": @"XDREMUX_STYLE_RENDER_INTENSITY",
    };
    for (NSString *settingName in numericOverrides) {
        NSString *environmentName = numericOverrides[settingName];
        NSString *rawValue = environment[environmentName];
        if (rawValue) {
            NSNumber *value = @([rawValue doubleValue]);
            effectiveStyleSettings[settingName] = value;
            styleSettingOverrides[settingName] = @{
                @"environment": environmentName,
                @"value": value,
            };
        }
    }
    NSString *castOverride = environment[@"XDREMUX_STYLE_RENDER_CAST"];
    if (castOverride.length > 0) {
        effectiveStyleSettings[@"cast"] = castOverride;
        styleSettingOverrides[@"cast"] = @{
            @"environment": @"XDREMUX_STYLE_RENDER_CAST",
            @"value": castOverride,
        };
    }
    styleSettings = effectiveStyleSettings;
    NSString *inverseOverride = environment[@"LEARNNODE_APPLY_INVERSE_CURVE"];
    if (inverseOverride) {
        applyInverseCurve = inverseOverride.boolValue;
    }
    BOOL useStyleEngine = [environment[@"LEARNNODE_USE_STYLE_ENGINE"] boolValue];
    double linearGain = [SendId(properties, NSSelectorFromString(@"linearGain")) doubleValue];
    double linearRangeMin = [SendId(
        properties,
        NSSelectorFromString(@"linearRangeMin")
    ) doubleValue];
    double linearRangeMax = [SendId(
        properties,
        NSSelectorFromString(@"linearRangeMax")
    ) doubleValue];
    linearThumbnail = NormalizeLinearThumbnail(
        linearThumbnail,
        applyInverseCurve,
        linearGain,
        linearRangeMin,
        linearRangeMax
    );

    CGSize semanticRenderSize = SemanticStyleRenderSize(input.extent.size);
    CIImage *semanticInput = ScaleImageToSize(input, semanticRenderSize);
    CIImage *black = BlackImage(semanticInput.extent);
    CIImage *subjectSource = LoadImage(subjectMattePath, NO);
    CIImage *skinSource = LoadImage(skinMattePath, NO);
    CIImage *skySource = LoadImage(skyMattePath, NO);
    CIImage *subject = subjectSource
        ? ScaleImageToSize(subjectSource, semanticRenderSize)
        : black;
    CIImage *skin = skinSource
        ? ScaleImageToSize(skinSource, semanticRenderSize)
        : black;
    CIImage *sky = skySource
        ? ScaleImageToSize(skySource, semanticRenderSize)
        : black;
    id filter = SendId(SendId((id)NSClassFromString(@"PISemanticStyleFilter"),
                              sel_registerName("alloc")),
                       sel_registerName("init"));
    SendObject(filter, NSSelectorFromString(@"setInputImage:"), semanticInput);
    SendObject(filter, NSSelectorFromString(@"setInputSubjectMatteImage:"), subject);
    SendObject(filter, NSSelectorFromString(@"setInputSkinMatteImage:"), skin);
    SendObject(filter, NSSelectorFromString(@"setInputSkyMatteImage:"), sky);
    SendObject(filter, NSSelectorFromString(@"setInputLinearThumbnailImage:"), linearThumbnail);
    SendObject(filter, NSSelectorFromString(@"setInputGainMapImage:"), black);
    SendDoubleValue(filter, NSSelectorFromString(@"setInputToneBias:"),
                    [styleSettings[@"tone"] doubleValue]);
    SendDoubleValue(filter, NSSelectorFromString(@"setInputColorBias:"),
                    [styleSettings[@"color"] doubleValue]);
    SendObject(filter, NSSelectorFromString(@"setInputCast:"),
               styleSettings[@"cast"] ?: @"Standard");
    SendDoubleValue(filter, NSSelectorFromString(@"setInputIntensity:"),
                    [styleSettings[@"intensity"] doubleValue]);
    SendObject(filter, NSSelectorFromString(@"setInputSceneType:"),
               SendId(properties, NSSelectorFromString(@"sceneType")));
    SendObject(filter, NSSelectorFromString(@"setInputTRCData:"),
               SendId(properties, NSSelectorFromString(@"globalToneCurveData")));
    SendDoubleValue(filter, NSSelectorFromString(@"setInputBaselineExposure:"),
                    SendDouble(properties, NSSelectorFromString(@"baselineExposure")));
    SendObject(filter, NSSelectorFromString(@"setInputSRLCurveParameter:"),
               SendId(properties, NSSelectorFromString(@"subjectRelightingValue")));
    SendObject(filter, NSSelectorFromString(@"setInputStatistics:"),
               SendId(properties, NSSelectorFromString(@"stats")));
    SendObject(filter, NSSelectorFromString(@"setInputExtendedStatistics:"),
               SendId(properties, NSSelectorFromString(@"extendedStats")));
    SendObject(filter, NSSelectorFromString(@"setInputLightMapData:"),
               SendId(properties, NSSelectorFromString(@"lightMapData")));
    SendObject(filter, NSSelectorFromString(@"setInputLinearLightMapData:"),
               SendId(properties, NSSelectorFromString(@"linearLightMapData")));
    SendObject(filter, NSSelectorFromString(@"setInputLightMapWidth:"),
               SendId(properties, NSSelectorFromString(@"lightMapWidth")));
    SendObject(filter, NSSelectorFromString(@"setInputLightMapHeight:"),
               SendId(properties, NSSelectorFromString(@"lightMapHeight")));
    SendObject(filter, NSSelectorFromString(@"setBrightnessValue:"),
               SendId(properties, NSSelectorFromString(@"brightness")));
    SendObject(filter, NSSelectorFromString(@"setTuningType:"),
               SendId(properties, NSSelectorFromString(@"tuningType")));
    SendObject(filter, NSSelectorFromString(@"setBaseGain:"),
               SendId(properties, NSSelectorFromString(@"baseGain")));
    SendObject(filter, NSSelectorFromString(@"setFaceBasedGlobalExposureBoostRatio:"),
               SendId(properties, NSSelectorFromString(@"faceBasedGlobalExposureBoostRatio")));
    SendBoolValue(filter, NSSelectorFromString(@"setUseStyleEngine:"), useStyleEngine);

    CIImage *target = SendId(filter, NSSelectorFromString(@"outputImage"));
    if (capture) {
        *capture = @{
            @"metadataPath": metadataPath,
            @"metadataLength": @(metadata.length),
            @"propertiesClass": NSStringFromClass([properties class]),
            @"version": version ? [version description] : (id)[NSNull null],
            @"versionMinor": @(versionMinor),
            @"styleSettings": JSONSafe(styleSettings),
            @"styleSettingOverrides": JSONSafe(styleSettingOverrides),
            @"applyInverseCurveToLinearThumbnail": @(applyInverseCurve),
            @"applyInverseCurveSource": inverseOverride
                ? @"LEARNNODE_APPLY_INVERSE_CURVE"
                : @"static still-image version-minor gate",
            @"useStyleEngine": @(useStyleEngine),
            @"useStyleEngineSource": environment[@"LEARNNODE_USE_STYLE_ENGINE"]
                ? @"LEARNNODE_USE_STYLE_ENGINE"
                : @"absent adjustment setting defaults false",
            @"linearGain": @(linearGain),
            @"linearRangeMin": @(linearRangeMin),
            @"linearRangeMax": @(linearRangeMax),
            @"inputPolicy": @{
                @"main": imagePath,
                @"mainAndMatteRenderSize": @{
                    @"width": @(semanticRenderSize.width),
                    @"height": @(semanticRenderSize.height),
                },
                @"mainAndMatteScaleSource": @"PISemanticStyleRenderNode replay geometry",
                @"linearThumbnail": linearThumbnailPath,
                @"subjectMatte": subjectMattePath,
                @"skinMatte": skinMattePath,
                @"skyMatte": skyMattePath,
                @"gainMap": @"cropped black CIImage; no HEIC gain auxiliary",
            },
            @"filterClass": NSStringFromClass([filter class]),
            @"filterIvars": ObjectIvarSummary(filter),
            @"target": target ? @{
                @"class": NSStringFromClass([target class]),
                @"extent": (
#if TARGET_OS_OSX
            XDRemuxRectToString(target.extent)
#else
            XDRemuxRectToString(target.extent)
#endif
        ),
                @"description": [target description] ?: @"",
            } : (id)[NSNull null],
        };
    }
    return target;
}

static NSDictionary *FindNestedDictionary(
    NSDictionary *settings,
    NSString *preferredKey,
    NSString *requiredKey
) {
    id preferred = settings[preferredKey];
    if ([preferred isKindOfClass:[NSDictionary class]]) {
        return preferred;
    }
    for (id key in settings) {
        id candidate = settings[key];
        if ([candidate isKindOfClass:[NSDictionary class]] && candidate[requiredKey] != nil) {
            return candidate;
        }
    }
    return nil;
}

static BOOL WriteJSON(NSDictionary *object, NSString *path, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:JSONSafe(object)
                                                   options:NSJSONWritingPrettyPrinted |
                                                           NSJSONWritingSortedKeys
                                                     error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

static NSData *RawDeflate(NSData *input, NSError **error) {
    z_stream stream = {0};
    int status = deflateInit2(
        &stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY
    );
    if (status != Z_OK) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:30
                                     userInfo:@{NSLocalizedDescriptionKey: @"raw deflate initialization failed"}];
        }
        return nil;
    }
    NSMutableData *output = [NSMutableData dataWithLength:compressBound((uLong)input.length)];
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;
    stream.next_out = output.mutableBytes;
    stream.avail_out = (uInt)output.length;
    status = deflate(&stream, Z_FINISH);
    if (status != Z_STREAM_END) {
        deflateEnd(&stream);
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:31
                                     userInfo:@{NSLocalizedDescriptionKey: @"raw deflate failed"}];
        }
        return nil;
    }
    output.length = stream.total_out;
    deflateEnd(&stream);
    return output;
}

static CGImageRef CopyCGImageFromObject(id object) {
    if (!object) {
        return NULL;
    }
    CFTypeRef value = (__bridge CFTypeRef)object;
    if (CFGetTypeID(value) == CGImageGetTypeID()) {
        return CGImageRetain((CGImageRef)value);
    }
#if TARGET_OS_OSX
    if ([object isKindOfClass:[NSImage class]]) {
        NSImage *nsImage = (NSImage *)object;
        NSRect rect = NSMakeRect(0, 0, nsImage.size.width, nsImage.size.height);
        CGImageRef image = [nsImage CGImageForProposedRect:&rect context:nil hints:nil];
        return image ? CGImageRetain(image) : NULL;
    }
#endif
    if ([object respondsToSelector:NSSelectorFromString(@"CGImage")]) {
        CGImageRef image = ((CGImageRef (*)(id, SEL))objc_msgSend)(
            object, NSSelectorFromString(@"CGImage")
        );
        return image ? CGImageRetain(image) : NULL;
    }
    return NULL;
}

static BOOL WritePNG(CGImageRef image, NSString *path, NSError **error) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (directory.length && ![[NSFileManager defaultManager]
            createDirectoryAtPath:directory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:error]) {
        return NO;
    }
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL
    );
    if (!destination) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:32
                                     userInfo:@{NSLocalizedDescriptionKey: @"cannot create render PNG destination"}];
        }
        return NO;
    }
    CGImageDestinationAddImage(destination, image, NULL);
    BOOL written = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (!written && error) {
        *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                     code:33
                                 userInfo:@{NSLocalizedDescriptionKey: @"cannot finalize render PNG"}];
    }
    return written;
}

static NSDictionary *RunNeutrinoStyleRender(
    NSString *photoPath,
    NSString *outputPath,
    NSString *manifestPath,
    double tone,
    double color,
    double intensity,
    BOOL enabled,
    NSUInteger maximumDimension,
    NSString *cast
) {
    __block CFAbsoluteTime stageStartedAt = CFAbsoluteTimeGetCurrent();
    NSMutableDictionary *stageMilliseconds = [NSMutableDictionary dictionary];
    void (^recordStage)(NSString *) = ^(NSString *stage) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        stageMilliseconds[stage] = @((now - stageStartedAt) * 1000.0);
        stageStartedAt = now;
    };
    NSArray<NSString *> *frameworks = @[
        @"/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore",
        @"/System/Library/PrivateFrameworks/PhotoImaging.framework/PhotoImaging",
        @"/System/Library/PrivateFrameworks/PhotosUICore.framework/PhotosUICore",
        @"/System/Library/PrivateFrameworks/PhotosUIPrivate.framework/PhotosUIPrivate",
    ];
    NSMutableArray *loadResults = [NSMutableArray array];
    BOOL frameworksLoaded = YES;
    for (NSString *path in frameworks) {
        BOOL loaded = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL;
        frameworksLoaded = frameworksLoaded && loaded;
        [loadResults addObject:@{ @"path": path, @"loaded": @(loaded) }];
    }
    recordStage(@"frameworksMs");
    NSMutableDictionary *result = [@{
        @"schema": @"xdremux-neutrino-style-render-v1",
        @"photo": photoPath,
        @"output": outputPath,
        @"settings": @{
            @"tone": @(tone), @"color": @(color), @"intensity": @(intensity),
            @"enabled": @(enabled), @"cast": cast,
        },
        @"maximumDimension": @(maximumDimension),
        @"frameworks": loadResults,
    } mutableCopy];
    if (!frameworksLoaded) {
        result[@"status"] = @"framework_load_failed";
        WriteJSON(result, manifestPath, NULL);
        return result;
    }

    NSURL *photoURL = [NSURL fileURLWithPath:photoPath];
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)photoURL, NULL);
    NSDictionary *properties = imageSource
        ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL))
        : nil;
    if (imageSource) {
        CFRelease(imageSource);
    }
    NSUInteger width = [properties[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    NSInteger orientation = [properties[(id)kCGImagePropertyOrientation] integerValue];
    if (orientation == 0) {
        orientation = 1;
    }
    if (width == 0 || height == 0) {
        result[@"status"] = @"image_properties_failed";
        WriteJSON(result, manifestPath, NULL);
        return result;
    }
    recordStage(@"imagePropertiesMs");

    NSDictionary *recipe = @{
        @"metadata": @{
            @"masterHeight": @(height), @"masterWidth": @(width),
            @"orientation": @(orientation),
        },
        @"formatVersion": @1,
        @"versionInfo": @{
            @"buildNumber": @"23F84", @"appVersion": @"XDRemux",
            @"schemaRevision": @0, @"platform": @"macOS",
        },
        @"adjustments": @[@{
            @"formatVersion": @1,
            @"enabled": @(enabled),
            @"settings": @{
                @"version": @1, @"tone": @(tone), @"enabled": @(enabled),
                @"cast": cast, @"intensity": @(intensity), @"color": @(color),
            },
            @"identifier": @"SemanticStyle",
            @"formatIdentifier": @"com.apple.photo",
        }],
    };
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:recipe options:0 error:&error];
    NSData *adjustmentData = json ? RawDeflate(json, &error) : nil;
    if (!adjustmentData) {
        result[@"status"] = @"adjustment_creation_failed";
        result[@"error"] = JSONSafe(error);
        WriteJSON(result, manifestPath, NULL);
        return result;
    }

    Class rendererClass = NSClassFromString(@"PLPhotoEditRenderer");
    ((void (*)(id, SEL))objc_msgSend)(
        rendererClass, NSSelectorFromString(@"configureNeutrinoCacheDirectoryIfNeeded")
    );
    Class sourceClass = NSClassFromString(@"PLPhotoEditSource");
    id sourceObject = ((id (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(
        [sourceClass alloc],
        NSSelectorFromString(@"initWithURL:type:image:useEmbeddedPreview:"),
        photoURL, @"public.heic", nil, NO
    );
    id renderer = ((id (*)(id, SEL, id))objc_msgSend)(
        [rendererClass alloc], NSSelectorFromString(@"initWithEditSource:"), sourceObject
    );
    Class importClass = NSClassFromString(@"PLPhotoEditImportProperties");
    id importProperties = ((id (*)(id, SEL, NSInteger))objc_msgSend)(
        importClass, NSSelectorFromString(@"importPropertiesWithEXIFOrientation:"), orientation
    );
    id controller = ((id (*)(id, SEL, id, id, id, id, NSError **))objc_msgSend)(
        [NSClassFromString(@"PLPhotoEditPersistenceManager") new],
        NSSelectorFromString(@"loadPhotoEditData:formatIdentifier:formatVersion:importProperties:error:"),
        adjustmentData, @"com.apple.photo", @"1.12", importProperties, &error
    );
    if (renderer && controller) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            renderer, NSSelectorFromString(@"setCompositionController:"), controller
        );
    }
    if (!renderer || !controller) {
        result[@"status"] = @"renderer_creation_failed";
        result[@"error"] = JSONSafe(error);
        WriteJSON(result, manifestPath, NULL);
        return result;
    }
    recordStage(@"rendererSetupMs");

    double scale = maximumDimension > 0
        ? fmin(1.0, (double)maximumDimension / fmax((double)width, (double)height))
        : 1.0;
    CGSize targetSize = CGSizeMake(
        fmax(1.0, round((double)width * scale)),
        fmax(1.0, round((double)height * scale))
    );
    __block id completionImage = nil;
    __block BOOL completed = NO;
    void (^completion)(id, id) = ^(id image, __unused id info) {
        completionImage = image;
        completed = YES;
    };
    ((void (*)(id, SEL, CGSize, NSInteger, id, id))objc_msgSend)(
        renderer,
        NSSelectorFromString(@"renderImageWithTargetSize:contentMode:name:completion:"),
        targetSize, 0, @"XDRemux constrained key1 calibration", completion
    );
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:180.0];
    while (!completed && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    recordStage(@"renderMs");
    CGImageRef rendered = CopyCGImageFromObject(completionImage);
    BOOL written = rendered && WritePNG(rendered, outputPath, &error);
    recordStage(@"pngMs");
    if (rendered) {
        result[@"render"] = @{
            @"width": @(CGImageGetWidth(rendered)),
            @"height": @(CGImageGetHeight(rendered)),
            @"bitsPerComponent": @(CGImageGetBitsPerComponent(rendered)),
            @"bitsPerPixel": @(CGImageGetBitsPerPixel(rendered)),
        };
        CGImageRelease(rendered);
    }
    result[@"status"] = written ? @"written" : (completed ? @"write_failed" : @"timeout");
    result[@"error"] = JSONSafe(error);
    result[@"stageMilliseconds"] = stageMilliseconds;
    WriteJSON(result, manifestPath, NULL);
    return result;
}

static NSDictionary *RunNeutrinoStyleRenderBatch(NSString *planPath) {
    NSError *error = nil;
    NSData *planData = [NSData dataWithContentsOfFile:planPath options:0 error:&error];
    NSDictionary *plan = planData
        ? [NSJSONSerialization JSONObjectWithData:planData options:0 error:&error]
        : nil;
    NSArray *requests = [plan isKindOfClass:[NSDictionary class]]
        && [plan[@"requests"] isKindOfClass:[NSArray class]]
        ? plan[@"requests"]
        : nil;
    if (!requests) {
        return @{
            @"schema": @"xdremux-neutrino-style-render-batch-result-v1",
            @"passed": @NO,
            @"failureCount": @1,
            @"renders": @[],
            @"error": JSONSafe(error ?: [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                                                  code:40
                                                              userInfo:@{
                NSLocalizedDescriptionKey: @"invalid render batch plan",
            }]),
        };
    }

    NSMutableArray *renders = [NSMutableArray arrayWithCapacity:requests.count];
    NSUInteger failureCount = 0;
    for (id value in requests) {
        @autoreleasepool {
            NSDictionary *request = [value isKindOfClass:[NSDictionary class]] ? value : nil;
            NSString *photo = [request[@"photo"] isKindOfClass:[NSString class]]
                ? [request[@"photo"] stringByStandardizingPath]
                : nil;
            NSString *output = [request[@"output"] isKindOfClass:[NSString class]]
                ? [request[@"output"] stringByStandardizingPath]
                : nil;
            NSString *manifest = [request[@"manifest"] isKindOfClass:[NSString class]]
                ? [request[@"manifest"] stringByStandardizingPath]
                : nil;
            NSNumber *tone = [request[@"tone"] isKindOfClass:[NSNumber class]]
                ? request[@"tone"]
                : nil;
            NSNumber *color = [request[@"color"] isKindOfClass:[NSNumber class]]
                ? request[@"color"]
                : nil;
            NSNumber *intensity = [request[@"intensity"] isKindOfClass:[NSNumber class]]
                ? request[@"intensity"]
                : nil;
            NSNumber *enabled = [request[@"enabled"] isKindOfClass:[NSNumber class]]
                ? request[@"enabled"]
                : nil;
            NSNumber *maximumDimension = [request[@"maximumDimension"] isKindOfClass:[NSNumber class]]
                ? request[@"maximumDimension"]
                : nil;
            NSString *cast = [request[@"cast"] isKindOfClass:[NSString class]]
                ? request[@"cast"]
                : @"Standard";
            if (!photo || !output || !manifest || !tone || !color || !intensity
                    || !enabled || !maximumDimension) {
                failureCount += 1;
                [renders addObject:@{
                    @"status": @"invalid_batch_request",
                    @"error": @"render batch request is missing a required field",
                }];
                continue;
            }
            NSDictionary *result = RunNeutrinoStyleRender(
                photo,
                output,
                manifest,
                tone.doubleValue,
                color.doubleValue,
                intensity.doubleValue,
                enabled.boolValue,
                maximumDimension.unsignedIntegerValue,
                cast
            );
            [renders addObject:result];
            if (![result[@"status"] isEqualToString:@"written"]) {
                failureCount += 1;
            }
        }
    }
    BOOL passed = failureCount == 0;
    return @{
        @"schema": @"xdremux-neutrino-style-render-batch-result-v1",
        @"passed": [NSNumber numberWithBool:passed],
        @"failureCount": @(failureCount),
        @"renders": renders,
        @"error": [NSNull null],
    };
}

static CVPixelBufferRef CreateHalfRGBAPixelBuffer(
    CIContext *context,
    CIImage *image,
    CGSize size,
    NSError **error
) {
    NSDictionary *attributes = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        (size_t)llround(size.width),
        (size_t)llround(size.height),
        kCVPixelFormatType_64RGBAHalf,
        (__bridge CFDictionaryRef)attributes,
        &buffer
    );
    if (status != kCVReturnSuccess || !buffer) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:20
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"CVPixelBufferCreate RGBAHalf failed: %d", status],
            }];
        }
        return NULL;
    }
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_P3_D65,
        kCVAttachmentMode_ShouldPropagate
    );
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_sRGB,
        kCVAttachmentMode_ShouldPropagate
    );
    CGColorSpaceRef displayP3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    if (displayP3) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferCGColorSpaceKey,
            displayP3,
            kCVAttachmentMode_ShouldPropagate
        );
    }
    CGRect bounds = CGRectMake(0, 0, size.width, size.height);
    CIImage *renderImage = image;
    if (!CGSizeEqualToSize(image.extent.size, size) ||
        image.extent.origin.x != 0 || image.extent.origin.y != 0) {
        CGFloat scaleX = size.width / image.extent.size.width;
        CGFloat scaleY = size.height / image.extent.size.height;
        renderImage = [[image imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-image.extent.origin.x,
                                             -image.extent.origin.y)]
            imageByApplyingTransform:CGAffineTransformMakeScale(scaleX, scaleY)];
    }
    @try {
        [context render:renderImage
        toCVPixelBuffer:buffer
                 bounds:bounds
             colorSpace:NULL];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:21
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
            }];
        }
        CFRelease(buffer);
        buffer = NULL;
    }
    if (displayP3) {
        CGColorSpaceRelease(displayP3);
    }
    return buffer;
}

static NSData *CopyOneComponentFloat32PixelBuffer(
    CVPixelBufferRef buffer,
    NSError **error
) {
    CVReturn status = CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    if (status != kCVReturnSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:22
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"CVPixelBufferLockBaseAddress failed: %d", status],
            }];
        }
        return nil;
    }
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const size_t sourceRowBytes = CVPixelBufferGetBytesPerRow(buffer);
    const size_t packedRowBytes = width * sizeof(float);
    NSMutableData *data = [NSMutableData dataWithLength:packedRowBytes * height];
    const uint8_t *source = CVPixelBufferGetBaseAddress(buffer);
    uint8_t *destination = data.mutableBytes;
    if (!source) {
        data = nil;
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:23
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"coefficient pixel buffer has no base address",
            }];
        }
    } else {
        for (size_t row = 0; row < height; row++) {
            memcpy(destination + row * packedRowBytes,
                   source + row * sourceRowBytes,
                   packedRowBytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return data;
}

static NSData *Float32CoefficientsToFloat16(NSData *float32Data, NSError **error) {
    if (float32Data.length % sizeof(float) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:24
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Float32 coefficient byte count is not aligned",
            }];
        }
        return nil;
    }
    const float *source = float32Data.bytes;
    const NSUInteger count = float32Data.length / sizeof(float);
    NSMutableData *result = [NSMutableData dataWithLength:count * sizeof(uint16_t)];
    uint16_t *destination = result.mutableBytes;
    for (NSUInteger index = 0; index < count; index++) {
        if (!isfinite(source[index])) {
            if (error) {
                *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                             code:25
                                         userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"non-finite Float32 coefficient at index %lu",
                        (unsigned long)index],
                }];
            }
            return nil;
        }
        __fp16 half = (__fp16)source[index];
        memcpy(&destination[index], &half, sizeof(uint16_t));
    }
    return result;
}

static NSDictionary *RunSmartStyleUtilityLearn(
    CIContext *context,
    id<MTLCommandQueue> commandQueue,
    CIImage *source,
    CIImage *target,
    NSString *outputDirectory
) {
    Class utilityClass = NSClassFromString(@"CMISmartStyleUtilitiesV1");
    if (!utilityClass) {
        return @{ @"status": @"class_missing" };
    }
    NSUInteger useCase = 1;
    NSString *useCaseValue = [NSProcessInfo processInfo]
        .environment[@"LEARNNODE_SMART_STYLE_USE_CASE"];
    if (useCaseValue.length) {
        useCase = (NSUInteger)useCaseValue.integerValue;
    }
    id utility = ((id (*)(id, SEL))objc_msgSend)(
        (id)utilityClass,
        sel_registerName("alloc")
    );
    utility = ((id (*)(id, SEL, id, NSUInteger, NSUInteger, id))objc_msgSend)(
        utility,
        NSSelectorFromString(
            @"initWithOptionalMetalCommandQueue:useCase:processingType:optionalExternalMemoryResource:"
        ),
        commandQueue,
        useCase,
        1,
        nil
    );
    if (!utility) {
        return @{
            @"status": @"initialization_failed",
            @"useCase": @(useCase),
        };
    }
    const size_t width = [[utility valueForKey:@"_coefficientsPixelBufferWidth"]
        unsignedIntegerValue];
    const size_t height = [[utility valueForKey:@"_coefficientsPixelBufferHeight"]
        unsignedIntegerValue];
    const OSType pixelFormat = (OSType)SendInteger(
        utility,
        NSSelectorFromString(@"coefficientsPixelBufferPixelFormat")
    );
    id engine = IvarObjectValue(utility, @"_styleEngineProcessor");
    id configuration = engine && [engine respondsToSelector:NSSelectorFromString(@"configuration")]
        ? SendId(engine, NSSelectorFromString(@"configuration"))
        : nil;
    CGSize thumbnailSize = configuration
        ? ((CGSize (*)(id, SEL))objc_msgSend)(
            configuration,
            NSSelectorFromString(@"thumbnailSize")
        )
        : source.extent.size;
    NSError *sourceError = nil;
    NSError *targetError = nil;
    CVPixelBufferRef sourceBuffer = CreateHalfRGBAPixelBuffer(
        context, source, thumbnailSize, &sourceError
    );
    CVPixelBufferRef targetBuffer = CreateHalfRGBAPixelBuffer(
        context, target, thumbnailSize, &targetError
    );
    CVPixelBufferRef coefficientBuffer = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn createStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        (__bridge CFDictionaryRef)attributes,
        &coefficientBuffer
    );
    int learnStatus = -1;
    NSInteger finishStatus = -1;
    id integratedCoefficients = nil;
    if (sourceBuffer && targetBuffer &&
        createStatus == kCVReturnSuccess && coefficientBuffer) {
        learnStatus = SendSmartStyleUtilityLearn(
            utility,
            NSSelectorFromString(
                @"learnTransformFrom:to:outputCoefficients:outputIntegratedCoefficients:"
            ),
            sourceBuffer,
            targetBuffer,
            coefficientBuffer,
            &integratedCoefficients
        );
        if (learnStatus == 0 && [utility respondsToSelector:NSSelectorFromString(@"forceMetalCachesFlush")]) {
            SendInteger(utility, NSSelectorFromString(@"forceMetalCachesFlush"));
        }
        if (learnStatus == 0 &&
            engine &&
            [engine respondsToSelector:NSSelectorFromString(@"finishProcessing")]) {
            finishStatus = SendInteger(engine, NSSelectorFromString(@"finishProcessing"));
        }
    }
    if (engine) {
        RetainCMIResources(engine, @"smartstyle_utility_after_process", YES);
    }
    if (integratedCoefficients &&
        [integratedCoefficients conformsToProtocol:@protocol(MTLTexture)]) {
        NSString *key = @"smartstyle_utility.outputIntegratedCoefficients";
        id<MTLTexture> texture = integratedCoefficients;
        gCapturedCMIResources[key] = texture;
        gCapturedCMIDescriptors[key] = @{
            @"captureStage": @"smartstyle_utility_after_process",
            @"source": @"CMISmartStyleUtilitiesV1 output parameter",
            @"sourceName": @"outputIntegratedCoefficients",
            @"kind": @"MTLTexture",
            @"width": @(texture.width),
            @"height": @(texture.height),
            @"arrayLength": @(texture.arrayLength),
            @"pixelFormat": @((NSUInteger)texture.pixelFormat),
            @"storageMode": @((NSUInteger)texture.storageMode),
        };
    }
    NSError *copyError = nil;
    NSData *float32 = coefficientBuffer && learnStatus == 0
        ? CopyOneComponentFloat32PixelBuffer(coefficientBuffer, &copyError)
        : nil;
    NSError *conversionError = nil;
    NSData *float16 = float32
        ? Float32CoefficientsToFloat16(float32, &conversionError)
        : nil;
    NSString *float32Path = [outputDirectory
        stringByAppendingPathComponent:@"smartstyle_utility_linear.f32.bin"];
    NSString *float16Path = [outputDirectory
        stringByAppendingPathComponent:@"smartstyle_utility_key1.f16.bin"];
    NSError *float32WriteError = nil;
    NSError *float16WriteError = nil;
    BOOL float32Written = float32 && [float32 writeToFile:float32Path
                                                    options:NSDataWritingAtomic
                                                      error:&float32WriteError];
    BOOL float16Written = float16 && [float16 writeToFile:float16Path
                                                    options:NSDataWritingAtomic
                                                      error:&float16WriteError];
    NSDictionary *summary = @{
        @"status": learnStatus == 0 && float32Written && float16Written
            ? @"success"
            : @"failed",
        @"useCase": @(useCase),
        @"processingType": @1,
        @"learnStatus": @(learnStatus),
        @"finishStatus": @(finishStatus),
        @"sourceError": JSONSafe(sourceError),
        @"targetError": JSONSafe(targetError),
        @"coefficientCreateStatus": @(createStatus),
        @"coefficientPixelFormat": @(pixelFormat),
        @"coefficientWidth": @(width),
        @"coefficientHeight": @(height),
        @"float32Path": float32Written ? float32Path : (id)[NSNull null],
        @"float32Length": float32 ? @(float32.length) : (id)[NSNull null],
        @"float16Path": float16Written ? float16Path : (id)[NSNull null],
        @"float16Length": float16 ? @(float16.length) : (id)[NSNull null],
        @"copyError": JSONSafe(copyError),
        @"conversionError": JSONSafe(conversionError),
        @"float32WriteError": JSONSafe(float32WriteError),
        @"float16WriteError": JSONSafe(float16WriteError),
        @"integratedCoefficients": integratedCoefficients
            ? TextureSummary(integratedCoefficients)
            : (id)[NSNull null],
        @"engine": engine ? ProcessorSummary(engine) : (id)[NSNull null],
    };
    if (sourceBuffer) CFRelease(sourceBuffer);
    if (targetBuffer) CFRelease(targetBuffer);
    if (coefficientBuffer) CFRelease(coefficientBuffer);
    return summary;
}

static NSDictionary *ReadSemanticStyleSettings(NSString *imagePath, NSError **error) {
    CGImageSourceRef source = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:imagePath],
        NULL
    );
    NSDictionary *properties = source
        ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL))
        : nil;
    if (source) {
        CFRelease(source);
    }
    if (!properties) {
        if (error) {
            *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                         code:40
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"failed to read image properties",
            }];
        }
        return nil;
    }
    NSDictionary *makerApple = properties[(NSString *)kCGImagePropertyMakerAppleDictionary];
    id maker84 = ValueForDescribedKey(makerApple, @"84");
    typedef id (*SettingsFromMakerNoteFunction)(id);
    SettingsFromMakerNoteFunction settingsFromMakerNote =
        (SettingsFromMakerNoteFunction)dlsym(
            RTLD_DEFAULT,
            "PISemanticStyleSettingsFromMakerNoteProperties"
        );
    NSDictionary *settings = settingsFromMakerNote && maker84
        ? settingsFromMakerNote(maker84)
        : nil;
    if (![settings isKindOfClass:[NSDictionary class]] && error) {
        *error = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                     code:41
                                 userInfo:@{
            NSLocalizedDescriptionKey: @"failed to derive style settings from MakerApple 84",
        }];
    }
    return [settings isKindOfClass:[NSDictionary class]] ? settings : nil;
}

int XDRemuxLearnNodeProbeMain(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL styleSettingsMode = argc == 3 &&
            strcmp(argv[1], "--style-settings") == 0;
        if (styleSettingsMode) {
            NSString *photoImagingPath =
                @"/System/Library/PrivateFrameworks/PhotoImaging.framework/PhotoImaging";
            BOOL frameworkLoaded = dlopen(
                photoImagingPath.UTF8String,
                RTLD_NOW | RTLD_GLOBAL
            ) != NULL;
            NSString *inputPath = [[NSString stringWithUTF8String:argv[2]]
                stringByStandardizingPath];
            NSError *settingsError = nil;
            NSDictionary *settings = frameworkLoaded
                ? ReadSemanticStyleSettings(inputPath, &settingsError)
                : nil;
            NSDictionary *result = @{
                @"schema": @"xdremux-semantic-style-settings-probe-v1",
                @"input": inputPath,
                @"frameworkLoaded": @(frameworkLoaded),
                @"settings": settings ?: (id)[NSNull null],
                @"error": JSONSafe(settingsError),
                @"passed": @(settings != nil),
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:JSONSafe(result)
                                                           options:NSJSONWritingSortedKeys
                                                             error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return settings ? 0 : 1;
        }
        BOOL renderStyleMode = (argc == 10 || argc == 11) &&
            strcmp(argv[1], "--render-style") == 0;
        if (renderStyleMode) {
            NSDictionary *result = RunNeutrinoStyleRender(
                [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath],
                [[NSString stringWithUTF8String:argv[3]] stringByStandardizingPath],
                [[NSString stringWithUTF8String:argv[4]] stringByStandardizingPath],
                strtod(argv[5], NULL),
                strtod(argv[6], NULL),
                strtod(argv[7], NULL),
                strtol(argv[8], NULL, 10) != 0,
                (NSUInteger)strtoull(argv[9], NULL, 10),
                argc == 11 ? [NSString stringWithUTF8String:argv[10]] : @"Standard"
            );
            NSData *json = [NSJSONSerialization dataWithJSONObject:JSONSafe(result)
                                                           options:NSJSONWritingSortedKeys
                                                             error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return [result[@"status"] isEqualToString:@"written"] ? 0 : 1;
        }
        BOOL renderStyleBatchMode = argc == 3 &&
            strcmp(argv[1], "--render-style-batch") == 0;
        if (renderStyleBatchMode) {
            NSDictionary *result = RunNeutrinoStyleRenderBatch(
                [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath]
            );
            NSData *json = [NSJSONSerialization dataWithJSONObject:JSONSafe(result)
                                                           options:NSJSONWritingSortedKeys
                                                             error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return [result[@"passed"] boolValue] ? 0 : 1;
        }
        BOOL compositionSelfTest = argc == 2 &&
            strcmp(argv[1], "--self-test-composition") == 0;
        if (compositionSelfTest) {
            NSDictionary *result = CompositionSelfTest();
            NSError *serializationError = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                           options:NSJSONWritingSortedKeys
                                                             error:&serializationError];
            if (!json || serializationError) {
                fprintf(stderr, "%s\n", serializationError.localizedDescription.UTF8String);
                return 1;
            }
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return [result[@"passed"] boolValue] ? 0 : 1;
        }
        BOOL semanticMode = argc == 9 && strcmp(argv[1], "--semantic") == 0;
        BOOL directMode = argc == 4;
        if (!semanticMode && !directMode) {
            fprintf(stderr,
                    "usage: %s input-image target-image output-directory\n"
                    "       %s --semantic image.heic style-metadata.bplist "
                    "linear-thumbnail subject-matte skin-matte sky-matte output-directory\n"
                    "       %s --render-style image.heic output.png manifest.json "
                    "tone color intensity enabled maximum-dimension [cast]\n"
                    "       %s --render-style-batch plan.json\n"
                    "       %s --style-settings image.heic\n"
                    "       %s --self-test-composition\n",
                    argv[0], argv[0], argv[0], argv[0], argv[0], argv[0]);
            return 2;
        }
        int inputIndex = semanticMode ? 2 : 1;
        int outputIndex = semanticMode ? 8 : 3;
        NSString *inputPath = [[NSString stringWithUTF8String:argv[inputIndex]]
            stringByStandardizingPath];
        NSString *targetPath = directMode
            ? [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath]
            : @"<PISemanticStyleFilter output>";
        NSString *outputDirectory = [[NSString stringWithUTF8String:argv[outputIndex]]
            stringByStandardizingPath];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:outputDirectory
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        void *neutrino = dlopen(
            "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore",
            RTLD_NOW
        );
        void *photoImaging = dlopen(
            "/System/Library/PrivateFrameworks/PhotoImaging.framework/PhotoImaging",
            RTLD_NOW
        );
        void *cmImaging = dlopen(
            "/System/Library/PrivateFrameworks/CMImaging.framework/CMImaging",
            RTLD_NOW
        );
        if (!neutrino || !photoImaging || !cmImaging) {
            fprintf(stderr, "failed to load private frameworks\n");
            return 1;
        }

        CIImage *input = LoadImage(inputPath, YES);
        CIImage *target = directMode ? LoadImage(targetPath, YES) : nil;
        NSDictionary *semanticCapture = nil;
        NSData *nativeStyleData = nil;
        NSError *semanticError = nil;
        if (semanticMode && input) {
            target = SemanticTarget(
                input,
                inputPath,
                [[NSString stringWithUTF8String:argv[3]] stringByStandardizingPath],
                [[NSString stringWithUTF8String:argv[4]] stringByStandardizingPath],
                [[NSString stringWithUTF8String:argv[5]] stringByStandardizingPath],
                [[NSString stringWithUTF8String:argv[6]] stringByStandardizingPath],
                [[NSString stringWithUTF8String:argv[7]] stringByStandardizingPath],
                &semanticCapture,
                &nativeStyleData,
                &semanticError
            );
        }
        if (!input || !target) {
            NSDictionary *failure = @{
                @"schema": @"learnnode-coefficient-probe-v2",
                @"mode": semanticMode ? @"semantic" : @"direct",
                @"input": inputPath,
                @"target": targetPath,
                @"semantic": semanticCapture ?: (id)[NSNull null],
                @"semanticError": JSONSafe(semanticError),
            };
            WriteJSON(failure, [outputDirectory stringByAppendingPathComponent:@"probe.json"], NULL);
            fprintf(stderr, "failed to load input or target CIImage\n");
            return 1;
        }

        NUIntegerPair scale = {1, 1};
        NUIntegerPair aspect = {
            (int64_t)llround(input.extent.size.width),
            (int64_t)llround(input.extent.size.height),
        };
        Class nodeClass = NSClassFromString(@"NUStyleTransferNode");
        NSDictionary *settings = SendClassPairPair(
            nodeClass,
            NSSelectorFromString(@"semanticStyleImageSettingsForScale:aspectRatio:"),
            scale,
            aspect
        );
        NSDictionary *baseConfiguration = FindNestedDictionary(
            settings,
            @"configuration",
            @"spotlightCountX"
        );
        NSDictionary *baseTuning = FindNestedDictionary(
            settings,
            @"tuningParameters",
            @"StylePriorStrength"
        );
        if (!baseConfiguration || !baseTuning) {
            NSDictionary *failure = @{
                @"schema": @"learnnode-coefficient-probe-v1",
                @"error": @"failed to locate configuration or tuning dictionary",
                @"settings": JSONSafe(settings),
            };
            WriteJSON(failure, [outputDirectory stringByAppendingPathComponent:@"probe.json"], NULL);
            fprintf(stderr, "failed to locate configuration or tuning dictionary\n");
            return 1;
        }

        NSMutableDictionary *configuration = [baseConfiguration mutableCopy];
        NSMutableDictionary *tuning = [baseTuning mutableCopy];
        if (directMode) {
            // Same-image learning is a deterministic source-derived identity baseline.
            configuration[@"applyDithering"] = @NO;
            configuration[@"applySyntheticNoise"] = @NO;
        }
        Class filterClass = NSClassFromString(@"PISemanticStyleFilter");
        NSDictionary *requestedStyle = semanticMode ? semanticCapture[@"styleSettings"] : nil;
        NSString *cast = requestedStyle[@"cast"] ?: @"Standard";
        float tone = requestedStyle ? [requestedStyle[@"tone"] floatValue] : 0.0f;
        float color = requestedStyle ? [requestedStyle[@"color"] floatValue] : 0.0f;
        float intensity = requestedStyle ? [requestedStyle[@"intensity"] floatValue] : 1.0f;
        NSDictionary *castTuning = ((id (*)(id, SEL, id))objc_msgSend)(
            (id)filterClass,
            NSSelectorFromString(@"styleTuningParametersForCast:"),
            cast
        );
        if (castTuning) {
            [tuning addEntriesFromDictionary:castTuning];
        }
        float priorStrength = [tuning[@"StylePriorStrength"] floatValue];
        NSData *prior = SendClassCastFloats(
            filterClass,
            NSSelectorFromString(@"stylePriorDataForCast:tone:color:intensity:priorStrength:"),
            cast,
            tone,
            color,
            intensity,
            priorStrength
        );
        configuration[@"useFloat16"] = @YES;
        if (prior) {
            configuration[@"priorMatrix"] = prior;
        }

        Class wrapperClass = NSClassFromString(@"_NUStyleEngineConfiguration");
        id wrapper = ((id (*)(id, SEL, id))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)wrapperClass, sel_registerName("alloc")),
            NSSelectorFromString(@"initWithConfigurationDictionary:"),
            configuration
        );
        CGSize thumbnailSize = ((CGSize (*)(id, SEL))objc_msgSend)(
            wrapper,
            NSSelectorFromString(@"thumbnailSize")
        );
        CGSize coefficientSize = SendClassDictionarySize(
            wrapperClass,
            NSSelectorFromString(@"coefficientTextureSizeForConfigurationDictionary:"),
            configuration
        );
        id nuColorSpace = SendId(
            (id)NSClassFromString(@"NUColorSpace"),
            NSSelectorFromString(@"workingColorSpace")
        );
        NUIntegerPair thumbnailTargetSize = {
            (int64_t)llround(thumbnailSize.width),
            (int64_t)llround(thumbnailSize.height),
        };
        Class thumbnailProcessorClass = NSClassFromString(@"_NUStyleTransferThumbnailProcessor");
        NSError *inputThumbnailError = nil;
        NSError *targetThumbnailError = nil;
        BOOL inputsArePrecomputedThumbnails = [NSProcessInfo processInfo]
            .environment[@"LEARNNODE_INPUTS_ARE_PRECOMPUTED_THUMBNAILS"].boolValue;
        BOOL inputMatchesThumbnailSize =
            llround(input.extent.size.width) == thumbnailTargetSize.first &&
            llround(input.extent.size.height) == thumbnailTargetSize.second;
        BOOL targetMatchesThumbnailSize =
            llround(target.extent.size.width) == thumbnailTargetSize.first &&
            llround(target.extent.size.height) == thumbnailTargetSize.second;
        if (inputsArePrecomputedThumbnails &&
            (!inputMatchesThumbnailSize || !targetMatchesThumbnailSize)) {
            NSDictionary *failure = @{
                @"schema": @"learnnode-coefficient-probe-v2",
                @"mode": semanticMode ? @"semantic" : @"direct",
                @"error": @"precomputed thumbnails do not match configured thumbnail size",
                @"thumbnailSize": @{
                    @"width": @(thumbnailTargetSize.first),
                    @"height": @(thumbnailTargetSize.second),
                },
                @"inputExtent": XDRemuxRectToString(input.extent),
                @"targetExtent": (
#if TARGET_OS_OSX
            XDRemuxRectToString(target.extent)
#else
            XDRemuxRectToString(target.extent)
#endif
        ),
            };
            WriteJSON(failure, [outputDirectory stringByAppendingPathComponent:@"probe.json"], NULL);
            fprintf(stderr, "precomputed thumbnails do not match configured thumbnail size\n");
            return 1;
        }
        CIImage *inputThumbnail = inputsArePrecomputedThumbnails
            ? input
            : SendClassThumbnail(
                thumbnailProcessorClass,
                NSSelectorFromString(@"generateThumbnailForImage:targetSize:colorSpace:configuration:tuningParameters:error:"),
                input,
                thumbnailTargetSize,
                nuColorSpace,
                configuration,
                tuning,
                &inputThumbnailError
            );
        CIImage *targetThumbnail = inputsArePrecomputedThumbnails
            ? target
            : SendClassThumbnail(
                thumbnailProcessorClass,
                NSSelectorFromString(@"generateThumbnailForImage:targetSize:colorSpace:configuration:tuningParameters:error:"),
                target,
                thumbnailTargetSize,
                nuColorSpace,
                configuration,
                tuning,
                &targetThumbnailError
            );
        if (!inputThumbnail || !targetThumbnail) {
            NSDictionary *failure = @{
                @"schema": @"learnnode-coefficient-probe-v2",
                @"mode": semanticMode ? @"semantic" : @"direct",
                @"inputThumbnailError": JSONSafe(inputThumbnailError),
                @"targetThumbnailError": JSONSafe(targetThumbnailError),
                @"semantic": semanticCapture ?: (id)[NSNull null],
            };
            WriteJSON(failure, [outputDirectory stringByAppendingPathComponent:@"probe.json"], NULL);
            fprintf(stderr, "failed to create exact style-transfer thumbnails\n");
            return 1;
        }

        Class learnProcessorClass = NSClassFromString(@"_NUStyleTransferLearnProcessor");
        Method learnMethod = class_getClassMethod(
            learnProcessorClass,
            NSSelectorFromString(@"processWithInputs:arguments:output:error:")
        );
        Class cmiProcessorClass = NSClassFromString(@"CMIStyleEngineProcessor");
        Method cmiMethod = class_getInstanceMethod(cmiProcessorClass, NSSelectorFromString(@"process"));
        Class semanticProcessorClass = NSClassFromString(@"PISemanticStyleProcessor");
        Method semanticMethod = class_getClassMethod(
            semanticProcessorClass,
            NSSelectorFromString(@"processWithInputs:arguments:output:error:")
        );
        Class semanticRendererClass = NSClassFromString(@"PISemanticStyleRenderer");
        Method usingSharedMethod = class_getClassMethod(
            semanticRendererClass,
            NSSelectorFromString(@"usingSharedSemanticStyleRendererWithMetalCommandQueue:processingType:useStyleEngine:perform:")
        );
        Class smartStyleRendererClass = NSClassFromString(@"CMISmartStyleMetalRendererV1");
        NSArray<NSString *> *smartStyleStatusSelectors = @[
            @"setup",
            @"prepareToProcess:",
            @"process",
            @"finishProcessing",
            @"_updateRenderPipelineConfigForInputs",
            @"_setupStatsAndRenderParamBuffer",
            @"_processSegmentationMasks",
            @"_processLTMGainMap",
            @"_calculateDynamicRenderParameters",
            @"_applyFinalRendering",
            @"_encodeLinear",
        ];
        Class guidedFilterClass = NSClassFromString(@"CMIGuidedFilter");
        Method guidedFilterMethod = class_getInstanceMethod(
            guidedFilterClass,
            NSSelectorFromString(@"encodeToCommandBuffer:inputTexture:guideTexture:outputTexture:kernelRadius:epsilon:")
        );
        gOriginalLearnProcess = method_getImplementation(learnMethod);
        gOriginalCMIProcess = method_getImplementation(cmiMethod);
        gOriginalSemanticProcess = method_getImplementation(semanticMethod);
        gOriginalUsingSharedRenderer = method_getImplementation(usingSharedMethod);
        gOriginalGuidedFilterEncode = method_getImplementation(guidedFilterMethod);
        gOriginalSmartStyleMethods = [NSMutableDictionary dictionary];
        gEvents = [NSMutableArray array];
        gCapturedCMIResources = [NSMutableDictionary dictionary];
        gCapturedCMISnapshots = [NSMutableDictionary dictionary];
        gCapturedCMIDescriptors = [NSMutableDictionary dictionary];
        method_setImplementation(learnMethod, (IMP)RecordingLearnProcess);
        method_setImplementation(cmiMethod, (IMP)RecordingCMIProcess);
        method_setImplementation(semanticMethod, (IMP)RecordingSemanticProcess);
        method_setImplementation(usingSharedMethod, (IMP)RecordingUsingSharedRenderer);
        method_setImplementation(guidedFilterMethod, (IMP)RecordingGuidedFilterEncode);
        for (NSString *selectorName in smartStyleStatusSelectors) {
            Method method = class_getInstanceMethod(
                smartStyleRendererClass,
                NSSelectorFromString(selectorName)
            );
            IMP original = method_getImplementation(method);
            gOriginalSmartStyleMethods[selectorName] = [NSValue valueWithPointer:original];
            IMP recording = [selectorName isEqualToString:@"prepareToProcess:"]
                ? (IMP)RecordingSmartStylePrepare
                : (IMP)RecordingSmartStyleStatus;
            method_setImplementation(method, recording);
        }

        CIImage *learnedImage = nil;
        NSError *learnError = nil;
        NSError *renderError = nil;
        NSMutableData *raw = nil;
        BOOL hooksRestored = NO;
        BOOL swapLearnDirection = [NSProcessInfo processInfo]
            .environment[@"LEARNNODE_SWAP_INPUT_TARGET"].boolValue;
        CIImage *learnSourceThumbnail = swapLearnDirection
            ? targetThumbnail
            : inputThumbnail;
        CIImage *learnTargetThumbnail = swapLearnDirection
            ? inputThumbnail
            : targetThumbnail;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        CIContext *context = [CIContext contextWithMTLDevice:device options:@{
            kCIContextWorkingColorSpace: [NSNull null],
            kCIContextOutputColorSpace: [NSNull null],
        }];
        NSDictionary *smartStyleUtility = nil;
        if ([NSProcessInfo processInfo]
                .environment[@"LEARNNODE_USE_SMART_STYLE_UTILITIES"].boolValue) {
            smartStyleUtility = RunSmartStyleUtilityLearn(
                context,
                [device newCommandQueue],
                learnSourceThumbnail,
                learnTargetThumbnail,
                outputDirectory
            );
        }
        @try {
            learnedImage = SendClassLearn(
                learnProcessorClass,
                NSSelectorFromString(@"learnStyleFromInputThumbnail:targetThumbnail:colorSpace:configuration:tuningParameters:error:"),
                learnSourceThumbnail,
                learnTargetThumbnail,
                nuColorSpace,
                configuration,
                tuning,
                &learnError
            );
            if (learnedImage) {
                size_t width = (size_t)llround(learnedImage.extent.size.width);
                size_t height = (size_t)llround(learnedImage.extent.size.height);
                size_t rowBytes = width * sizeof(uint16_t);
                raw = [NSMutableData dataWithLength:rowBytes * height];
                @try {
                    [context render:learnedImage
                           toBitmap:raw.mutableBytes
                           rowBytes:rowBytes
                             bounds:learnedImage.extent
                             format:kCIFormatRh
                         colorSpace:NULL];
                    if (gLastCMIProcessor) {
                        AppendEvent(@{
                            @"event": @"CMIStyleEngineProcessor.afterCoreImageRender",
                            @"processor": ProcessorSummary(gLastCMIProcessor),
                        });
                    }
                } @catch (NSException *exception) {
                    renderError = [NSError errorWithDomain:@"LearnNodeCoefficientProbe"
                                                       code:2
                                                   userInfo:@{
                        NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                    }];
                }
            }
        } @finally {
            method_setImplementation(learnMethod, gOriginalLearnProcess);
            method_setImplementation(cmiMethod, gOriginalCMIProcess);
            method_setImplementation(semanticMethod, gOriginalSemanticProcess);
            method_setImplementation(usingSharedMethod, gOriginalUsingSharedRenderer);
            method_setImplementation(guidedFilterMethod, gOriginalGuidedFilterEncode);
            for (NSString *selectorName in smartStyleStatusSelectors) {
                Method method = class_getInstanceMethod(
                    smartStyleRendererClass,
                    NSSelectorFromString(selectorName)
                );
                method_setImplementation(
                    method,
                    [gOriginalSmartStyleMethods[selectorName] pointerValue]
                );
            }
            hooksRestored = method_getImplementation(learnMethod) == gOriginalLearnProcess &&
                method_getImplementation(cmiMethod) == gOriginalCMIProcess &&
                method_getImplementation(semanticMethod) == gOriginalSemanticProcess &&
                method_getImplementation(usingSharedMethod) == gOriginalUsingSharedRenderer &&
                method_getImplementation(guidedFilterMethod) == gOriginalGuidedFilterEncode;
            for (NSString *selectorName in smartStyleStatusSelectors) {
                Method method = class_getInstanceMethod(
                    smartStyleRendererClass,
                    NSSelectorFromString(selectorName)
                );
                hooksRestored = hooksRestored &&
                    method_getImplementation(method) ==
                        [gOriginalSmartStyleMethods[selectorName] pointerValue];
            }
        }

        NSString *rawPath = [outputDirectory stringByAppendingPathComponent:@"learned_style.f16.bin"];
        if (raw && !renderError) {
            [raw writeToFile:rawPath options:NSDataWritingAtomic error:&renderError];
        }
        NSError *capturedBufferError = nil;
        NSArray<NSDictionary *> *capturedBuffers = WriteCapturedCMIResources(
            outputDirectory,
            &capturedBufferError
        );
        Class applyProcessorClass = NSClassFromString(@"_NUStyleTransferApplyProcessor");
        SEL applySelector = NSSelectorFromString(
            @"applyStyle:toImage:thumbnail:target:deltaMap:colorSpace:configuration:tuningParameters:noiseModel:error:"
        );
        NSError *learnedApplyError = nil;
        NSError *nativeApplyError = nil;
        NSError *composedApplyError = nil;
        CIImage *learnedAppliedImage = learnedImage ? SendClassApply(
            applyProcessorClass,
            applySelector,
            learnedImage,
            learnSourceThumbnail,
            learnSourceThumbnail,
            learnTargetThumbnail,
            nil,
            nuColorSpace,
            configuration,
            tuning,
            nil,
            &learnedApplyError
        ) : nil;
        NSUInteger coefficientRowBytes =
            (NSUInteger)llround(coefficientSize.width) * sizeof(uint16_t);
        NSUInteger expectedCoefficientBytes = coefficientRowBytes *
            (NSUInteger)llround(coefficientSize.height);
        BOOL composeNativeKey1Correction = [NSProcessInfo processInfo]
            .environment[@"LEARNNODE_COMPOSE_NATIVE_KEY1_CORRECTION"].boolValue;
        NSDictionary *compositionSummary = nil;
        NSMutableData *composedRaw = composeNativeKey1Correction &&
            raw.length == expectedCoefficientBytes &&
            nativeStyleData.length == expectedCoefficientBytes
                ? ComposeLearnedWithIdentityRelativeKey1(
                    raw,
                    nativeStyleData,
                    &compositionSummary
                )
                : nil;
        CIImage *composedLearnedImage = composedRaw
            ? [CIImage imageWithBitmapData:composedRaw
                              bytesPerRow:coefficientRowBytes
                                     size:coefficientSize
                                   format:kCIFormatRh
                               colorSpace:nil]
            : nil;
        CIImage *composedAppliedImage = composedLearnedImage ? SendClassApply(
            applyProcessorClass,
            applySelector,
            composedLearnedImage,
            learnSourceThumbnail,
            learnSourceThumbnail,
            learnTargetThumbnail,
            nil,
            nuColorSpace,
            configuration,
            tuning,
            nil,
            &composedApplyError
        ) : nil;
        CIImage *nativeStyleImage = nativeStyleData.length == expectedCoefficientBytes
            ? [CIImage imageWithBitmapData:nativeStyleData
                               bytesPerRow:coefficientRowBytes
                                      size:coefficientSize
                                    format:kCIFormatRh
                                colorSpace:nil]
            : nil;
        CIImage *nativeAppliedImage = nativeStyleImage ? SendClassApply(
            applyProcessorClass,
            applySelector,
            nativeStyleImage,
            learnSourceThumbnail,
            learnSourceThumbnail,
            learnTargetThumbnail,
            nil,
            nuColorSpace,
            configuration,
            tuning,
            nil,
            &nativeApplyError
        ) : nil;
        NSString *inputThumbnailPath = [outputDirectory
            stringByAppendingPathComponent:@"input_thumbnail.rgba16f.bin"];
        NSString *targetThumbnailPath = [outputDirectory
            stringByAppendingPathComponent:@"target_thumbnail.rgba16f.bin"];
        NSString *learnedAppliedPath = [outputDirectory
            stringByAppendingPathComponent:@"learned_applied_thumbnail.rgba16f.bin"];
        NSString *nativeAppliedPath = [outputDirectory
            stringByAppendingPathComponent:@"native_key1_applied_thumbnail.rgba16f.bin"];
        NSString *composedRawPath = [outputDirectory
            stringByAppendingPathComponent:@"composed_learned_style.f16.bin"];
        NSString *composedAppliedPath = [outputDirectory
            stringByAppendingPathComponent:@"composed_learned_applied_thumbnail.rgba16f.bin"];
        NSError *inputThumbnailCaptureError = nil;
        NSError *targetThumbnailCaptureError = nil;
        NSError *learnedAppliedCaptureError = nil;
        NSError *nativeAppliedCaptureError = nil;
        NSError *composedAppliedCaptureError = nil;
        NSError *composedRawWriteError = nil;
        BOOL inputThumbnailCaptured = RenderHalfRGBA(
            context,
            inputThumbnail,
            inputThumbnailPath,
            &inputThumbnailCaptureError
        );
        BOOL targetThumbnailCaptured = RenderHalfRGBA(
            context,
            targetThumbnail,
            targetThumbnailPath,
            &targetThumbnailCaptureError
        );
        BOOL learnedAppliedCaptured = learnedAppliedImage && RenderHalfRGBA(
            context,
            learnedAppliedImage,
            learnedAppliedPath,
            &learnedAppliedCaptureError
        );
        BOOL nativeAppliedCaptured = nativeAppliedImage && RenderHalfRGBA(
            context,
            nativeAppliedImage,
            nativeAppliedPath,
            &nativeAppliedCaptureError
        );
        BOOL composedRawWritten = composedRaw && [composedRaw writeToFile:composedRawPath
                                                                   options:NSDataWritingAtomic
                                                                     error:&composedRawWriteError];
        BOOL composedAppliedCaptured = composedAppliedImage && RenderHalfRGBA(
            context,
            composedAppliedImage,
            composedAppliedPath,
            &composedAppliedCaptureError
        );
        NSDictionary *result = @{
            @"schema": @"learnnode-coefficient-probe-v2",
            @"mode": semanticMode ? @"semantic" : @"direct",
            @"input": inputPath,
            @"target": targetPath,
            @"inputExtent": XDRemuxRectToString(input.extent),
            @"targetExtent": (
#if TARGET_OS_OSX
            XDRemuxRectToString(target.extent)
#else
            XDRemuxRectToString(target.extent)
#endif
        ),
            @"semantic": semanticCapture ?: (id)[NSNull null],
            @"semanticError": JSONSafe(semanticError),
            @"settings": JSONSafe(settings),
            @"configuration": JSONSafe(configuration),
            @"tuning": JSONSafe(tuning),
            @"requestedStyle": @{
                @"cast": cast,
                @"tone": @(tone),
                @"color": @(color),
                @"intensity": @(intensity),
            },
            @"learnDirection": @{
                @"swapped": @(swapLearnDirection),
                @"source": swapLearnDirection
                    ? @"semantic target thumbnail"
                    : @"input thumbnail",
                @"target": swapLearnDirection
                    ? @"input thumbnail"
                    : @"semantic target thumbnail",
                @"sourceEnvironment": [NSProcessInfo processInfo]
                    .environment[@"LEARNNODE_SWAP_INPUT_TARGET"]
                        ? @"LEARNNODE_SWAP_INPUT_TARGET"
                        : @"default",
            },
            @"smartStyleUtility": smartStyleUtility ?: (id)[NSNull null],
            @"priorLength": @(prior.length),
            @"priorStrength": @(priorStrength),
            @"thumbnailSize": @{
                @"width": @(thumbnailSize.width),
                @"height": @(thumbnailSize.height),
            },
            @"thumbnailInputPolicy": @{
                @"precomputed": @(inputsArePrecomputedThumbnails),
                @"environment": @"LEARNNODE_INPUTS_ARE_PRECOMPUTED_THUMBNAILS",
                @"inputMatchesConfiguredSize": @(inputMatchesThumbnailSize),
                @"targetMatchesConfiguredSize": @(targetMatchesThumbnailSize),
            },
            @"coefficientTextureSize": @{
                @"width": @(coefficientSize.width),
                @"height": @(coefficientSize.height),
            },
            @"inputThumbnail": @{
                @"class": NSStringFromClass([inputThumbnail class]),
                @"description": [inputThumbnail description] ?: @"",
                @"extent": (
#if TARGET_OS_OSX
                XDRemuxRectToString(inputThumbnail.extent)
#else
                XDRemuxRectToString(inputThumbnail.extent)
#endif
            ),
                @"creationError": JSONSafe(inputThumbnailError),
                @"capturePath": inputThumbnailPath,
                @"captureFormat": @"kCIFormatRGBAh",
                @"captureLength": inputThumbnailCaptured
                    ? @((NSUInteger)llround(inputThumbnail.extent.size.width) *
                        (NSUInteger)llround(inputThumbnail.extent.size.height) * 8)
                    : (id)[NSNull null],
                @"captureError": JSONSafe(inputThumbnailCaptureError),
            },
            @"targetThumbnail": @{
                @"class": NSStringFromClass([targetThumbnail class]),
                @"description": [targetThumbnail description] ?: @"",
                @"extent": XDRemuxRectToString(targetThumbnail.extent),
                @"creationError": JSONSafe(targetThumbnailError),
                @"capturePath": targetThumbnailPath,
                @"captureFormat": @"kCIFormatRGBAh",
                @"captureLength": targetThumbnailCaptured
                    ? @((NSUInteger)llround(targetThumbnail.extent.size.width) *
                        (NSUInteger)llround(targetThumbnail.extent.size.height) * 8)
                    : (id)[NSNull null],
                @"captureError": JSONSafe(targetThumbnailCaptureError),
            },
            @"behavioralApply": @{
                @"processorClass": NSStringFromClass(applyProcessorClass),
                @"selector": NSStringFromSelector(applySelector),
                @"imageArgumentPolicy": swapLearnDirection
                    ? @"semantic target used for image and thumbnail; input thumbnail supplied as target"
                    : @"input thumbnail used for image and thumbnail; semantic target thumbnail supplied as target",
                @"learned": @{
                    @"outputClass": learnedAppliedImage
                        ? NSStringFromClass([learnedAppliedImage class])
                        : (id)[NSNull null],
                    @"outputExtent": learnedAppliedImage
                        ? XDRemuxRectToString(learnedAppliedImage.extent)
                        : (id)[NSNull null],
                    @"creationError": JSONSafe(learnedApplyError),
                    @"capturePath": learnedAppliedCaptured
                        ? learnedAppliedPath
                        : (id)[NSNull null],
                    @"captureError": JSONSafe(learnedAppliedCaptureError),
                },
                @"nativeKey1": @{
                    @"styleDataLength": @(nativeStyleData.length),
                    @"coefficientImageCreated": @(nativeStyleImage != nil),
                    @"outputClass": nativeAppliedImage
                        ? NSStringFromClass([nativeAppliedImage class])
                        : (id)[NSNull null],
                    @"outputExtent": nativeAppliedImage
                        ? XDRemuxRectToString(nativeAppliedImage.extent)
                        : (id)[NSNull null],
                    @"creationError": JSONSafe(nativeApplyError),
                    @"capturePath": nativeAppliedCaptured
                        ? nativeAppliedPath
                        : (id)[NSNull null],
                    @"captureError": JSONSafe(nativeAppliedCaptureError),
                },
                @"composedLearnedWithNativeKey1Correction": @{
                    @"requested": @(composeNativeKey1Correction),
                    @"environment": @"LEARNNODE_COMPOSE_NATIVE_KEY1_CORRECTION",
                    @"summary": compositionSummary ?: (id)[NSNull null],
                    @"coefficientImageCreated": @(composedLearnedImage != nil),
                    @"coefficientCapturePath": composedRawWritten
                        ? composedRawPath
                        : (id)[NSNull null],
                    @"coefficientCaptureError": JSONSafe(composedRawWriteError),
                    @"outputClass": composedAppliedImage
                        ? NSStringFromClass([composedAppliedImage class])
                        : (id)[NSNull null],
                    @"outputExtent": composedAppliedImage
                        ? XDRemuxRectToString(composedAppliedImage.extent)
                        : (id)[NSNull null],
                    @"creationError": JSONSafe(composedApplyError),
                    @"capturePath": composedAppliedCaptured
                        ? composedAppliedPath
                        : (id)[NSNull null],
                    @"captureError": JSONSafe(composedAppliedCaptureError),
                },
            },
            @"learnedObject": learnedImage ? @{
                @"class": NSStringFromClass([learnedImage class]),
                @"isCIImage": @([learnedImage isKindOfClass:[CIImage class]]),
                @"description": [learnedImage description] ?: @"",
                @"extent": XDRemuxRectToString(learnedImage.extent),
                @"ivars": ObjectIvarSummary(learnedImage),
            } : [NSNull null],
            @"learnError": JSONSafe(learnError),
            @"renderError": JSONSafe(renderError),
            @"rawOutput": raw && !renderError ? @{
                @"path": rawPath,
                @"length": @(raw.length),
                @"rowBytes": @((NSUInteger)llround(coefficientSize.width) * sizeof(uint16_t)),
                @"format": @"kCIFormatRh",
                @"sourceMethod": @"learnStyleFromInputThumbnail:targetThumbnail:colorSpace:configuration:tuningParameters:error:",
                @"captureTiming": @"after full CIImage evaluation",
            } : [NSNull null],
            @"capturedBuffers": capturedBuffers,
            @"capturedBufferError": JSONSafe(capturedBufferError),
            @"events": gEvents,
            @"hooksRestored": @(hooksRestored),
            @"claimBoundary": @"Local private-framework invocation and reversible in-process Objective-C hooks; no system framework was modified on disk.",
        };
        NSString *jsonPath = [outputDirectory stringByAppendingPathComponent:@"probe.json"];
        if (!WriteJSON(result, jsonPath, &error)) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("%s\n", jsonPath.UTF8String);
        return learnedImage && raw && !renderError &&
            inputThumbnailCaptured && targetThumbnailCaptured ? 0 : 1;
    }
}
