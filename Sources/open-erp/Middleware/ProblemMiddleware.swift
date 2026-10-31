import Vapor

struct ProblemMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let abort = error as? any AbortError
            let status = abort?.status ?? .internalServerError
            let code = (error as? ProblemAbort)?.code ?? ProblemCode(status: status)
            let isServerError = status.code >= 500
            let detail = isServerError ? "Something went wrong." : (abort?.reason ?? status.reasonPhrase)
            var headers = abort?.headers ?? [:]
            if status == .unauthorized, !headers.contains(name: .wwwAuthenticate) {
                // RFC 6750 §3.1: a rejected token gets an error code; a missing one does not.
                headers.add(name: .wwwAuthenticate, value: code == .invalidAccessToken ? #"Bearer error="invalid_token""# : "Bearer")
            }

            // Client errors stay out of logs beyond status and code, since their reasons and URLs may carry
            // submitted values. Server errors keep diagnostics, matching Vapor's `Logger.report(error:)`.
            var metadata: Logger.Metadata = ["status": "\(status.code)", "code": "\(code.rawValue)"]
            if isServerError { metadata["error"] = "\(String(reflecting: error))" }
            request.logger.log(level: isServerError ? .error : .warning, "Request failed", metadata: metadata)

            let response = Response(status: status, headers: headers)
            try response.content.encode(Problem(status: status, detail: detail, code: code), as: .json)
            response.headers.contentType = .problemJSON
            return response
        }
    }
}

extension HTTPMediaType {
    static let problemJSON = HTTPMediaType(type: "application", subType: "problem+json")
}

func configureProblemMiddleware(_ app: Application) {
    // Replace Vapor's default formatter; keep its route logging middleware.
    app.middleware = .init()
    app.middleware.use(RouteLoggingMiddleware(logLevel: .info))
    app.middleware.use(ProblemMiddleware())
}
