import Foundation

/// Count, mean, median and peak context percentage over a set of model requests. Every request weighs the same, so
/// nothing is time-weighted. A request with unknown occupancy counts as a request but never as a measurement.
public struct ContextStatistics: Equatable, Sendable {
    public let requests: Int
    /// Requests that carried a context percentage; mean, median and peak are over these alone.
    public let measured: Int
    public let mean: Double?
    /// The middle measurement, or the mean of the two middle ones for an even count.
    public let median: Double?
    public let peak: Double?

    /// One context percentage per model request, nil where its occupancy was unknown.
    public init(_ percentages: some Collection<Double?>) {
        let values = percentages.compactMap { $0 }.sorted()
        requests = percentages.count
        measured = values.count
        guard let peak = values.last else {
            (mean, median, self.peak) = (nil, nil, nil)
            return
        }
        let middle = values.count / 2
        mean = values.reduce(0, +) / Double(values.count)
        median = values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        self.peak = peak
    }
}

/// The Insights statistics: per session generation, per profile and overall, with generations grouped under their
/// routing lane for navigation.
public struct InsightsReport: Equatable, Sendable {
    public struct ProfileStatistics: Equatable, Sendable, Identifiable {
        public let profile: String
        public let statistics: ContextStatistics
        public var id: String { profile }
    }

    public struct GenerationStatistics: Equatable, Sendable, Identifiable {
        public let generation: Generation
        public let statistics: ContextStatistics
        public var id: String { generation.sessionID }
    }

    public struct Lane: Equatable, Sendable, Identifiable {
        public let routingID: String
        public let profile: String
        /// Oldest first.
        public let generations: [GenerationStatistics]
        public var id: String { routingID }
    }

    /// One model request as the statistics see it: where it ran and its context percentage.
    struct Request {
        let profile: String
        let generation: GenerationKey
        let percentage: Double?
    }

    struct GenerationKey: Hashable {
        let routingID: String
        let sessionID: String
    }

    public let overall: ContextStatistics
    /// By profile name.
    public let profiles: [ProfileStatistics]
    /// Most recent activity first, as `TelemetryStore.lineages()` orders them.
    public let lanes: [Lane]
    public let toolCalls: Int

    init(requests: [Request], lineages: [Lineage], toolCalls: Int) {
        overall = ContextStatistics(requests.map(\.percentage))
        profiles = Dictionary(grouping: requests, by: \.profile)
            .map { ProfileStatistics(profile: $0.key, statistics: ContextStatistics($0.value.map(\.percentage))) }
            .sorted { $0.profile < $1.profile }
        let byGeneration = Dictionary(grouping: requests, by: \.generation).mapValues { $0.map(\.percentage) }
        lanes = lineages.map { lineage in
            Lane(routingID: lineage.routingID, profile: lineage.profile, generations: lineage.generations.map {
                let key = GenerationKey(routingID: lineage.routingID, sessionID: $0.sessionID)
                return GenerationStatistics(generation: $0, statistics: ContextStatistics(byGeneration[key] ?? []))
            })
        }
        self.toolCalls = toolCalls
    }
}
