// ohpm.exe shim: forwards to DevEco Studio's ohpm (pm-cli.js) via node.exe.
// Bare `ohpm` is unresolvable by CreateProcess on Windows (CPF-Flutter's tool
// spawns it bare); bypassing cmd/.bat sidesteps cmd /c quoting pitfalls with
// spaces in the DevEco path.
#include <windows.h>
#include <stdio.h>

int main(int argc, char **argv) {
    const char *home = getenv("DEVECO_HOME");
    char cli[MAX_PATH];
    if (home && home[0]) {
        snprintf(cli, sizeof(cli), "%s/tools/ohpm/bin/pm-cli.js", home);
    } else {
        snprintf(cli, sizeof(cli), "%s",
                 "C:/Program Files/Huawei/DevEco Studio/tools/ohpm/bin/pm-cli.js");
    }
    char cmd[8192];
    int n = snprintf(cmd, sizeof(cmd), "node \"%s\"", cli);
    for (int i = 1; i < argc && n > 0; i++) {
        n += snprintf(cmd + n, sizeof(cmd) - (size_t)n, " \"%s\"", argv[i]);
    }
    if (n <= 0 || n >= (int)sizeof(cmd)) return 3;

    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi = { 0 };
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "ohpm-shim: CreateProcess failed (%lu)\n", GetLastError());
        return 2;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}
