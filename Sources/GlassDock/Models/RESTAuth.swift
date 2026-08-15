import Vapor

struct AuthResponse: Content {
    let Status: String
    let IdentityToken: String?
}
