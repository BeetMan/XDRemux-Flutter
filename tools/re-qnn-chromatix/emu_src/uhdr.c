// ROM libultrahdr harness (run under qemu).
//   uhdr dec <in.jpg> <out.raw> <max_boost>   : decode to linear RGBA half-float, print metadata
//   uhdr enc <base.jpg> <gainmap.jpg> <max_boost> <out.jpg> : JPEG_R from compressed images + metadata
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int error_code; int has_detail; char detail[256]; } uhdr_error_info_t;
typedef struct { int fmt, cg, ct, range; unsigned w, h; void* planes[3]; unsigned stride[3]; } uhdr_raw_image_t;
typedef struct { void* data; size_t data_sz; size_t capacity; int cg, ct, range; } uhdr_compressed_image_t;
typedef struct { float f[32]; } meta_t;   // layout probed at run time (scalar or [3] arrays)

extern void* uhdr_create_decoder(void);
extern uhdr_error_info_t uhdr_dec_set_image(void*, uhdr_compressed_image_t*);
extern uhdr_error_info_t uhdr_dec_set_out_img_format(void*, int);
extern uhdr_error_info_t uhdr_dec_set_out_color_transfer(void*, int);
extern uhdr_error_info_t uhdr_dec_set_out_max_display_boost(void*, float);
extern uhdr_error_info_t uhdr_decode(void*);
extern uhdr_raw_image_t* uhdr_get_decoded_image(void*);
extern uhdr_raw_image_t* uhdr_get_decoded_gainmap_image(void*);
extern meta_t* uhdr_dec_get_gainmap_metadata(void*);
extern void* uhdr_create_encoder(void);
extern uhdr_error_info_t uhdr_enc_set_compressed_image(void*, uhdr_compressed_image_t*, int);
extern uhdr_error_info_t uhdr_enc_set_gainmap_image(void*, uhdr_compressed_image_t*, void*);
extern uhdr_error_info_t uhdr_encode(void*);
extern uhdr_compressed_image_t* uhdr_get_encoded_stream(void*);

extern uhdr_error_info_t f2frac(const void*, void*) __asm__("_ZN8ultrahdr26uhdr_gainmap_metadata_frac30gainmapMetadataFloatToFractionEPKNS_25uhdr_gainmap_metadata_extEPS0_");
extern uhdr_error_info_t encmeta(const void*, void*) __asm__("_ZN8ultrahdr26uhdr_gainmap_metadata_frac21encodeGainmapMetadataEPKS0_RNSt3__16vectorIhNS3_9allocatorIhEEEE");

static void* slurp(const char* p, size_t* n) {
  FILE* f = fopen(p, "rb"); if (!f) { printf("open %s\n", p); exit(2); }
  fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
  void* b = malloc(*n); fread(b, 1, *n, f); fclose(f); return b;
}
#define CHK(x) do { uhdr_error_info_t er_ = (x); if (er_.error_code) { printf("ERR %s: %d %s\n", #x, er_.error_code, er_.has_detail ? er_.detail : ""); return 1; } } while (0)

int main(int argc, char** argv) {
  if (argc >= 5 && !strcmp(argv[1], "dec")) {
    size_t n; void* b = slurp(argv[2], &n);
    uhdr_compressed_image_t ci = {b, n, n, -1, -1, -1};
    void* d = uhdr_create_decoder();
    CHK(uhdr_dec_set_image(d, &ci));
    CHK(uhdr_dec_set_out_img_format(d, 4));      // 64bppRGBAHalfFloat
    CHK(uhdr_dec_set_out_color_transfer(d, 0));  // linear
    CHK(uhdr_dec_set_out_max_display_boost(d, (float)atof(argv[4])));
    CHK(uhdr_decode(d));
    uhdr_raw_image_t* o = uhdr_get_decoded_image(d);
    meta_t* m = uhdr_dec_get_gainmap_metadata(d);
    printf("out %ux%u fmt=%d cg=%d ct=%d stride=%u\nmeta:", o->w, o->h, o->fmt, o->cg, o->ct, o->stride[0]);
    for (int i = 0; i < 24; i++) printf(" %g", m->f[i]);
    printf("\n");
    FILE* f = fopen(argv[3], "wb");
    for (unsigned y = 0; y < o->h; y++) fwrite((char*)o->planes[0] + (size_t)y * o->stride[0] * 8, 8, o->w, f);
    fclose(f);
    return 0;
  }
  if (argc >= 6 && !strcmp(argv[1], "enc")) {
    size_t n1, n2; void* b1 = slurp(argv[2], &n1); void* b2 = slurp(argv[3], &n2);
    uhdr_compressed_image_t base = {b1, n1, n1, argc > 6 ? atoi(argv[6]) : 0, 3, 1};  // cg (0 BT709, 1 P3), sRGB TF, full
    uhdr_compressed_image_t gm = {b2, n2, n2, -1, -1, -1};
    float mb = (float)atof(argv[4]);
    // array layout (probed from the ROM decoder): max[3],min[3],gamma[3],off_sdr[3],off_hdr[3],cap_min,cap_max,use_base_cg
    float meta_scalar[18] = {mb, mb, mb, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, mb, 0};
    ((int*)meta_scalar)[17] = 1;
    void* e = uhdr_create_encoder();
    CHK(uhdr_enc_set_compressed_image(e, &base, 2));           // UHDR_BASE_IMG
    CHK(uhdr_enc_set_gainmap_image(e, &gm, meta_scalar));
    CHK(uhdr_encode(e));
    uhdr_compressed_image_t* o = uhdr_get_encoded_stream(e);
    FILE* f = fopen(argv[5], "wb"); fwrite(o->data, 1, o->data_sz, f); fclose(f);
    printf("encoded %zu bytes\n", o->data_sz);
    return 0;
  }
  if (argc >= 3 && !strcmp(argv[1], "iso")) {      // iso <max_boost> : ISO 21496-1 payload (hex)
    float mb = (float)atof(argv[2]);
    unsigned char ext[128]; memset(ext, 0, sizeof ext);
    float* f = (float*)ext;
    for (int i = 0; i < 3; i++) { f[i] = mb; f[3 + i] = 1; f[6 + i] = 1; f[9 + i] = 0; f[12 + i] = 0; }
    f[15] = 1; f[16] = mb; ((int*)ext)[17] = 1;
    ext[72] = 3 << 1; memcpy(ext + 73, "1.0", 4);           // libc++ short std::string "1.0"
    unsigned char frac[1024]; memset(frac, 0, sizeof frac);
    CHK(f2frac(ext, frac));
    void* vec[3] = {0, 0, 0};
    CHK(encmeta(frac, vec));
    unsigned char* b = vec[0]; size_t n = (unsigned char*)vec[1] - b;
    printf("iso %zu:", n);
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
    return 0;
  }
  printf("usage\n");
  return 1;
}
