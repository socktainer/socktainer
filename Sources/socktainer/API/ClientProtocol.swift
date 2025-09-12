import Foundation
import ContainerClient

public protocol ClientProtocol: Sendable {
    func ping() async throws
    func getContainer(id: String) async throws -> ClientContainer?
}