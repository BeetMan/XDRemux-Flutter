#import "XDremuxAppleProbes.h"
#import <unistd.h>
#import <fcntl.h>

// Probe entry points (ported from the upstream helper .m files; main was
// renamed to a callable function during vendoring).
int XDRemuxLearnNodeProbeMain(int argc, const char *argv[]);
int XDRemuxStyleScenePayloadProbeMain(int argc, const char *argv[]);

@implementation XDRemuxProbeOutcome
@end

typedef int (*XDRemuxProbeMain)(int argc, const char *argv[]);

/// Runs a probe main in-process while capturing everything it writes to
/// stdout/stderr (both FILE* and fd-level writes) into temp files. ObjC
/// exceptions raised by private-framework calls inside the probe are
/// caught and mapped to status 1 with the exception description on
/// stderr, so a failed probe cannot take the host app down.
static XDRemuxProbeOutcome *XDRemuxRunProbe(XDRemuxProbeMain probeMain,
                                          int argc,
                                          const char *argv[]) {
    NSURL *scratch = [NSFileManager.defaultManager.temporaryDirectory
        URLByAppendingPathComponent:[NSString stringWithFormat:@"xdremux-probe-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:scratch
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    NSString *outPath = [scratch URLByAppendingPathComponent:@"stdout.txt"].path;
    NSString *errPath = [scratch URLByAppendingPathComponent:@"stderr.txt"].path;

    fflush(NULL);
    int savedStdout = dup(STDOUT_FILENO);
    int savedStderr = dup(STDERR_FILENO);
    int outFd = open(outPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    int errFd = open(errPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (outFd >= 0) { dup2(outFd, STDOUT_FILENO); }
    if (errFd >= 0) { dup2(errFd, STDERR_FILENO); }

    int status = 1;
    NSException *caught = nil;
    @try {
        status = probeMain(argc, argv);
    } @catch (NSException *exception) {
        caught = exception;
        status = 1;
    }

    fflush(NULL);
    if (savedStdout >= 0) { dup2(savedStdout, STDOUT_FILENO); close(savedStdout); }
    if (savedStderr >= 0) { dup2(savedStderr, STDERR_FILENO); close(savedStderr); }
    if (outFd >= 0) { close(outFd); }
    if (errFd >= 0) { close(errFd); }

    NSData *outData = [NSData dataWithContentsOfFile:outPath] ?: [NSData new];
    NSMutableData *errData = [NSMutableData dataWithData:
        [NSData dataWithContentsOfFile:errPath] ?: [NSData new]];
    if (caught) {
        NSString *message = [NSString stringWithFormat:
            @"in-process probe raised %@: %@\n",
            caught.name ?: @"", caught.reason ?: @""];
        [errData appendData:[message dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [NSFileManager.defaultManager removeItemAtURL:scratch error:nil];

    XDRemuxProbeOutcome *outcome = [XDRemuxProbeOutcome new];
    outcome.status = status;
    outcome.stdoutData = outData;
    outcome.stderrData = errData;
    return outcome;
}

XDRemuxProbeOutcome *XDRemuxRunLearnNodeProbe(int argc, const char *argv[]) {
    return XDRemuxRunProbe(XDRemuxLearnNodeProbeMain, argc, argv);
}

XDRemuxProbeOutcome *XDRemuxRunStyleScenePayloadProbe(int argc, const char *argv[]) {
    return XDRemuxRunProbe(XDRemuxStyleScenePayloadProbeMain, argc, argv);
}
