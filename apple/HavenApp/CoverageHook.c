// Coverage flush for the hosted macOS unit tests (HavenMacUnitTests).
//
// The host is a sandboxed app that Xcode points at a profile path inside its CONTAINER, which
// xcodebuild is not allowed to read back (macOS App Data protection) — so a hosted run reported no
// coverage at all. The profile runtime inside the app is also linked hidden, so the test bundle
// cannot reach it with dlsym. This hook lives in the host image, where the runtime is visible: it
// serializes the in-memory counters (the runtime's buffer API, which does not care whether Xcode's
// own exit hook already wrote them) and saves them to a path the host's entitlements allow
// (build-output roots only).
//
// Compiled into every target that builds HavenApp/, but only the UI-test host defines
// HAVEN_UNIT_TEST_HOST, so everywhere else this file is empty. The runtime symbols are weak: a build
// without coverage instrumentation links and the hook is a no-op.
#if defined(HAVEN_UNIT_TEST_HOST)
#include <stdio.h>
#include <stdlib.h>

extern unsigned long long __llvm_profile_get_size_for_buffer(void) __attribute__((weak));
extern int __llvm_profile_write_buffer(char *) __attribute__((weak));

// Returns 0 when the profile was written to `path`, -2 when this build has no profile runtime.
int HavenCoverageFlush(const char *path) {
    if (!path || !__llvm_profile_get_size_for_buffer || !__llvm_profile_write_buffer) return -2;
    unsigned long long size = __llvm_profile_get_size_for_buffer();
    char *buffer = (char *)malloc((size_t)size);
    if (!buffer) return -3;
    int rc = __llvm_profile_write_buffer(buffer);
    if (rc == 0) {
        FILE *f = fopen(path, "wb");
        if (!f) rc = -4;
        else {
            if (fwrite(buffer, 1, (size_t)size, f) != (size_t)size) rc = -5;
            fclose(f);
        }
    }
    free(buffer);
    return rc;
}
#else
typedef int haven_coverage_hook_unused;
#endif
