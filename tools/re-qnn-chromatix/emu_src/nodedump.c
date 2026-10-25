// Dump the raw chromatix node returned by the original TuningDataManager for a module + mode.
//   nodedump <tuned.bin> <module> <modespec> <nbytes>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*ctor_t)(void*);
typedef int (*init_t)(void*, void*);
typedef int (*cmt_t)(void*, const char*);
typedef void* (*getc_t)(void*);
typedef void* (*getm_t)(void*, const char*, void*, uint32_t, void*);
#define OFF_CTOR 0x1631da0UL
#define OFF_GETMODULE 0x610c20UL

int main(int argc, char** argv) {
  void* h = dlopen("/vendor/lib64/hw/camera.qcom.core.so", RTLD_NOW | RTLD_GLOBAL);
  if (!h) { printf("dlopen core: %s\n", dlerror()); return 1; }
  ctor_t ctor = (ctor_t)dlsym(h, "_ZN4CamX17TuningDataManagerC1Ev");
  init_t init = (init_t)dlsym(h, "_ZN4CamX17TuningDataManager10InitializeEPNS_27TuningDataManagerCreateInfoE");
  cmt_t cmt = (cmt_t)dlsym(h, "_ZN4CamX17TuningDataManager19CreateTunedModeTreeEPKc");
  getc_t getc = (getc_t)dlsym(h, "_ZN4CamX17TuningDataManager12GetChromatixEv");
  getm_t getm = (getm_t)((uintptr_t)ctor - OFF_CTOR + OFF_GETMODULE);
  void* tdm = calloc(1, 0x1000);
  ctor(tdm); init(tdm, NULL); cmt(tdm, argv[1]);
  void* psm = getc(tdm);
  uint32_t modes[16][2]; uint32_t nm = 0;
  char spec[256]; snprintf(spec, sizeof spec, "%s", argv[3]);
  for (char* t = strtok(spec, ","); t && nm < 16; t = strtok(NULL, ",")) {
    unsigned ty, va;
    if (sscanf(t, "%u=%u", &ty, &va) == 2) { modes[nm][0] = ty; modes[nm][1] = va; nm++; }
  }
  uint8_t* node = (uint8_t*)getm(psm, argv[2], modes, nm, NULL);
  if (!node) { printf("no node\n"); return 2; }
  int n = atoi(argv[4]);
  for (int i = 0; i < n; i += 4) {
    if (i % 32 == 0) printf("\n%04x:", i);
    printf(" %08x", *(uint32_t*)(node + i));
  }
  printf("\n");
  for (int i = 0; i + 8 <= n; i += 4) {           // follow heap pointers in the header
    uint64_t p = *(uint64_t*)(node + i);
    if ((p >> 40) == 0xb40000 || (p >> 40) == 0xb40040 || ((p >> 32) & 0xffffff00) == 0xb4004000) {
      printf("ptr@%04x ->", i);
      for (int k = 0; k < 24; k++) printf(" %08x", ((uint32_t*)(uintptr_t)p)[k]);
      printf("\n");
    }
  }
  return 0;
}
