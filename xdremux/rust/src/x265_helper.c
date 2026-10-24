//! Minimal C helper for x265 FFI — sets struct fields that are impractical
//! to replicate in Rust (x265_picture is a large version-dependent struct).

#if defined(_MSC_VER) && !defined(__cplusplus)
/* MSVC's C mode has no `bool` keyword; x265.h uses it only in declarations we
   never touch. A byte-sized typedef keeps layout compatible. */
typedef unsigned char bool;
#endif

#include "x265.h"
#include <string.h>

#ifdef _MSC_VER
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

EXPORT void xdremux_pic_set_planes(x265_picture *pic, void *p0, void *p1, void *p2,
                            int s0, int s1, int s2) {
    pic->planes[0] = p0;
    pic->planes[1] = p1;
    pic->planes[2] = p2;
    pic->stride[0] = s0;
    pic->stride[1] = s1;
    pic->stride[2] = s2;
}

EXPORT void xdremux_pic_set_pts(x265_picture *pic, int64_t pts) {
    pic->pts = pts;
}

/* Set param fields that cannot be set via x265_param_parse(). */
EXPORT void xdremux_param_set_basic(x265_param *p, int width, int height,
                             int bit_depth, int total_frames) {
    p->sourceWidth = width;
    p->sourceHeight = height;
    p->internalBitDepth = bit_depth;
    p->totalFrames = total_frames;
}

/* ---------------------------------------------------------------------------
 * glibc >= 2.38 C23 strtol compat shim.
 *
 * When compiled against glibc >= 2.38, <stdlib.h> in C23 mode redirects
 * strtol() to __isoc23_strtol (via an assembler alias), which glibc exports
 * only as __isoc23_strtol@GLIBC_2.38. The prebuilt static libx265.a was
 * compiled that way, so linking it leaves a GLIBC_2.38 requirement on the
 * cdylib even though neither our code nor x265 needs the C23 '0b' prefix
 * parsing. Define the symbol locally and forward to the classic
 * strtol@GLIBC_2.2.5 so the .so stays loadable on Ubuntu 22.04 (glibc 2.35)
 * and other older distros. The definition is hidden: it only exists to
 * satisfy the static archive's reference at link time, never for interposition.
 *
 * This is a no-op on non-glibc Linux (musl reports no __GLIBC__) and on
 * glibc < 2.38, where no __isoc23_* redirect exists.
 * ------------------------------------------------------------------------- */
#if defined(__linux__) && defined(__GLIBC__) && \
    (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 38))

/* Bind to the classic, unversioned strtol symbol (GLIBC_2.2.5) explicitly:
   a plain strtol() call here would itself be redirected back to
   __isoc23_strtol by glibc's asm alias and recurse. */
extern long xdremux_libc_strtol_(const char *__restrict nptr,
                                 char **__restrict endptr, int base)
    __asm__("strtol");

__attribute__((visibility("hidden")))
long __isoc23_strtol(const char *nptr, char **endptr, int base) {
    return xdremux_libc_strtol_(nptr, endptr, base);
}

#endif /* __linux__ && glibc >= 2.38 */
