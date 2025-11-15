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

const char* get_docker_engine_api_min_version(void) {
    return DOCKER_ENGINE_API_MIN_VERSION;
}

const char* get_docker_engine_api_max_version(void) {
    return DOCKER_ENGINE_API_MAX_VERSION;
}

const char* get_apple_container_version(void) {
    return APPLE_CONTAINER_VERSION;
}
