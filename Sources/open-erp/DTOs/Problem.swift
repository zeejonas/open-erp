import Vapor

/// RFC 9457 problem details. Clients branch on code/status, not title/detail.
struct Problem: Content {
    var type: String
    var title: String
    var status: UInt
    var detail: String
    var code: ProblemCode

    init(status: HTTPStatus, detail: String, code: ProblemCode) {
        self.type = "urn:open-erp:problem:\(code.rawValue)"
        self.title = status.reasonPhrase
        self.status = status.code
        self.detail = detail
        self.code = code
    }
}

/// `CaseIterable` lets VaporToOpenAPI publish the code catalog as a schema enum.
enum ProblemCode: String, Codable, CaseIterable, Sendable {
    case badRequest = "bad_request"
    case unauthorized
    case forbidden
    case notFound = "not_found"
    case conflict
    case payloadTooLarge = "payload_too_large"
    case unsupportedMediaType = "unsupported_media_type"
    case tooManyRequests = "too_many_requests"
    case internalError = "internal_error"
    case httpError = "http_error"
    case invalidAccessToken = "invalid_access_token"

    init(status: HTTPStatus) {
        switch status.code {
        case 400: self = .badRequest
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404: self = .notFound
        case 409: self = .conflict
        case 413: self = .payloadTooLarge
        case 415: self = .unsupportedMediaType
        case 429: self = .tooManyRequests
        case 500...599: self = .internalError
        default: self = .httpError
        }
    }
}

/// Use an explicit code only when it offers a distinct client recovery action.
struct ProblemAbort: AbortError {
    let status: HTTPStatus
    let code: ProblemCode
}
