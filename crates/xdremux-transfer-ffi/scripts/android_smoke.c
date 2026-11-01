/* Test-only dlopen harness: shell lifecycle/ABI validation, no application claim. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../include/xdremux_transfer.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "check failed at line %d\n", __LINE__); exit(1); } } while (0)
#define LOAD(name) __typeof__(&xdremux_transfer_##name) name = dlsym(lib, "xdremux_transfer_" #name); CHECK(name)

static char *field(const char *json, const char *name, char *out, size_t capacity) {
    char key[128]; snprintf(key, sizeof key, "\"%s\":\"", name);
    const char *start = strstr(json, key); CHECK(start); start += strlen(key);
    const char *end = strchr(start, '"'); CHECK(end && (size_t)(end - start) < capacity);
    memcpy(out, start, end - start); out[end - start] = 0; return out;
}

int main(int argc, char **argv) {
    CHECK(argc == 3);
    CHECK(strspn(argv[2], "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") == strlen(argv[2]));
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); CHECK(lib);
    LOAD(abi_version); LOAD(create); LOAD(submit); LOAD(poll); LOAD(stop); LOAD(release); LOAD(free_string);
    CHECK(abi_version() == 65539); CHECK(stop(0) == 2);
    uint64_t h = 0, op = 0;
    CHECK(create(NULL, 1, &h) == 1);
    CHECK(create((const uint8_t *)"{}", 65537, &h) == 1);
    char config[2048], address[128] = "", fingerprint[128] = "", instance[128] = "";
    for (int round = 0; round < 3; ++round) {
        if (!round) snprintf(config, sizeof config, "{\"root\":\"%s\"}", argv[2]);
        else snprintf(config, sizeof config, "{\"root\":\"%s\",\"bind\":\"%s\"}", argv[2], address);
        CHECK(create((const uint8_t *)config, strlen(config), &h) == 0);
        CHECK(release(h) == 3);
        int ready = 0;
        for (int i = 0; i < 6000 && !ready; ++i) {
            char *json = NULL; CHECK(poll(h, 128, 2097152, &json) == 0);
            CHECK(!strstr(json, "\"kind\":\"start_failed\""));
            ready = strstr(json, "\"phase\":1") != NULL;
            if (ready) {
                char new_fp[128], new_instance[128];
                field(json, "address", address, sizeof address);
                field(json, "fingerprint", new_fp, sizeof new_fp);
                field(json, "core_instance_id", new_instance, sizeof new_instance);
                if (round) { CHECK(!strcmp(new_fp, fingerprint)); CHECK(strcmp(new_instance, instance)); }
                strcpy(fingerprint, new_fp); strcpy(instance, new_instance);
            }
            CHECK(free_string(json) == 0); CHECK(free_string(json) == 1);
            if (!ready) usleep(10000);
        }
        CHECK(ready);
        const char *cmd = "{\"command\":\"snapshot\",\"limit\":64}";
        CHECK(submit(h, (const uint8_t *)cmd, strlen(cmd), &op) == 0);
        int result = 0;
        for (int i = 0; i < 1000 && !result; ++i) {
            char *json = NULL; CHECK(poll(h, 128, 2097152, &json) == 0);
            result = strstr(json, "\"transfers\":[]") != NULL;
            CHECK(free_string(json) == 0); if (!result) usleep(10000);
        }
        CHECK(result);
        CHECK(stop(h) == 0); CHECK(stop(h) == 0);
        int stopped = 0;
        for (int i = 0; i < 1000 && !stopped; ++i) {
            char *json = NULL; CHECK(poll(h, 128, 2097152, &json) == 0);
            stopped = strstr(json, "\"phase\":3") != NULL;
            CHECK(free_string(json) == 0); if (!stopped) usleep(10000);
        }
        CHECK(stopped); CHECK(release(h) == 0); CHECK(release(h) == 2); CHECK(stop(h) == 2);
    }
    CHECK(free_string(NULL) == 0);
    CHECK(dlclose(lib) == 0);
    puts("{\"passed\":true,\"abi\":65539,\"rounds\":3,\"samePortAndRootReopened\":true,\"stableCertificate\":true,\"newInstances\":true,\"snapshot\":true,\"invalidHandlesAndInputs\":true,\"pairedBufferFree\":true}");
    return 0;
}
