import Fluent
import Vapor

struct PlatformAdminCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "email")
        var email: String

        @Argument(name: "first-name")
        var firstName: String

        @Argument(name: "last-name")
        var lastName: String

        @Argument(name: "subject")
        var subject: String

        @Flag(name: "revoke", help: "Clear platform administrator access")
        var revoke: Bool
    }

    var help: String {
        "Create or update a user, bind an OIDC subject, and grant platform administrator access. Pass --revoke to clear the flag."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let db = context.application.db
        let existing = try await User.find(email: signature.email, on: db)
        if let existing, let bound = existing.authSubject, bound != signature.subject {
            throw PlatformAdminCommandError(description: "Subject conflict: \(signature.email) is bound to a different subject")
        }
        if let other = try await User.query(on: db).filter(\.$authSubject == signature.subject).first(),
            other.id != existing?.id
        {
            throw PlatformAdminCommandError(description: "Subject conflict: subject is already bound to another user")
        }

        if signature.revoke {
            guard let existing else {
                throw PlatformAdminCommandError(description: "User \(signature.email) was not found")
            }
            existing.isPlatformAdmin = false
            try await existing.save(on: db)
            context.application.logger.notice(
                "Revoked platform administrator",
                metadata: ["email": .string(signature.email), "subject": .string(signature.subject)]
            )
            context.console.print("Revoked platform administrator from \(signature.email)")
            return
        }

        if let existing {
            existing.firstName = signature.firstName
            existing.lastName = signature.lastName
            existing.authSubject = signature.subject
            existing.isPlatformAdmin = true
            try await existing.save(on: db)
        } else {
            let user = User(
                firstName: signature.firstName,
                lastName: signature.lastName,
                email: signature.email,
                authSubject: signature.subject,
                isPlatformAdmin: true
            )
            try await user.save(on: db)
        }
        context.application.logger.notice(
            "Granted platform administrator",
            metadata: ["email": .string(signature.email), "subject": .string(signature.subject)]
        )
        context.console.print("Granted platform administrator to \(signature.email)")
    }
}

struct PlatformAdminCommandError: Error, CustomStringConvertible {
    var description: String
}
