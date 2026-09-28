import Foundation

/// The Discord location a lane lives in. A thread is itself a Discord channel, so the link targets the
/// thread when there is one and the channel otherwise; `@me` stands in for a missing guild (a DM).
public struct DiscordDestination: Equatable, Sendable {
    public let guildID: String?
    public let channelID: String
    public let threadID: String?

    /// Only a Discord lane with a route-safe channel gets a destination. IDs are Discord snowflakes;
    /// anything outside `[A-Za-z0-9_-]` could escape the URL path, so it gets no link at all.
    public init?(session: LiveSession) {
        guard session.platform == "discord", let channelID = session.route.channelID else { return nil }
        let ids = [session.route.guildID, channelID, session.route.threadID].compactMap { $0 }
        guard ids.allSatisfy(Self.isRouteSafe) else { return nil }
        self.guildID = session.route.guildID
        self.channelID = channelID
        self.threadID = session.route.threadID
    }

    /// `/channels/<guild>/<thread or channel>`: Discord's own Copy Link shape.
    public var path: String { "/channels/\(guildID ?? "@me")/\(threadID ?? channelID)" }

    /// Opens in the browser; the fallback when no app claims `discord:`.
    public var webURL: URL { URL(string: "https://discord.com\(path)")! }

    /// Opens the same location in the Discord desktop app.
    public var appURL: URL { URL(string: "discord://-\(path)")! }

    static func isRouteSafe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-" }
    }
}

/// What the details pane shows for one lane: the approved live fields, then generation identity for
/// diagnostics. Built only from `LiveSession`, which never carries messages, tool arguments or results.
public struct SessionDetails: Equatable, Sendable {
    public struct Field: Equatable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    public let title: String
    public let isOffline: Bool
    public let fields: [Field]
    public let diagnostics: [Field]
    public let discord: DiscordDestination?

    public init(session: LiveSession, isOffline: Bool, now: Date) {
        title = session.displayName
        self.isOffline = isOffline
        discord = DiscordDestination(session: session)

        var fields = [
            Field(label: "Profile", value: session.profileLabel),
            Field(label: "State", value: isOffline ? "\(session.state.label) (last known, gateway offline)" : session.state.label),
            Field(label: "Context", value: Self.context(session.context, now: now)),
            Field(label: "Model", value: [session.model, session.provider].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Unknown"),
        ]
        // A tool name is live-only: shown while its turn runs, never kept for an idle lane.
        if session.state == .working, let tool = session.currentTool {
            fields.append(Field(label: "Current tool", value: tool))
        }
        if let started = session.turnStartedAt, session.state != .idle {
            fields.append(Field(label: "Turn started", value: LiveSession.elapsed(since: started, now: now)))
        }
        fields.append(Field(label: "Last activity", value: session.lastActivityAt.map { LiveSession.elapsed(since: $0, now: now) } ?? "Unknown"))
        fields.append(Field(label: "Discord", value: Self.location(session)))
        self.fields = fields

        diagnostics = [
            Field(label: "Session", value: session.sessionID),
            Field(label: "Previous session", value: session.previousSessionID ?? "None"),
            Field(label: "Lineage root", value: session.lineageRootID),
            Field(label: "Routing", value: session.id),
        ]
    }

    static func context(_ context: ContextOccupancy, now: Date) -> String {
        var parts = [context.percentText, context.tokensText.map { "\($0) tokens" }].compactMap { $0 }
        guard !parts.isEmpty else { return "No measurement yet" }
        if context.isEstimated { parts.append("estimated") }
        if let measured = context.measuredAt { parts.append("measured \(LiveSession.elapsed(since: measured, now: now))") }
        return parts.joined(separator: " · ")
    }

    static func location(_ session: LiveSession) -> String {
        let channel = session.route.channelLabel ?? "Unknown channel"
        return session.route.threadID == nil ? channel : "Thread in \(channel)"
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
