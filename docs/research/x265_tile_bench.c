/* x265 tile benchmark for docs/research/ohos-hw-hevc-20261115.md.
 *
 * Encodes every 512x512 tile of a raw raster with the parameters of the
 * core's batch path (xdremux/rust/src/hevc/x265.rs, open_encoder), one
 * single-frame session per tile, single thread (pools 1), and prints the
 * time per tile plus an FNV-1a hash of the slice and parameter-set NAL units
 * (SEI is skipped: x265's info SEI records the cpuid and the container drops
 * SEI anyway). Build it once against each libx265.a to compare builds.
 *
 * Inputs (from any 3072x4096 photo):
 *   ffmpeg -i photo.jpg -frames:v 1 -pix_fmt yuv444p -color_range pc -f rawvideo data/primary444.yuv
 *   ffmpeg -i photo.jpg -frames:v 1 -pix_fmt yuv420p -color_range pc -f rawvideo data/primary420.yuv
 *   ffmpeg -i photo.jpg -frames:v 1 -vf scale=1536:2048,format=gray -f rawvideo data/gain_gray.yuv
 * Build (V = xdremux/rust/vendor/x265/source, B = an x265 build directory):
 *   clang -O2 -o bench x265_tile_bench.c -I$V -I$B $B/libx265.a -lc++
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "x265.h"

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static uint64_t fnv(uint64_t h, const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
  return h;
}

static uint8_t *load(const char *path, size_t want) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(1); }
  uint8_t *b = malloc(want);
  if (fread(b, 1, want, f) != want) { fprintf(stderr, "short read %s\n", path); exit(1); }
  fclose(f);
  return b;
}

typedef struct {
  const char *name, *preset, *csp, *crf, *profile;
  int rgb, chroma; /* chroma: 0 = 4:0:0, 1 = 4:2:0, 3 = 4:4:4 */
} Cfg;

static void set(x265_param *p, const char *k, const char *v) {
  if (x265_param_parse(p, k, v) != 0) { fprintf(stderr, "param %s=%s rejected\n", k, v); exit(1); }
}

/* Encode every 512x512 tile of a planar raster; returns seconds. */
static double run(const Cfg *c, uint8_t *raster, int W, int H, uint64_t *hash, size_t *bytes) {
  const int T = 512;
  int cw = c->chroma == 3 ? W : W / 2, ch = c->chroma == 3 ? H : H / 2;
  uint8_t *Y = raster, *U = raster + (size_t)W * H, *V = U + (size_t)cw * ch;
  double start = now();
  for (int ty = 0; ty < H / T; ty++) {
    for (int tx = 0; tx < W / T; tx++) {
      x265_param *p = x265_param_alloc();
      x265_param_default_preset(p, c->preset, NULL);
      set(p, "input-csp", c->csp);
      p->sourceWidth = T; p->sourceHeight = T; p->internalBitDepth = 8; p->totalFrames = 1;
      set(p, "fps", "1"); set(p, "crf", c->crf); set(p, "range", "full");
      set(p, "repeat-headers", "0"); set(p, "keyint", "1");
      if (x265_param_apply_profile(p, c->profile) != 0) { fprintf(stderr, "profile\n"); exit(1); }
      set(p, "bframes", "0"); set(p, "rc-lookahead", "0"); set(p, "open-gop", "0");
      if (c->rgb) {
        set(p, "colormatrix", "bt709"); set(p, "colorprim", "bt709"); set(p, "transfer", "bt709");
        set(p, "psy-rd", "0"); set(p, "aq-mode", "1");
      }
      set(p, "frame-threads", "1"); set(p, "pools", "1"); set(p, "log-level", "none");
      x265_encoder *e = x265_encoder_open(p);
      if (!e) { fprintf(stderr, "open failed\n"); exit(1); }
      x265_picture *pic = x265_picture_alloc();
      x265_picture_init(p, pic);
      int cx = c->chroma == 3 ? tx * T : tx * T / 2, cy = c->chroma == 3 ? ty * T : ty * T / 2;
      pic->planes[0] = Y + (size_t)ty * T * W + tx * T;
      pic->stride[0] = W;
      if (c->chroma != 0) {
        pic->planes[1] = U + (size_t)cy * cw + cx;
        pic->planes[2] = V + (size_t)cy * cw + cx;
        pic->stride[1] = pic->stride[2] = cw;
      }
      x265_nal *nals; uint32_t n;
      if (x265_encoder_headers(e, &nals, &n) >= 0)
        for (uint32_t i = 0; i < n; i++) { if (nals[i].type < 32 || (nals[i].type >= 32 && nals[i].type <= 34)) { *hash = fnv(*hash, nals[i].payload, nals[i].sizeBytes); *bytes += nals[i].sizeBytes; } }
      int r = x265_encoder_encode(e, &nals, &n, pic, NULL);
      for (;;) {
        if (r < 0) { fprintf(stderr, "encode failed\n"); exit(1); }
        for (uint32_t i = 0; i < n; i++) { if (nals[i].type < 32 || (nals[i].type >= 32 && nals[i].type <= 34)) { *hash = fnv(*hash, nals[i].payload, nals[i].sizeBytes); *bytes += nals[i].sizeBytes; } }
        if (r == 0 && n == 0) break;
        r = x265_encoder_encode(e, &nals, &n, NULL, NULL);
        if (r == 0) break;
      }
      x265_picture_free(pic);
      x265_encoder_close(e);
      x265_param_free(p);
    }
  }
  return now() - start;
}

int main(void) {
  const Cfg cfgs[] = {
    { "primary 4:4:4 medium crf14", "medium", "i444", "14", "main444-8", 1, 3 },
    { "primary 4:2:0 medium crf14", "medium", "i420", "14", "mainstillpicture", 1, 1 },
    { "OPPO writeback 4:4:4 fast crf14", "fast", "i444", "14", "main444-8", 1, 3 },
    { "gain map gray ultrafast crf18", "ultrafast", "i400", "18", "main444-8", 0, 0 },
  };
  const int W = 3072, H = 4096, GW = 1536, GH = 2048;
  uint8_t *p444 = load("data/primary444.yuv", (size_t)W * H * 3);
  uint8_t *p420 = load("data/primary420.yuv", (size_t)W * H * 3 / 2);
  uint8_t *gray = load("data/gain_gray.yuv", (size_t)GW * GH);
  for (int i = 0; i < 4; i++) {
    const Cfg *c = &cfgs[i];
    uint8_t *raster = c->chroma == 3 ? p444 : c->chroma == 1 ? p420 : gray;
    int w = c->chroma == 0 ? GW : W, h = c->chroma == 0 ? GH : H;
    int tiles = (w / 512) * (h / 512);
    double best = 1e9; uint64_t hash = 0; size_t bytes = 0;
    for (int rep = 0; rep < 2; rep++) {
      uint64_t hh = 1469598103934665603ULL; size_t bb = 0;
      double t = run(c, raster, w, h, &hh, &bb);
      if (t < best) best = t;
      hash = hh; bytes = bb;
    }
    printf("%-34s tiles=%2d total=%7.0f ms  per-tile=%6.1f ms  bytes=%8zu  hash=%016llx\n",
           c->name, tiles, best * 1000, best * 1000 / tiles, bytes, (unsigned long long)hash);
  }
  return 0;
}
