import Foundation
import PerchCore

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct TaskGuess {
    @Guide(description: "The to-do itself, copied in the user's own words and language, without the words that say when.")
    var title: String

    @Guide(description: "When the to-do is due, repeats or should remind, rewritten in plain English such as 'tomorrow at 5pm', 'friday morning', 'every monday', 'by december 3' or 'in 2 hours'. Use month names, never numeric dates. Empty if the to-do doesn't say when.")
    var when: String

    @Guide(description: "How urgent the task sounds. Use none unless the wording clearly implies urgency.", .anyOf(["none", "low", "medium", "high"]))
    var priority: String

    @Guide(description: "One short project name such as Work, Home or Health. Reuse an existing project when one fits. Empty if unclear.")
    var project: String
}
#endif

/// A priority, a project, and the title split into its to-do and an English date phrase for `NLParser`, from Apple's
/// on-device model on macOS 26 with Apple Intelligence on. The model reads any language it supports. Everywhere else,
/// or when the model fails, `classify` returns nil and tasks simply stay as they were added.
enum AutoClassifier {
    struct Guess {
        var priority: Priority?
        var project: String?
        /// The text without its date, in its own language.
        var title: String
        /// The text's date in English for `NLParser`, empty when it has none.
        var when: String
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static func classify(_ text: String, projects: [String]) async -> Guess? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let known = projects.isEmpty ? "none yet" : projects.joined(separator: ", ")
            let session = LanguageModelSession(instructions: "You sort to-do items for a personal planner. Existing projects: \(known).")
            do {
                let guess = try await session.respond(to: "To-do item: \(text)", generating: TaskGuess.self).content
                let project = guess.project.trimmingCharacters(in: .whitespacesAndNewlines)
                let priority = Priority(name: guess.priority)
                return Guess(priority: priority == .some(.none) ? nil : priority, project: project.isEmpty ? nil : project, title: guess.title, when: guess.when)
            } catch {
                NSLog("Perch: Apple Intelligence couldn't read a task: %@", "\(error)")
                return nil
            }
        }
        #endif
        return nil
    }
}
