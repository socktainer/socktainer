import Foundation
import Vapor

public struct RESTContainerWait: Content {
    public let StatusCode: Int64
    public let Error: ContainerWaitExitError?
    public init(statusCode: Int64, error: ContainerWaitExitError? = nil) {

        self.StatusCode = statusCode
        self.Error = error

    }
}
