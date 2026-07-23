//! Minimal C helper for x265 FFI — sets struct fields that are impractical
//! to replicate in Rust (x265_picture is a large version-dependent struct).

#include "x265.h"
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

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
