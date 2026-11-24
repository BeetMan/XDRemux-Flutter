#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#include <stdbool.h>
#include <stdio.h>

typedef struct {
    int64_t value;
    int32_t scale;
} FrameTime;

typedef bool (*ReceiveFrame)(void *context, FrameTime time, const float *rgba);

static FrameTime frame_time(CMTime time) {
    return (FrameTime){time.value, CMTIME_IS_NUMERIC(time) ? time.timescale : 0};
}

static NSString *decode_frames(NSURL *url, int32_t track_id, uint32_t width, uint32_t height,
                               ReceiveFrame receive, void *context, FrameTime *end) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track = [asset trackWithTrackID:track_id];
    if (![track.mediaType isEqualToString:AVMediaTypeVideo]) {
        return @"primary video track is unavailable";
    }
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader) return error.localizedDescription ?: @"cannot create video reader";

    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:track outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:
                                                @(kCVPixelFormatType_64RGBAHalf)}];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return @"cannot attach the video decoder";
    [reader addOutput:output];

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
    if (!space) return @"extended linear Rec.2020 is unavailable";
    CIContext *ci = [CIContext contextWithOptions:@{
        kCIContextWorkingColorSpace: (__bridge id)space,
        kCIContextCacheIntermediates: @NO,
    }];
    size_t row_bytes = width * 4 * sizeof(float);
    NSMutableData *bitmap = [NSMutableData dataWithLength:row_bytes * height];
    NSString *failure = nil;
    if (![reader startReading]) {
        failure = reader.error.localizedDescription ?: @"video decoder did not start";
    } else {
        for (;;) {
            @autoreleasepool {
                CMSampleBufferRef sample = [output copyNextSampleBuffer];
                if (!sample) break;
                CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sample);
                // AVAssetReader can emit a synthetic image for an empty edit.
                if (CMTIME_IS_NUMERIC(timestamp) && [track segmentForTrackTime:timestamp].isEmpty) {
                    CFRelease(sample);
                    continue;
                }
                FrameTime time = frame_time(timestamp);
                CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
                if (pixels && time.scale > 0) {
                    // Keep coded orientation. The MOV carries the display transform.
                    CIImage *image = [CIImage imageWithCVPixelBuffer:pixels];
                    CGRect extent = image.extent;
                    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
                        -CGRectGetMinX(extent), -CGRectGetMinY(extent))];
                    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(
                        width / CGRectGetWidth(extent), height / CGRectGetHeight(extent))];
                    [ci render:image toBitmap:bitmap.mutableBytes rowBytes:row_bytes
                        bounds:CGRectMake(0, 0, width, height) format:kCIFormatRGBAf colorSpace:space];
                    if (!receive(context, time, bitmap.bytes)) failure = @"could not record video frame";
                } else {
                    failure = @"video decoder returned a frame without pixels or a presentation time";
                }
                CFRelease(sample);
                if (failure) {
                    [reader cancelReading];
                    break;
                }
            }
        }
        if (!failure && reader.status != AVAssetReaderStatusCompleted) {
            failure = reader.error.localizedDescription ?: @"video decoder did not finish";
        }
    }
    *end = frame_time(CMTimeRangeGetEnd(track.timeRange));
    CGColorSpaceRelease(space);
    return failure;
}

// The pairing entry point has the finished MOV in memory. AVAssetReader takes
// a file URL, so stage it in a per-call directory for the duration of decoding.
bool xdremux_observe_live_style_video(const uint8_t *movie, size_t size, int32_t track_id,
                                    uint32_t width, uint32_t height, ReceiveFrame receive,
                                    void *context, FrameTime *end, char *error, size_t error_size) {
    @autoreleasepool {
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *directory = [files.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                                                                      isDirectory:YES];
        NSError *file_error = nil;
        if (![files createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil
                                  error:&file_error]) {
            snprintf(error, error_size, "%s", file_error.localizedDescription.UTF8String);
            return false;
        }
        NSURL *url = [directory URLByAppendingPathComponent:@"paired.mov"];
        NSData *bytes = [NSData dataWithBytesNoCopy:(void *)movie length:size freeWhenDone:NO];
        NSString *failure = [bytes writeToURL:url options:0 error:&file_error]
            ? decode_frames(url, track_id, width, height, receive, context, end)
            : file_error.localizedDescription;
        [files removeItemAtURL:directory error:NULL];
        if (failure) snprintf(error, error_size, "%s", failure.UTF8String);
        return failure == nil;
    }
}
