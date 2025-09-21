#include "BuildInfo.h"

const char* get_build_version(void) {
    return BUILD_VERSION;
}

const char* get_build_git_commit(void) {
    return BUILD_GIT_COMMIT;
}

const char* get_build_time(void) {
    return BUILD_TIME;
}
