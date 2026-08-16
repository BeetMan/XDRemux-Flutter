#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static id SendClassObjectError(Class cls, SEL selector, id value, NSError **error) {
    return ((id (*)(id, SEL, id, NSError **))objc_msgSend)(cls, selector, value, error);
}

static id SendObject(id object, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s style-metadata.bplist style-data-readback.bin\n", argv[0]);
            return 2;
        }
        void *framework = dlopen(
            "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore",
            RTLD_NOW
        );
        NSString *inputPath = [NSString stringWithUTF8String:argv[1]];
        NSString *readbackPath = [NSString stringWithUTF8String:argv[2]];
        NSData *metadata = [NSData dataWithContentsOfFile:inputPath];
        Class propertiesClass = NSClassFromString(@"_NUSemanticStyleProperties");
        NSError *error = nil;
        NSException *exception = nil;
        id properties = nil;
        @try {
            if (framework && propertiesClass && metadata) {
                properties = SendClassObjectError(
                    propertiesClass,
                    NSSelectorFromString(@"semanticStylePropertiesFromImageMetadata:error:"),
                    metadata,
                    &error
                );
            }
        } @catch (NSException *caught) {
            exception = caught;
        }
        NSData *styleData = nil;
        if (properties) {
            styleData = SendObject(properties, NSSelectorFromString(@"styleData"));
        }
        BOOL readbackWritten = styleData
            ? [styleData writeToFile:readbackPath options:NSDataWritingAtomic error:&error]
            : NO;
        NSDictionary *result = @{
            @"schema": @"xdremux-apple-semantic-style-properties-probe-v1",
            @"frameworkLoaded": @(framework != NULL),
            @"classAvailable": @(propertiesClass != Nil),
            @"parseSucceeded": @(properties != nil),
            @"styleDataLength": @(styleData.length),
            @"readbackWritten": @(readbackWritten),
            @"error": error ? error.description : [NSNull null],
            @"exception": exception ? @{
                @"name": exception.name ?: @"",
                @"reason": exception.reason ?: @"",
            } : [NSNull null],
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
        if (json) {
            [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
            [[NSFileHandle fileHandleWithStandardOutput]
                writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
        if (framework) {
            dlclose(framework);
        }
        return properties && styleData.length == 51840 && readbackWritten ? 0 : 1;
    }
}
