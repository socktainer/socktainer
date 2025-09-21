#ifndef BUILD_VERSION
#define BUILD_VERSION "0.0.0-dev"
#endif

#ifndef BUILD_GIT_COMMIT
#define BUILD_GIT_COMMIT "unspecified"
#endif

#ifndef BUILD_TIME
#define BUILD_TIME "unspecified"
#endif

#ifndef DOCKER_ENGINE_API_MIN_VERSION
#define DOCKER_ENGINE_API_MIN_VERSION "1.51"
#endif

#ifndef DOCKER_ENGINE_API_MAX_VERSION
#define DOCKER_ENGINE_API_MAX_VERSION "1.51"
#endif

const char* get_build_version();

const char* get_build_git_commit();

const char* get_build_time();

const char* get_docker_engine_api_min_version();

const char* get_docker_engine_api_max_version();
