#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity for an upcoming rocket launch: countdown on the Lock Screen and Dynamic Island.
nonisolated struct LaunchActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var net: Date
        var status: String
    }

    var mission: String
    var rocket: String
    var provider: String
    var location: String
}
#endif
