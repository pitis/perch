import Foundation

/// The Model Context Protocol over newline-delimited JSON-RPC. It only ever sees one line at a time, so the
/// socket that carries it stays elsewhere. Call on the main thread, since it reads and writes the Workspace.
public final class MCPServer {
    private let workspace: Workspace
    private let protocolVersion = "2025-06-18"

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public func handle(line: String) -> String? {
        guard let raw = line.data(using: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let request = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        // A message without an id is a notification and gets no reply.
        guard let id = request["id"] else { return nil }
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return reply(id, [
                "protocolVersion": requested ?? protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "perch", "version": "1.0"],
                "instructions": "Perch is the user's task, notes and focus workspace on this Mac. Titles passed to add_tasks understand natural language such as \"call mom tomorrow at 5pm #home !high\".",
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                return reply(id, toolResult(text: encode(try call(name, args)), isError: false))
            } catch {
                return reply(id, toolResult(text: (error as? ToolError)?.message ?? "\(error)", isError: true))
            }
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func toolResult(text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private struct ToolError: Error {
        let message: String
    }

    // MARK: Tools

    private func call(_ name: String, _ a: [String: Any]) throws -> Any {
        switch name {
        case "add_tasks":
            guard let titles = a["titles"] as? [String], !titles.isEmpty else { throw ToolError(message: "titles must be a non-empty array of strings") }
            let day = try optionalDay(a["day"], default: workspace.today)
            return titles.compactMap { workspace.add($0, defaultDay: day) }.map(describe)
        case "list_tasks":
            return try listTasks(a)
        case "update_task":
            return try updateTask(a)
        case "complete_task":
            let id = try taskId(a)
            workspace.setCompleted(id, (a["completed"] as? Bool) ?? true)
            return describe(workspace.task(id)!)
        case "delete_task":
            let id = try taskId(a)
            workspace.delete(id)
            return ["deleted": id.uuidString]
        case "set_reminder":
            let id = try taskId(a)
            guard let at = a["at"] as? String else { throw ToolError(message: "at is required") }
            let date = try reminderDate(at)
            workspace.update(id) { task in
                task.reminderAt = date
                task.day = Day.key(date, calendar: self.workspace.calendar)
            }
            return describe(workspace.task(id)!)
        case "read_note":
            let day = try requiredDay(a["day"])
            return ["day": day, "text": workspace.note(on: day)]
        case "write_note":
            guard let text = a["text"] as? String else { throw ToolError(message: "text is required") }
            let day = try requiredDay(a["day"])
            if (a["replace"] as? Bool) == true {
                workspace.setNote(text, on: day)
            } else {
                workspace.appendNote(text, on: day)
            }
            return ["day": day, "text": workspace.note(on: day)]
        case "get_insights":
            return describe(workspace.insights())
        case "focus_start":
            var id: UUID?
            if a["task_id"] != nil { id = try taskId(a, key: "task_id") }
            if let minutes = a["minutes"] as? Int, minutes <= 0 { throw ToolError(message: "minutes must be positive") }
            workspace.focusStart(taskId: id, minutes: a["minutes"] as? Int, stopwatch: (a["stopwatch"] as? Bool) ?? false)
            return focusStatus()
        case "focus_pause":
            workspace.focusPause()
            return focusStatus()
        case "focus_resume":
            workspace.focusResume()
            return focusStatus()
        case "focus_add_five":
            workspace.focusAddFive()
            return focusStatus()
        case "focus_stop":
            workspace.focusStop()
            return focusStatus()
        case "focus_status":
            return focusStatus()
        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    private func listTasks(_ a: [String: Any]) throws -> Any {
        let which = (a["list"] as? String)?.lowercased() ?? "today"
        switch which {
        case "inbox": return workspace.inbox.map(describe)
        case "overdue": return workspace.overdue.map(describe)
        case "upcoming":
            let today = workspace.today
            return workspace.data.tasks
                .filter { !$0.isCompleted && ($0.day.map { $0 >= today } ?? false) }
                .sorted { ($0.day ?? "", $0.order) < ($1.day ?? "", $1.order) }
                .map(describe)
        case "completed":
            return workspace.completed(on: try requiredDay(a["day"])).map(describe)
        default:
            return workspace.open(on: try requiredDay(which)).map(describe)
        }
    }

    private func updateTask(_ a: [String: Any]) throws -> Any {
        let id = try taskId(a)
        guard let current = workspace.task(id) else { throw ToolError(message: "No task with that id") }

        // Validate everything first so a bad field can't leave the task half-updated.
        var priority: Priority?
        if let name = a["priority"] as? String {
            guard let parsed = Priority(name: name) else { throw ToolError(message: "priority must be none, low, medium or high") }
            priority = parsed
        }
        let targetDay: String?? = a["day"] != nil ? .some(try optionalDay(a["day"], default: nil)) : nil
        var deadline: String??
        if let raw = a["deadline"] {
            if raw is NSNull || (raw as? String)?.isEmpty == true { deadline = .some(nil) } else { deadline = .some(try requiredDay(raw)) }
        }
        var repeatRule: RepeatRule??
        if let raw = a["repeat"] {
            if raw is NSNull || (raw as? String)?.isEmpty == true {
                repeatRule = .some(nil)
            } else {
                guard let text = raw as? String, let rule = NLParser.parse("x " + text, now: workspace.now, calendar: workspace.calendar).repeatRule else {
                    throw ToolError(message: "repeat must be a phrase such as \"every weekday\" or \"every 2 weeks\", or null to clear it")
                }
                repeatRule = .some(rule)
            }
        }

        if let targetDay, targetDay != current.day { workspace.move(id, to: targetDay) }
        workspace.update(id) { task in
            if let title = a["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty { task.title = title }
            if let notes = a["notes"] as? String { task.notes = notes }
            if let priority { task.priority = priority }
            if let project = a["project"] as? String { task.project = project.isEmpty ? nil : project }
            if let minutes = a["planned_minutes"] as? Int, minutes > 0 { task.plannedMinutes = minutes }
            if let deadline { task.deadline = deadline }
            if let repeatRule { task.repeatRule = repeatRule }
            if let steps = a["steps"] as? [String] {
                task.steps = steps.map { title in
                    task.steps.first { $0.title == title } ?? Step(title: title)
                }
            }
        }
        return describe(workspace.task(id)!)
    }

    private func taskId(_ a: [String: Any], key: String = "id") throws -> UUID {
        guard let raw = a[key] as? String, let id = UUID(uuidString: raw) else { throw ToolError(message: "\(key) must be a task id from list_tasks") }
        guard workspace.task(id) != nil else { throw ToolError(message: "No task with id \(raw)") }
        return id
    }

    /// "today", "tomorrow", "friday", "2026-12-24" and so on. A missing value means today.
    private func requiredDay(_ raw: Any?) throws -> String {
        guard let text = raw as? String, !text.isEmpty else { return workspace.today }
        if Day.isValid(text) { return text }
        guard let day = NLParser.parse("x " + text, now: workspace.now, calendar: workspace.calendar).day else {
            throw ToolError(message: "Couldn't read \"\(text)\" as a day. Use today, tomorrow, a weekday or YYYY-MM-DD.")
        }
        return day
    }

    /// Like `requiredDay`, but "inbox" or null means no day at all.
    private func optionalDay(_ raw: Any?, default fallback: String?) throws -> String? {
        if raw == nil { return fallback }
        if raw is NSNull { return nil }
        if let text = raw as? String, text.lowercased() == "inbox" || text.isEmpty { return nil }
        return try requiredDay(raw)
    }

    private func reminderDate(_ text: String) throws -> Date {
        if let exact = ISO8601DateFormatter().date(from: text) { return exact }
        guard let parsed = NLParser.parse("x " + text, now: workspace.now, calendar: workspace.calendar).reminderAt else {
            throw ToolError(message: "Couldn't read \"\(text)\" as a time. Try \"tomorrow at 5pm\" or an ISO 8601 date.")
        }
        return parsed
    }

    // MARK: Output

    private func describe(_ task: TaskItem) -> [String: Any] {
        var out: [String: Any] = [
            "id": task.id.uuidString,
            "title": task.title,
            "completed": task.isCompleted,
            "priority": task.priority.label.lowercased(),
            "day": task.day ?? "inbox",
        ]
        if !task.notes.isEmpty { out["notes"] = task.notes }
        if let at = task.reminderAt { out["reminder"] = localISO(at) }
        if let deadline = task.deadline { out["deadline"] = deadline }
        if let project = task.project { out["project"] = project }
        if let rule = task.repeatRule { out["repeat"] = rule.label }
        if let minutes = task.plannedMinutes { out["planned_minutes"] = minutes }
        if task.focusedSeconds > 0 { out["focused_minutes"] = task.focusedSeconds / 60 }
        if !task.steps.isEmpty { out["steps"] = task.steps.map { ["title": $0.title, "done": $0.done] as [String: Any] } }
        return out
    }

    private func describe(_ s: InsightsSummary) -> [String: Any] {
        var out: [String: Any] = [
            "headline": s.headline,
            "summary": s.sentence,
            "completed_last_7_days": s.completed,
            "completed_previous_7_days": s.previousCompleted,
            "planned_last_7_days": s.planned,
            "focus_minutes_last_7_days": s.focusSeconds / 60,
            "active_days": s.activeDays,
            "days": s.days.map { ["day": $0.day, "completed": $0.completed, "planned": $0.planned, "focus_minutes": $0.focusSeconds / 60] as [String: Any] },
        ]
        if let peak = s.peakHour { out["peak_hour_24h"] = peak }
        return out
    }

    private func focusStatus() -> [String: Any] {
        let f = workspace.data.focus
        let now = workspace.now
        var out: [String: Any] = [
            "state": f.phase.rawValue,
            "mode": f.mode.rawValue,
            "elapsed_seconds": Int(f.elapsed(at: now)),
        ]
        if f.mode == .countdown { out["remaining_seconds"] = Int(f.remaining(at: now)) }
        if let id = f.taskId, let task = workspace.task(id) { out["task"] = ["id": id.uuidString, "title": task.title] }
        return out
    }

    private func localISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = workspace.calendar.timeZone
        return f.string(from: date)
    }

    // MARK: Tool definitions

    private static func schema(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static let stringProp: [String: Any] = ["type": "string"]
    private static let idProp: [String: Any] = ["type": "string", "description": "Task id from list_tasks"]
    private static let dayProp: [String: Any] = ["type": "string", "description": "today, tomorrow, a weekday, or YYYY-MM-DD. Defaults to today."]

    private static func tool(_ name: String, _ description: String, _ input: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": input]
    }

    static let tools: [[String: Any]] = [
        tool("add_tasks", "Add one or more tasks. Each title understands natural language: \"call mom tomorrow at 5pm\", \"standup every weekday at 9:30 #work\", \"pay rent by friday !high\".",
             schema(["titles": ["type": "array", "items": stringProp], "day": ["type": "string", "description": "Default day when a title doesn't name one: today, tomorrow, a weekday, YYYY-MM-DD, or inbox. Defaults to today."]], required: ["titles"])),
        tool("list_tasks", "List tasks. list is today (default), tomorrow, a weekday, YYYY-MM-DD, inbox, overdue, upcoming or completed. For completed, day picks the date.",
             schema(["list": stringProp, "day": dayProp])),
        tool("update_task", "Change a task's fields. Only the fields you pass change.",
             schema([
                 "id": idProp, "title": stringProp, "notes": stringProp,
                 "day": ["type": ["string", "null"], "description": "New day, or inbox or null for the Inbox."],
                 "priority": ["type": "string", "enum": ["none", "low", "medium", "high"]],
                 "project": ["type": "string", "description": "Project name, or empty to clear."],
                 "deadline": ["type": ["string", "null"], "description": "Deadline day, or null to clear."],
                 "repeat": ["type": ["string", "null"], "description": "\"every weekday\", \"every 2 weeks\", \"every monday and thursday\", or null to clear."],
                 "planned_minutes": ["type": "integer", "description": "Focus length for this task."],
                 "steps": ["type": "array", "items": stringProp, "description": "Replaces the step list. Steps with the same title keep their done state."],
             ], required: ["id"])),
        tool("complete_task", "Mark a task done, or not done with completed: false. Finishing a repeating task creates its next occurrence.",
             schema(["id": idProp, "completed": ["type": "boolean"]], required: ["id"])),
        tool("delete_task", "Delete a task.", schema(["id": idProp], required: ["id"])),
        tool("set_reminder", "Set when a task rings in the notch. at is natural language (\"tomorrow at 5pm\", \"in 30 minutes\") or ISO 8601.",
             schema(["id": idProp, "at": stringProp], required: ["id", "at"])),
        tool("read_note", "Read the Notepad for a day.", schema(["day": dayProp])),
        tool("write_note", "Add text to the Notepad for a day. Pass replace: true to overwrite the whole note.",
             schema(["text": stringProp, "day": dayProp, "replace": ["type": "boolean"]], required: ["text"])),
        tool("get_insights", "Summary of the last 7 days: tasks completed vs planned, active focus time, active days and peak focus hour.", schema()),
        tool("focus_start", "Start a focus timer, replacing any current one. Countdown by default; pass stopwatch: true for no time limit.",
             schema(["task_id": idProp, "minutes": ["type": "integer"], "stopwatch": ["type": "boolean"]])),
        tool("focus_pause", "Pause the focus timer.", schema()),
        tool("focus_resume", "Resume a paused focus timer.", schema()),
        tool("focus_add_five", "Add five minutes to the countdown.", schema()),
        tool("focus_stop", "Stop the focus timer and log the active time.", schema()),
        tool("focus_status", "Read the focus timer's state.", schema()),
    ]
}
