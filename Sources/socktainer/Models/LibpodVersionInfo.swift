import Vapor

struct LibpodVersionInfo: Content {
    let APIVersion: String
    let Arch: String
    let BuildTime: String
    let GitCommit: String
    let GoVersion: String
    let MinAPIVersion: String
    let Os: String
    let Version: String
}
