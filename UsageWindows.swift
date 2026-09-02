import Foundation

struct UsageWindow: Codable, Hashable {
    var usedPercent: Int
    var resetsAt: Date?
    var durationMinutes: Int?

    func current(at date: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= date else { return self }
        return UsageWindow(usedPercent: 0, resetsAt: nil, durationMinutes: durationMinutes)
    }

    var currentValue: UsageWindow { current(at: Date()) }
}

struct ClassifiedUsageWindows: Equatable {
    var short: UsageWindow?
    var weekly: UsageWindow?
}

enum UsageWindowClassifier {
    private static let dailyBoundaryMinutes = 24 * 60

    static func classify(primary: UsageWindow?, secondary: UsageWindow?) -> ClassifiedUsageWindows {
        let positioned = [(window: primary, isPrimary: true), (window: secondary, isPrimary: false)]
        let known = positioned.compactMap { item -> (window: UsageWindow, isPrimary: Bool)? in
            guard let window = item.window, window.durationMinutes != nil else { return nil }
            return (window, item.isPrimary)
        }

        // Codex field names describe position, not duration. Pro Lite, for example,
        // can expose its weekly window as `primary` with no `secondary` window.
        if !known.isEmpty {
            var short = known
                .filter { ($0.window.durationMinutes ?? dailyBoundaryMinutes) < dailyBoundaryMinutes }
                .min { distance($0.window.durationMinutes, from: 300) < distance($1.window.durationMinutes, from: 300) }?
                .window
            var weekly = known
                .filter { ($0.window.durationMinutes ?? 0) >= dailyBoundaryMinutes }
                .min { distance($0.window.durationMinutes, from: 10_080) < distance($1.window.durationMinutes, from: 10_080) }?
                .window

            let unknown = positioned.compactMap { item -> (window: UsageWindow, isPrimary: Bool)? in
                guard let window = item.window, window.durationMinutes == nil else { return nil }
                return (window, item.isPrimary)
            }
            for item in unknown {
                if item.isPrimary, short == nil { short = item.window }
                else if !item.isPrimary, weekly == nil { weekly = item.window }
                else if short == nil { short = item.window }
                else if weekly == nil { weekly = item.window }
            }
            return ClassifiedUsageWindows(short: short, weekly: weekly)
        }

        // Older Codex builds omitted duration metadata, so retain their positional contract.
        return ClassifiedUsageWindows(short: primary, weekly: secondary)
    }

    static func classify(discovered windows: [UsageWindow]) -> ClassifiedUsageWindows {
        let short = windows
            .filter { ($0.durationMinutes ?? dailyBoundaryMinutes) < dailyBoundaryMinutes }
            .min { distance($0.durationMinutes, from: 300) < distance($1.durationMinutes, from: 300) }
        let weekly = windows
            .filter { ($0.durationMinutes ?? 0) >= dailyBoundaryMinutes }
            .min { distance($0.durationMinutes, from: 10_080) < distance($1.durationMinutes, from: 10_080) }
        return ClassifiedUsageWindows(short: short, weekly: weekly)
    }

    private static func distance(_ value: Int?, from target: Int) -> Int {
        abs((value ?? target) - target)
    }
}
