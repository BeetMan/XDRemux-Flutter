// Run the original 17U TMC202 interpolation (libhwliqinterface2.so FUN 0xd98340) under qemu.
//   tmc <tuned.bin> <modespec> <in.bin> <out.bin>
// in.bin  : f32 drc, f32 drc_dark, f32 lux, f32 prev_lux, f32 leaf[75], u32 bhist[1024]
// out.bin : state buffer (0x2000 bytes) after the call; la_curve at +0x119c (65 f32)
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct __android_log_message;
extern void __android_log_set_logger(void (*)(const struct __android_log_message*));
extern void __android_log_stderr_logger(const struct __android_log_message*);
extern void __android_log_set_minimum_priority(int32_t);
typedef void (*ctor_t)(void*);
typedef int (*init_t)(void*, void*);
typedef int (*cmt_t)(void*, const char*);
typedef void* (*getc_t)(void*);
typedef void* (*getm_t)(void*, const char*, void*, uint32_t, void*);
typedef int (*tmc_t)(void* in, float* data, void* trig, void* vec);
#define OFF_CTOR 0x1631da0UL
#define OFF_GETMODULE 0x610c20UL
#define OFF_TMC_MAIN 0xd98340UL
#define STATE_SIZE 0x2000

int main(int argc, char** argv) {
  __android_log_set_logger(__android_log_stderr_logger);
  __android_log_set_minimum_priority(6);
  void* h = dlopen("/vendor/lib64/hw/camera.qcom.core.so", RTLD_NOW | RTLD_GLOBAL);
  if (!h) { printf("dlopen core: %s\n", dlerror()); return 1; }
  ctor_t ctor = (ctor_t)dlsym(h, "_ZN4CamX17TuningDataManagerC1Ev");
  init_t init = (init_t)dlsym(h, "_ZN4CamX17TuningDataManager10InitializeEPNS_27TuningDataManagerCreateInfoE");
  cmt_t cmt = (cmt_t)dlsym(h, "_ZN4CamX17TuningDataManager19CreateTunedModeTreeEPKc");
  getc_t getc = (getc_t)dlsym(h, "_ZN4CamX17TuningDataManager12GetChromatixEv");
  getm_t getm = (getm_t)((uintptr_t)ctor - OFF_CTOR + OFF_GETMODULE);
  void* hi = dlopen("/vendor/lib64/libhwliqinterface2.so", RTLD_NOW | RTLD_GLOBAL);
  if (!hi) { printf("dlopen iq: %s\n", dlerror()); return 1; }
  void* anchor = dlsym(hi, "_ZN4CamX12IQInterface214GetNumTriggersEv");
  Dl_info di; dladdr(anchor, &di);
  tmc_t tmc = (tmc_t)((uintptr_t)di.dli_fbase + OFF_TMC_MAIN);

  void* tdm = calloc(1, 0x1000);
  ctor(tdm); init(tdm, NULL); cmt(tdm, argv[1]);
  void* psm = getc(tdm);
  uint32_t modes[16][2]; uint32_t nm = 0;
  char spec[256]; snprintf(spec, sizeof spec, "%s", argv[2]);
  for (char* t = strtok(spec, ","); t && nm < 16; t = strtok(NULL, ",")) {
    unsigned ty, va;
    if (sscanf(t, "%u=%u", &ty, &va) == 2) { modes[nm][0] = ty; modes[nm][1] = va; nm++; }
  }
  uint8_t* node = (uint8_t*)getm(psm, "tmc202_sw_v2", modes, nm, NULL);
  if (!node) { printf("no tmc202 node\n"); return 2; }

  FILE* f = fopen(argv[3], "rb");
  float hdr[4]; float leaf[75]; uint32_t* bhist = calloc(1024, 4);
  if (fread(hdr, 4, 4, f) != 4 || fread(leaf, 4, 75, f) != 75 || fread(bhist, 4, 1024, f) != 1024) {
    printf("bad input\n"); return 3;
  }
  fclose(f);

  uint8_t* in = calloc(1, 0x200);
  uint8_t* state = calloc(1, STATE_SIZE);
  uint8_t* nodes = calloc(4, 0x48);
  float* data = calloc(2 * 75, 4);
  memcpy(data + 75, leaf, 300);
  float* trig = calloc(64, 4);
  uint32_t* tlist = calloc(4, 4); tlist[0] = 0;
  void* vec[2] = {tlist, tlist + 1};
  *(void**)(in + 0x00) = node + 0x68;
  *(float*)(in + 0x0c) = hdr[0];
  *(float*)(in + 0x10) = hdr[2];
  *(float*)(in + 0x14) = hdr[3];
  *(float*)(in + 0x18) = hdr[1];
  *(void**)(in + 0x20) = bhist;
  *(void**)(in + 0x28) = NULL;            // no face
  *(float*)(in + 0x34) = 1.0f;            // scaleRatioWB_current
  *(float*)(in + 0x3c) = 1.0f;            // faceAdjRatioPrev
  *(void**)(in + 0x60) = nodes;
  *(uint32_t*)(in + 0x68) = 1;            // region nodes
  *(uint32_t*)(in + 0x6c) = 1;            // leaves
  *(void**)(in + 0x70) = state;
  int r = tmc(in, data, trig, vec);
  printf("tmc rc=%d histmode=%u la[64]=%f\n", r, *(uint8_t*)(node + 0x68 + 0x6c), *(float*)(state + 0x129c));
  f = fopen(argv[4], "wb");
  fwrite(state, 1, STATE_SIZE, f);
  fwrite(data, 4, 75, f);
  fclose(f);
  return 0;
}
