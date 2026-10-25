// Drive 17U camx ParameterSetManager under qemu to fetch chromatix modules.
//   chromatix <tuned.bin> <outdir> <mode-spec> <module>...
//   mode-spec: comma list of type=value (types 0..7: Default,Sensor,Usecase,Feature0,
//              Feature1,Feature2,Scene,Effect), or "-" for the default mode.
// For each module writes <outdir>/<module>@<mode>.mem: records {u64 addr,u32 len,data}
// covering the module struct and every heap chunk reachable from it (scudo-sized).
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct __android_log_message;
extern void __android_log_set_logger(void (*)(const struct __android_log_message*));
extern void __android_log_stderr_logger(const struct __android_log_message*);
extern void __android_log_set_minimum_priority(int32_t);
typedef void (*ctor_t)(void*);
typedef int (*init_t)(void*, void*);
typedef int (*cmt_t)(void*, const char*);
typedef void* (*getc_t)(void*);
typedef void* (*getm_t)(void*, const char*, void*, uint32_t, void*);
#define OFF_CTOR 0x1631da0UL
#define OFF_GETMODULE 0x610c20UL

static int pfd[2] = {-1, -1};
static int readable(uintptr_t a, size_t n, void* out) {
  if (pfd[0] < 0) pipe(pfd);
  size_t done = 0;
  while (done < n) {
    size_t c = n - done > 4096 ? 4096 : n - done;
    if (write(pfd[1], (const char*)a + done, c) != (ssize_t)c) return 0;
    if (read(pfd[0], (char*)out + done, c) != (ssize_t)c) return 0;
    done += c;
  }
  return 1;
}

// scudo: 16-byte header in front of the user pointer.
// bits 0-7 classId, 8-9 state (1 = allocated), 12-31 size (primary) / unused bytes.
static size_t chunk_size(uintptr_t p) {
  uint64_t h;
  if ((p & 0xf) || !readable(p - 16, 8, &h)) return 0;
  unsigned cls = h & 0xff, state = (h >> 8) & 3;
  size_t sz = (h >> 12) & 0xfffff;
  if (state != 1 || cls == 0 || sz == 0) return 0;
  return sz;
}

#define MAXV 200000
static uintptr_t seen[MAXV];
static int nseen;
static int was_seen(uintptr_t a) {
  for (int i = 0; i < nseen; i++) if (seen[i] == a) return 1;
  if (nseen < MAXV) seen[nseen++] = a;
  return 0;
}

static void dump_chunk(FILE* f, uintptr_t a, size_t n, int depth) {
  if (was_seen(a)) return;
  uint8_t* buf = malloc(n);
  if (!buf || !readable(a, n, buf)) { free(buf); return; }
  uint32_t l = (uint32_t)n;
  fwrite(&a, 8, 1, f); fwrite(&l, 4, 1, f); fwrite(buf, 1, n, f);
  if (depth > 0)
    for (size_t o = 0; o + 8 <= n; o += 8) {
      uint64_t p; memcpy(&p, buf + o, 8);
      if ((p >> 48) != 0xb400 || (p & 0xf)) continue;
      size_t s = chunk_size((uintptr_t)p);
      if (s && s <= (16u << 20)) dump_chunk(f, (uintptr_t)p, s, depth - 1);
    }
  free(buf);
}

int main(int argc, char** argv) {
  __android_log_set_logger(__android_log_stderr_logger);
  __android_log_set_minimum_priority(6);
  void* h = dlopen("/vendor/lib64/hw/camera.qcom.core.so", RTLD_NOW | RTLD_GLOBAL);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
  ctor_t ctor = (ctor_t)dlsym(h, "_ZN4CamX17TuningDataManagerC1Ev");
  init_t init = (init_t)dlsym(h, "_ZN4CamX17TuningDataManager10InitializeEPNS_27TuningDataManagerCreateInfoE");
  cmt_t cmt = (cmt_t)dlsym(h, "_ZN4CamX17TuningDataManager19CreateTunedModeTreeEPKc");
  getc_t getc = (getc_t)dlsym(h, "_ZN4CamX17TuningDataManager12GetChromatixEv");
  getm_t getm = (getm_t)((uintptr_t)ctor - OFF_CTOR + OFF_GETMODULE);
  void* tdm = calloc(1, 0x1000);
  ctor(tdm);
  init(tdm, NULL);
  cmt(tdm, argv[1]);
  void* psm = getc(tdm);
  if (!psm) { printf("no chromatix\n"); return 2; }

  uint32_t modes[16][2]; uint32_t nm = 0;
  char spec[256]; snprintf(spec, sizeof spec, "%s", argv[3]);
  if (strcmp(spec, "-")) {
    for (char* t = strtok(spec, ","); t && nm < 16; t = strtok(NULL, ",")) {
      unsigned ty, va;
      if (sscanf(t, "%u=%u", &ty, &va) == 2) { modes[nm][0] = ty; modes[nm][1] = va; nm++; }
    }
  }
  for (int i = 4; i < argc; i++) {
    nseen = 0;
    uint8_t* node = (uint8_t*)getm(psm, argv[i], nm ? (void*)modes : NULL, nm, NULL);
    printf("%s mode=%s node=%p\n", argv[i], argv[3], node);
    if (!node) continue;
    char fn[512];
    snprintf(fn, sizeof fn, "%s/%s@%s.mem", argv[2], argv[i], argv[3]);
    FILE* f = fopen(fn, "wb");
    size_t ns = chunk_size((uintptr_t)node);
    // record 0: the node chunk (header + inline module struct); follow only its struct part
    uintptr_t a = (uintptr_t)node;
    uint32_t l = ns ? (uint32_t)ns : 0x200;
    uint8_t* buf = malloc(l);
    readable(a, l, buf);
    fwrite(&a, 8, 1, f); fwrite(&l, 4, 1, f); fwrite(buf, 1, l, f);
    was_seen(a);
    for (size_t o = 0x68; o + 8 <= l; o += 8) {
      uint64_t p; memcpy(&p, buf + o, 8);
      if ((p >> 48) != 0xb400 || (p & 0xf)) continue;
      size_t s = chunk_size((uintptr_t)p);
      if (s && s <= (16u << 20)) dump_chunk(f, (uintptr_t)p, s, 12);
    }
    free(buf);
    fclose(f);
  }
  return 0;
}
