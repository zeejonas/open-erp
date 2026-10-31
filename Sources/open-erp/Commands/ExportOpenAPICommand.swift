import Foundation
import Vapor

struct ExportOpenAPICommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "path", help: "Destination JSON file; its parent directory must exist.")
        var path: String
    }

    var help: String { "Export the route-derived OpenAPI document without runtime services." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(apiDocument(context.application))
        try data.write(to: URL(fileURLWithPath: signature.path), options: .atomic)
    }
}
