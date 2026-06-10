/*
 * Multi-environment variant fixture for compare_variants and env_branches queries.
 *
 * Compile variant A: cc -DPLATFORM_LINUX=1 platform.c
 * Compile variant B: cc -DPLATFORM_WINDOWS=1 platform.c
 *
 * Expected env_branches output:
 *   env_sensitive_branches: [{function:"init_socket", condition:"platform == LINUX", ...}]
 *
 * Expected compare_variants diff:
 *   only_in_variant_a: ["socket_linux_init"]
 *   only_in_variant_b: ["socket_windows_init"]
 */
#include <stdlib.h>

/* variant-specific implementations */
#ifdef PLATFORM_LINUX
static void socket_linux_init(void) { /* epoll-based */ }
#endif

#ifdef PLATFORM_WINDOWS
static void socket_windows_init(void) { /* iocp-based */ }
#endif

/* runtime env branch (also detected by env_branches query) */
void init_socket(int platform) {
    if (platform == 1) {          /* LINUX */
#ifdef PLATFORM_LINUX
        socket_linux_init();
#endif
    } else if (platform == 2) {   /* WINDOWS */
#ifdef PLATFORM_WINDOWS
        socket_windows_init();
#endif
    }
}

void get_config(const char *env, char *out, int max) {
    const char *val = getenv(env);   /* env_branches should flag this */
    if (val) {
        int i = 0;
        while (i < max - 1 && val[i]) { out[i] = val[i]; i++; }
        out[i] = '\0';
    }
}

int main(void) { return 0; }
