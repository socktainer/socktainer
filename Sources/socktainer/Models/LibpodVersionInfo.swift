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
    /// podman reports the server's API version from the `Podman Engine` component's
    /// `Details.APIVersion`, falling back to the top-level (Docker) `APIVersion`.
    let Components: [LibpodVersionComponent]
}

struct LibpodVersionComponent: Content {
    let Name: String
    let Version: String
    let Details: [String: String]
}
