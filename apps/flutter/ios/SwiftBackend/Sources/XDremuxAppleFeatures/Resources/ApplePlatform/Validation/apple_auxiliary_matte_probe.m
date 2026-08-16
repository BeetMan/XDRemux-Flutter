#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

static void Emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

static NSString *FourCC(OSType format) {
    char chars[5] = {
        (char)((format >> 24) & 0xff),
        (char)((format >> 16) & 0xff),
        (char)((format >> 8) & 0xff),
        (char)(format & 0xff),
        0,
    };
    return [NSString stringWithUTF8String:chars];
}

static NSDictionary *Stats(CVPixelBufferRef buffer) {
    if (!buffer) {
        return @{};
    }
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    NSMutableDictionary *result = [@{
        @"width": @(width),
        @"height": @(height),
        @"pixelFormat": FourCC(format),
        @"dataSize": @(CVPixelBufferGetDataSize(buffer)),
        @"planeCount": @(CVPixelBufferGetPlaneCount(buffer)),
    } mutableCopy];
    if (format != kCVPixelFormatType_OneComponent8 ||
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return result;
    }

    const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
    uint64_t histogram[256] = {0};
    uint64_t sum = 0;
    uint8_t minimum = UINT8_MAX;
    uint8_t maximum = 0;
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = base + y * bytesPerRow;
        for (size_t x = 0; x < width; x++) {
            uint8_t value = row[x];
            histogram[value]++;
            sum += value;
            minimum = MIN(minimum, value);
            maximum = MAX(maximum, value);
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);

    uint64_t count = width * height;
    NSMutableArray *histogramJSON = [NSMutableArray arrayWithCapacity:256];
    for (NSUInteger index = 0; index < 256; index++) {
        [histogramJSON addObject:@(histogram[index])];
    }
    result[@"bytesPerRow"] = @(bytesPerRow);
    result[@"min"] = @(minimum);
    result[@"max"] = @(maximum);
    result[@"mean"] = count ? @((double)sum / (double)count) : @0;
    result[@"histogram"] = histogramJSON;
    result[@"nonzeroRatio"] = count ? @(1.0 - (double)histogram[0] / (double)count) : @0;
    result[@"highConfidenceRatio"] = count ? @((double)histogram[255] / (double)count) : @0;
    return result;
}

static NSString *WritePNG(CVPixelBufferRef buffer, NSURL *outputURL, NSString *name);

static NSDictionary *RawInfoSummary(
    NSDictionary *info,
    NSURL *outputURL,
    NSString *name
) {
    NSData *data = info[(__bridge NSString *)kCGImageAuxiliaryDataInfoData];
    NSDictionary *description = info[(__bridge NSString *)kCGImageAuxiliaryDataInfoDataDescription];
    NSMutableDictionary *result = [@{
        @"dataPresent": @(data != nil),
        @"dataBytes": @(data.length),
        @"dataDescription": description.description ?: @"",
        @"metadataPresent": @(info[(__bridge NSString *)kCGImageAuxiliaryDataInfoMetadata] != nil),
    } mutableCopy];
    if (!data.length) {
        return result;
    }

    NSNumber *widthNumber = description[(__bridge NSString *)kCGImagePropertyWidth];
    NSNumber *heightNumber = description[(__bridge NSString *)kCGImagePropertyHeight];
    NSNumber *bytesPerRowNumber = description[(__bridge NSString *)kCGImagePropertyBytesPerRow];
    NSNumber *pixelFormatNumber = description[(__bridge NSString *)kCGImagePropertyPixelFormat];
    size_t width = widthNumber.unsignedLongLongValue;
    size_t height = heightNumber.unsignedLongLongValue;
    size_t bytesPerRow = bytesPerRowNumber.unsignedLongLongValue;
    OSType pixelFormat = pixelFormatNumber.unsignedIntValue;
    result[@"descriptionWidth"] = @(width);
    result[@"descriptionHeight"] = @(height);
    result[@"descriptionBytesPerRow"] = @(bytesPerRow);
    result[@"descriptionPixelFormat"] = FourCC(pixelFormat);

    if (width == 0 || height == 0 || bytesPerRow < width ||
        pixelFormat != kCVPixelFormatType_OneComponent8 ||
        data.length < bytesPerRow * height) {
        result[@"imageIODecoded"] = @NO;
        return result;
    }

    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferCreateWithBytes(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        (void *)data.bytes,
        bytesPerRow,
        NULL,
        NULL,
        NULL,
        &buffer
    );
    result[@"imageIODecoded"] = @(status == kCVReturnSuccess && buffer != NULL);
    if (buffer) {
        result[@"pixelBuffer"] = Stats(buffer);
        result[@"png"] = WritePNG(buffer, outputURL, name) ?: [NSNull null];
        CVPixelBufferRelease(buffer);
    }
    return result;
}

static NSString *WritePNG(CVPixelBufferRef buffer, NSURL *outputURL, NSString *name) {
    if (!buffer) {
        return nil;
    }
    NSURL *url = [outputURL URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    CIImage *image = [CIImage imageWithCVPixelBuffer:buffer];
    CIContext *context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    NSError *error = nil;
    BOOL ok = [context writePNGRepresentationOfImage:image
                                               toURL:url
                                              format:kCIFormatL8
                                          colorSpace:colorSpace
                                             options:@{}
                                               error:&error];
    CGColorSpaceRelease(colorSpace);
    return ok ? url.path : [NSString stringWithFormat:@"ERROR: %@", error.localizedDescription];
}

static NSDictionary *SemanticRow(
    CGImageSourceRef source,
    CFStringRef type,
    NSString *name,
    NSURL *outputURL
) {
    CFDictionaryRef rawInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type);
    if (!rawInfo) {
        return @{@"name": name, @"present": @NO};
    }
    NSDictionary *info = CFBridgingRelease(rawInfo);
    NSDictionary *rawInfoSummary = RawInfoSummary(info, outputURL, name);
    NSError *error = nil;
    AVSemanticSegmentationMatte *matte =
        [AVSemanticSegmentationMatte semanticSegmentationMatteFromImageSourceAuxiliaryDataType:type
                                                                      dictionaryRepresentation:info
                                                                                           error:&error];
    CVPixelBufferRef buffer = matte.mattingImage;
    return @{
        @"name": name,
        @"present": @YES,
        @"dictionaryKeys": [[info allKeys] sortedArrayUsingSelector:@selector(compare:)],
        @"rawInfo": rawInfoSummary,
        @"imageIODecoded": rawInfoSummary[@"imageIODecoded"] ?: @NO,
        @"avFoundationDecoded": @(matte != nil),
        @"decoded": @(matte != nil),
        @"decodeError": error.localizedDescription ?: [NSNull null],
        @"matteType": matte.matteType ?: [NSNull null],
        @"pixelFormatProperty": matte ? FourCC(matte.pixelFormatType) : [NSNull null],
        @"pixelBuffer": Stats(buffer),
        @"png": rawInfoSummary[@"png"] ?: [NSNull null],
    };
}

static NSDictionary *PortraitRow(CGImageSourceRef source, NSURL *outputURL) {
    CFDictionaryRef rawInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypePortraitEffectsMatte
    );
    if (!rawInfo) {
        return @{@"name": @"portrait", @"present": @NO};
    }
    NSDictionary *info = CFBridgingRelease(rawInfo);
    NSDictionary *rawInfoSummary = RawInfoSummary(info, outputURL, @"portrait");
    NSError *error = nil;
    AVPortraitEffectsMatte *matte =
        [AVPortraitEffectsMatte portraitEffectsMatteFromDictionaryRepresentation:info error:&error];
    CVPixelBufferRef buffer = matte.mattingImage;
    return @{
        @"name": @"portrait",
        @"present": @YES,
        @"dictionaryKeys": [[info allKeys] sortedArrayUsingSelector:@selector(compare:)],
        @"rawInfo": rawInfoSummary,
        @"imageIODecoded": rawInfoSummary[@"imageIODecoded"] ?: @NO,
        @"avFoundationDecoded": @(matte != nil),
        @"decoded": @(matte != nil),
        @"decodeError": error.localizedDescription ?: [NSNull null],
        @"pixelFormatProperty": matte ? FourCC(matte.pixelFormatType) : [NSNull null],
        @"pixelBuffer": Stats(buffer),
        @"png": rawInfoSummary[@"png"] ?: [NSNull null],
    };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s input-image output-directory\n", argv[0]);
            return 2;
        }
        NSURL *inputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSURL *outputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:outputURL
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)inputURL, NULL);
        if (!source) {
            Emit(@{@"ok": @NO, @"error": @"CGImageSourceCreateWithURL failed"});
            return 1;
        }

        NSArray *mattes = @[
            SemanticRow(source, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, @"skin", outputURL),
            SemanticRow(source, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, @"hair", outputURL),
            SemanticRow(source, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, @"teeth", outputURL),
            SemanticRow(source, kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, @"glasses", outputURL),
            PortraitRow(source, outputURL),
            SemanticRow(source, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, @"sky", outputURL),
        ];
        CFRelease(source);
        Emit(@{
            @"ok": @YES,
            @"input": inputURL.path,
            @"mattes": mattes,
            @"claimBoundary": @"ImageIO L008 decoding covers portrait, skin, hair, teeth, glasses, and sky. AVFoundation is reported separately because its sky constructor rejects valid Apple sky mattes on this OS.",
        });
        return 0;
    }
}
