import BuildInfo

// Get values from C functions and convert to Swift String

public func getBuildVersion() -> String {
    String(cString: get_build_version())
}

public func getBuildGitCommit() -> String {
    String(cString: get_build_git_commit())
}

public func getBuildTime() -> String {
    String(cString: get_build_time())
}

public func getDockerEngineApiMinVersion() -> String {
    String(cString: get_docker_engine_api_min_version())
}

public func getDockerEngineApiMaxVersion() -> String {
    String(cString: get_docker_engine_api_max_version())
}
