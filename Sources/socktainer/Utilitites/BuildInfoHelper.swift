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
