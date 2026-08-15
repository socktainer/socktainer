enum DockerImageReferenceSemantics {
    /// Physical Apple-store references that retain content but never represent
    /// a Docker repository/tag/digest association.
    static func isInternalReference(_ reference: String) -> Bool {
        ContainerImageLease.isReference(reference)
            || reference.hasPrefix("moby-dangling@sha256:")
            || reference.hasPrefix("untagged@sha256:")
            || reference.hasPrefix("<none>")
    }

    /// Distribution-reference parsing treats `sha256:<hex>` as a repository
    /// named `sha256` plus a tag. Docker reserves the full 64-hex spelling as
    /// an immutable image ID, and Apple may use that spelling as a physical
    /// retention key. Keep it out of every Docker tag-ownership path.
    static func isBareSHA256Identifier(_ reference: String) -> Bool {
        guard reference.hasPrefix("sha256:") else { return false }
        let hex = reference.dropFirst("sha256:".count)
        return hex.count == 64
            && hex.allSatisfy { character in
                character.isNumber || ("a"..."f").contains(character.lowercased())
            }
    }
}
