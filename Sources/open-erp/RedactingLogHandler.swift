import Logging

/// Query logs carry bound values, which include token hashes and personal data: PostgresKit logs them as `binds`,
/// and FluentKit logs written values as `input` and compared values in `filters`.
/// PostgresNIO protocol diagnostics may also include row data, binds, or failed-row details.
/// Drop those payloads at every level so query logging stays safe to enable.
struct RedactingLogHandler: LogHandler {
    static let redactedKeys: Set<String> = [
        "binds", "input", "filters",
        "psql_binds", "psql_error", "psql_notice", "psql_message", "psql_message_payload",
        "psql_connection_action", "psql_user_event",
    ]

    var base: any LogHandler

    var metadata: Logger.Metadata {
        get { base.metadata }
        set { base.metadata = newValue }
    }

    var metadataProvider: Logger.MetadataProvider? {
        get { base.metadataProvider }
        set { base.metadataProvider = newValue }
    }

    var logLevel: Logger.Level {
        get { base.logLevel }
        set { base.logLevel = newValue }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { base[metadataKey: key] }
        set { base[metadataKey: key] = newValue }
    }

    func log(event: LogEvent) {
        var event = event
        for key in Self.redactedKeys where event.metadata?[key] != nil {
            event.metadata?[key] = "[redacted]"
        }
        base.log(event: event)
    }
}
