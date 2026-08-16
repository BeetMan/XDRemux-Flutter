#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Captured result of running one ported Apple helper probe in-process.
/// Mirrors the helper process contract: status = the probe main's return
/// value (or 1 when an ObjC exception was caught); stdout/stderr = the
/// byte streams the helper would have written.
@interface XDRemuxProbeOutcome : NSObject
@property(nonatomic) int status;
@property(nonatomic, copy) NSData *stdoutData;
@property(nonatomic, copy) NSData *stderrData;
@end

/// Runs a probe in-process, capturing stdout/stderr. `argv` includes the
/// helper name at index 0, exactly like the upstream executable contract.
FOUNDATION_EXPORT XDRemuxProbeOutcome *_Nonnull
    XDRemuxRunLearnNodeProbe(int argc, const char *_Nonnull argv[]);

FOUNDATION_EXPORT XDRemuxProbeOutcome *_Nonnull
    XDRemuxRunStyleScenePayloadProbe(int argc, const char *_Nonnull argv[]);

NS_ASSUME_NONNULL_END
