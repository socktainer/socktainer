import ContainerizationOCI
import Foundation

/// One classification boundary for OCI artifacts and BuildKit attestations.
///
/// OCI permits artifact metadata on both the referring descriptor and the
/// referenced manifest/index document. BuildKit additionally uses descriptor
/// or document annotations. Callers must consider every location; otherwise an
/// attestation can be mistaken for a runnable image merely by moving the marker
/// into the content document.
enum OCIArtifactSemantics {
    static let buildKitReferenceTypeAnnotation =
        "vnd.docker.reference.type"
    static let buildKitReferenceDigestAnnotation =
        "vnd.docker.reference.digest"
    static let buildKitAttestationManifest = "attestation-manifest"

    struct Classification: Sendable, Equatable {
        let isArtifact: Bool
        let subjectDigest: String?
    }

    static func classify(
        descriptor: Descriptor,
        manifest: Manifest?
    ) -> Classification {
        classify(
            descriptor: descriptor,
            documentArtifactType: manifest?.artifactType,
            documentSubject: manifest?.subject,
            documentAnnotations: manifest?.annotations
        )
    }

    static func classify(
        descriptor: Descriptor,
        index: Index?
    ) -> Classification {
        classify(
            descriptor: descriptor,
            documentArtifactType: index?.artifactType,
            documentSubject: index?.subject,
            documentAnnotations: index?.annotations
        )
    }

    static func classify(descriptor: Descriptor) -> Classification {
        classify(
            descriptor: descriptor,
            documentArtifactType: nil,
            documentSubject: nil,
            documentAnnotations: nil
        )
    }

    private static func classify(
        descriptor: Descriptor,
        documentArtifactType: String?,
        documentSubject: Descriptor?,
        documentAnnotations: [String: String]?
    ) -> Classification {
        let descriptorSubject = normalizedValue(
            descriptor.annotations?[buildKitReferenceDigestAnnotation]
        )
        let documentAnnotatedSubject = normalizedValue(
            documentAnnotations?[buildKitReferenceDigestAnnotation]
        )
        return Classification(
            isArtifact: descriptor.artifactType != nil
                || isBuildKitAttestation(descriptor.annotations)
                || documentArtifactType != nil
                || documentSubject != nil
                || isBuildKitAttestation(documentAnnotations),
            subjectDigest: descriptorSubject
                ?? documentSubject?.digest
                ?? documentAnnotatedSubject
        )
    }

    private static func isBuildKitAttestation(
        _ annotations: [String: String]?
    ) -> Bool {
        normalizedValue(
            annotations?[buildKitReferenceTypeAnnotation]
        )?.lowercased() == buildKitAttestationManifest
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard
            let normalized = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }
}
