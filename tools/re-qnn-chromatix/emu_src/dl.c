#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
struct __android_log_message;
typedef void (*logger_fn)(const struct __android_log_message*);
extern void __android_log_set_logger(logger_fn);
extern void __android_log_stderr_logger(const struct __android_log_message*);
extern void __android_log_set_minimum_priority(int32_t);
int main(int argc, char** argv) {
  __android_log_set_logger(__android_log_stderr_logger);
  __android_log_set_minimum_priority(2);
  for (int i = 1; i < argc; i++) {
    void* h = dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL);
    printf("%s -> %p %s\n", argv[i], h, h ? "" : dlerror());
  }
  return 0;
}
