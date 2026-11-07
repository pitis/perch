import Foundation
import PerchCore

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct TaskGuess {
    @Guide(description: "How urgent the task sounds. Use none unless the wording clearly implies urgency.", .anyOf(["none", "low", "medium", "high"]))
    var priority: String

    @Guide(description: "One short project name such as Work, Home or Health. Reuse an existing project when one fits. Empty if unclear.")
    var project: String
}
#endif

/// A priority and project for new tasks, from Apple's on-device model on macOS 26 with Apple Intelligence on.
/// Everywhere else it does nothing, and tasks simply stay unclassified.
enum AutoClassifier {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static func classify(_ title: String, projects: [String]) async -> (priority: Priority?, project: String?) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let known = projects.isEmpty ? "none yet" : projects.joined(separator: ", ")
            let session = LanguageModelSession(instructions: "You sort to-do items for a personal planner. Existing projects: \(known).")
            do {
                let guess = try await session.respond(to: "To-do item: \(title)", generating: TaskGuess.self).content
                let project = guess.project.trimmingCharacters(in: .whitespacesAndNewlines)
                let priority = Priority(name: guess.priority)
                return (priority == .some(.none) ? nil : priority, project.isEmpty ? nil : project)
            } catch {
                return (nil, nil)
            }
        }
        #endif
        return (nil, nil)
    }
}
