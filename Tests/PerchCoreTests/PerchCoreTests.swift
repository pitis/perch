import XCTest
@testable import PerchCore

private var utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
    c.firstWeekday = 2
    return c
}()

/// Saturday 7 Nov 2026, 10:00 local.
private let saturday = Day.at("2026-11-07", hour: 10, minute: 0, calendar: utc)

private func parse(_ text: String, at now: Date = saturday, locale: String = "en_US") -> ParsedTask {
    NLParser.parse(text, now: now, calendar: utc, locale: Locale(identifier: locale))
}

private func clock(_ date: Date?) -> String {
    guard let date else { return "nil" }
    let c = utc.dateComponents([.hour, .minute], from: date)
    return String(format: "%@ %02d:%02d", Day.key(date, calendar: utc), c.hour!, c.minute!)
}

private func makeWorkspace(at now: Date = saturday) -> (Workspace, (TimeInterval) -> Void) {
    let w = Workspace()
    w.calendar = utc
    var current = now
    w.clock = { current }
    return (w, { current = current.addingTimeInterval($0) })
}

final class NLParserTests: XCTestCase {
    func testSiteExample() {
        let p = parse("call mom tomorrow at 5pm")
        XCTAssertEqual(p.title, "Call mom")
        XCTAssertEqual(p.day, "2026-11-08")
        XCTAssertEqual(clock(p.reminderAt), "2026-11-08 17:00")
        XCTAssertEqual(p.whenLabel(today: "2026-11-07", calendar: utc, locale: Locale(identifier: "en_US_POSIX"))?.replacingOccurrences(of: "\u{202F}", with: " "), "Tomorrow, 5:00 PM")
    }

    func testPlainTitlesAreLeftAlone() {
        for text in ["Read 20 pages", "Gym after work", "sat with mom", "buy sun cream", "morning run", "Meet at 5th avenue", "pay 10.50 to bob", "may the fourth"] {
            let p = parse(text)
            XCTAssertNil(p.day, text)
            XCTAssertNil(p.reminderAt, text)
            XCTAssertEqual(p.title.lowercased(), text.lowercased(), text)
        }
    }

    func testTimes() {
        XCTAssertEqual(clock(parse("x at 5:30 PM").reminderAt), "2026-11-07 17:30")
        XCTAssertEqual(clock(parse("x 9am").reminderAt), "2026-11-08 09:00", "already past today, so tomorrow")
        XCTAssertEqual(clock(parse("x at 17:45").reminderAt), "2026-11-07 17:45")
        XCTAssertEqual(clock(parse("x at 5").reminderAt), "2026-11-07 17:00", "5am is gone, 5pm is next")
        XCTAssertEqual(clock(parse("x tomorrow at 5").reminderAt), "2026-11-08 17:00")
        XCTAssertEqual(clock(parse("x at noon").reminderAt), "2026-11-07 12:00")
        XCTAssertEqual(clock(parse("x in 30 minutes").reminderAt), "2026-11-07 10:30")
        XCTAssertEqual(clock(parse("x in 2 hours").reminderAt), "2026-11-07 12:00")
        XCTAssertEqual(clock(parse("x tomorrow morning").reminderAt), "2026-11-08 09:00")
        XCTAssertEqual(clock(parse("x tonight").reminderAt), "2026-11-07 20:00")
        XCTAssertEqual(clock(parse("x at five pm").reminderAt), "2026-11-07 17:00")
        XCTAssertEqual(clock(parse("Call mom tomorrow at 5 p.m.").reminderAt), "2026-11-08 17:00")
    }

    func testDays() {
        XCTAssertEqual(parse("x today").day, "2026-11-07")
        XCTAssertEqual(parse("x monday").day, "2026-11-09")
        XCTAssertEqual(parse("x on fri").day, "2026-11-13")
        XCTAssertEqual(parse("x saturday").day, "2026-11-07", "a bare weekday can mean today")
        XCTAssertEqual(parse("x next week").day, "2026-11-09")
        XCTAssertEqual(parse("x in 3 days").day, "2026-11-10")
        XCTAssertEqual(parse("x dec 24").day, "2026-12-24")
        XCTAssertEqual(parse("x 12th of october").day, "2027-10-12", "already past this year")
        XCTAssertEqual(parse("x day after tomorrow").day, "2026-11-09")
    }

    func testRepeatPriorityProjectDeadline() {
        let standup = parse("standup every weekday at 9:30am !high #work")
        XCTAssertEqual(standup.title, "Standup")
        XCTAssertEqual(standup.repeatRule, RepeatRule(kind: .weekdays))
        XCTAssertEqual(standup.priority, .high)
        XCTAssertEqual(standup.project, "Work")
        XCTAssertEqual(clock(standup.reminderAt), "2026-11-09 09:30", "first weekday from a Saturday")

        XCTAssertEqual(parse("gym every monday and thursday").repeatRule?.weekdays, [2, 5])
        XCTAssertEqual(parse("gym every monday and thursday").day, "2026-11-09")
        XCTAssertEqual(parse("x every 2 weeks").repeatRule, RepeatRule(kind: .weekly, interval: 2))
        XCTAssertEqual(parse("pay rent by friday").deadline, "2026-11-13")
        XCTAssertEqual(parse("pay rent by friday").title, "Pay rent")
        XCTAssertNil(parse("pay rent by friday").day)
        XCTAssertEqual(parse("Plan trip p2").priority, .medium)
    }

    func testNumericDatesFollowTheLocalesOrder() {
        XCTAssertEqual(parse("x 12/25").day, "2026-12-25")
        XCTAssertEqual(parse("x 12/25").title, "X")
        XCTAssertEqual(parse("x 3/4").day, "2027-03-04", "already past this year")
        XCTAssertEqual(parse("x 12/25/27").day, "2027-12-25")
        XCTAssertEqual(parse("x 25/12", locale: "en_GB").day, "2026-12-25")
        XCTAssertEqual(parse("x 3/4", locale: "en_GB").day, "2027-04-03")
        XCTAssertEqual(parse("x 25.12.2026", locale: "ro_RO").day, "2026-12-25")
        XCTAssertEqual(parse("x 25.12.", locale: "de_DE").title, "X")
        XCTAssertEqual(parse("x 25/12 at 9:30", locale: "ro_RO").reminderAt.map(clock), "2026-12-25 09:30")
        XCTAssertEqual(parse("pay rent by 30/11", locale: "en_GB").deadline, "2026-11-30")
        XCTAssertEqual(parse("pay rent by 30/11", locale: "en_GB").title, "Pay rent")
        XCTAssertEqual(parse("pay rent by 25.12", locale: "de_DE").deadline, "2026-12-25")
        XCTAssertNil(parse("x 31/11", locale: "en_GB").day, "November has 30 days")
        XCTAssertNil(parse("x february 30").day)
        for (text, locale) in [("x 25/12", "en_US"), ("x 12.25", "en_US"), ("pay 10.50 to bob", "ro_RO"), ("update to 1.2.3", "de_DE"), ("room 12/40", "en_US"),
                               ("update to macOS 26.1", "ro_RO"), ("buy 2.5 kg flour", "en_US@rg=atzzzz"), ("read chapter 3.2", "de_DE")] {
            XCTAssertNil(parse(text, locale: locale).day, text)
            XCTAssertEqual(parse(text, locale: locale).title.lowercased(), text.lowercased(), text)
        }
    }

    func testRomanian() {
        let call = parse("sună-o pe mama mâine la 5")
        XCTAssertEqual(call.title, "Sună-o pe mama")
        XCTAssertEqual(clock(call.reminderAt), "2026-11-08 17:00")
        XCTAssertEqual(parse("plătește chiria până vineri").deadline, "2026-11-13")
        XCTAssertEqual(parse("plătește chiria până vineri").title, "Plătește chiria")
        let gym = parse("sală în fiecare luni și joi la 7 seara")
        XCTAssertEqual(gym.title, "Sală")
        XCTAssertEqual(gym.repeatRule?.weekdays, [2, 5])
        XCTAssertEqual(clock(gym.reminderAt), "2026-11-09 19:00")
        XCTAssertEqual(parse("raport poimâine").day, "2026-11-09")
        let meeting = parse("întâlnire pe 3 decembrie la ora 14:30")
        XCTAssertEqual(meeting.title, "Întâlnire")
        XCTAssertEqual(clock(meeting.reminderAt), "2026-12-03 14:30")
        XCTAssertEqual(clock(parse("verifică mailul în 30 de minute").reminderAt), "2026-11-07 10:30")
        XCTAssertEqual(clock(parse("sună la service peste două ore").reminderAt), "2026-11-07 12:00")
        XCTAssertEqual(parse("vacanță peste 3 luni").day, "2027-02-07")
        XCTAssertEqual(clock(parse("film diseară").reminderAt), "2026-11-07 20:00")
        XCTAssertEqual(parse("curățenie sâmbăta viitoare").day, "2026-11-14")
        XCTAssertEqual(parse("x în fiecare zi").repeatRule, RepeatRule(kind: .daily))
        XCTAssertEqual(parse("x azi").day, "2026-11-07")
        XCTAssertEqual(parse("x pe 25.12", locale: "ro_RO").title, "X")
        XCTAssertEqual(parse("factura până la 3 decembrie").deadline, "2026-12-03")
        let plain = parse("suna-l pe Ion maine dimineata")
        XCTAssertEqual(plain.title, "Suna-l pe Ion", "diacritics are optional")
        XCTAssertEqual(clock(plain.reminderAt), "2026-11-08 09:00")
        XCTAssertEqual(clock(parse("film la 7.30 seara").reminderAt), "2026-11-07 19:30")
        for text in ["du-te la magazin", "cumpără lapte", "mai multe ouă", "lunar eclipse photos", "pune pe 2 farfurii", "bilete LA 2028",
                     "plan pentru următoarele luni", "abonament pe două luni", "de luni de zile nu am sunat", "trimite email la 3 colegi",
                     "rezervare la 7 persoane", "programează controlul anual", "sună la bancă luni și joi", "plătește factura până pe 25.12"] {
            XCTAssertNil(parse(text).day, text)
            XCTAssertEqual(parse(text).title.lowercased(), text.lowercased(), text)
        }
    }

    func testEnglishNamesAreNotRomanian() {
        for text in ["Drive to Maine", "email Joi about the deck"] {
            XCTAssertNil(parse(text).day, text)
            XCTAssertEqual(parse(text).title.lowercased(), text.lowercased(), text)
        }
        XCTAssertEqual(parse("lunch with Azi tomorrow").title, "Lunch with Azi")
        XCTAssertEqual(parse("flight to LA 9:30").title, "Flight to LA")
        XCTAssertEqual(parse("gym PE monday").title, "Gym PE")
    }

    func testAllDetailsAndNoTitleKeepsSomethingToShow() {
        XCTAssertEqual(parse("tomorrow").title, "Tomorrow")
    }
}

final class RepeatTests: XCTestCase {
    func testNextOccurrences() {
        let today = "2026-11-07"
        XCTAssertEqual(RepeatRule(kind: .daily).next(from: today, today: today, calendar: utc), "2026-11-08")
        XCTAssertEqual(RepeatRule(kind: .weekdays).next(from: "2026-11-06", today: "2026-11-06", calendar: utc), "2026-11-09", "Friday skips the weekend")
        XCTAssertEqual(RepeatRule(kind: .weekly, weekdays: [2, 5]).next(from: "2026-11-09", today: "2026-11-09", calendar: utc), "2026-11-12")
        XCTAssertEqual(RepeatRule(kind: .daily).next(from: "2026-11-01", today: today, calendar: utc), "2026-11-08", "overdue jumps past today")
        XCTAssertEqual(RepeatRule(kind: .monthly).next(from: "2026-01-31", today: "2026-01-31", calendar: utc), "2026-02-28")
        XCTAssertEqual(RepeatRule(kind: .monthly).next(from: "2026-01-31", today: "2026-02-28", calendar: utc), "2026-03-31", "the 31st doesn't drift")
    }
}

final class WorkspaceTests: XCTestCase {
    func testAnotherReadingOfThePhraseSchedulesIt() {
        let (w, _) = makeWorkspace()
        let dentist = w.add("Zahnarzt am Dienstag um 14 Uhr", defaultDay: nil)!
        XCTAssertNil(dentist.day, "the parser doesn't read German")
        w.applySchedule(dentist.id, title: "zahnarzt", when: "tuesday at 2pm", ifUnchangedSince: dentist)
        XCTAssertEqual(w.task(dentist.id)?.title, "Zahnarzt")
        XCTAssertEqual(w.task(dentist.id)?.day, "2026-11-10")
        XCTAssertEqual(clock(w.task(dentist.id)?.reminderAt), "2026-11-10 14:00")

        let rent = w.add("Miete zahlen bis Freitag", defaultDay: w.today)!
        w.applySchedule(rent.id, title: "Miete zahlen", when: "by friday", ifUnchangedSince: rent)
        XCTAssertEqual(w.task(rent.id)?.deadline, "2026-11-13")
        XCTAssertEqual(w.task(rent.id)?.day, w.today, "a deadline keeps the day it was added to")

        let edited = w.add("Steuer machen am Montag", defaultDay: nil)!
        w.update(edited.id) { $0.title = "Steuer" }
        w.applySchedule(edited.id, title: "Steuer machen", when: "monday", ifUnchangedSince: edited)
        XCTAssertNil(w.task(edited.id)?.day, "an edit made meanwhile wins")

        let milk = w.add("Milch kaufen", defaultDay: nil)!
        w.applySchedule(milk.id, title: "Milch", when: "", ifUnchangedSince: milk)
        XCTAssertEqual(w.task(milk.id)?.title, "Milch kaufen", "nothing changes without a date")
        w.applySchedule(milk.id, title: "Milch kaufen", when: "today", ifUnchangedSince: milk)
        XCTAssertNil(w.task(milk.id)?.day, "a date that took no words from the text was made up")

        let doctor = w.add("Arzt anrufen morgen um 14 Uhr", defaultDay: nil)!
        w.applySchedule(doctor.id, title: "Call doctor", when: "tomorrow at 2pm", ifUnchangedSince: doctor)
        XCTAssertEqual(w.task(doctor.id)?.title, "Arzt anrufen morgen um 14 Uhr", "a translation isn't the user's own words")
        XCTAssertNil(w.task(doctor.id)?.day)

        let jog = w.add("Joggen jeden Montag", defaultDay: nil)!
        w.setCompleted(jog.id, true)
        w.applySchedule(jog.id, title: "Joggen", when: "every monday", ifUnchangedSince: jog)
        XCTAssertNil(w.task(jog.id)?.repeatRule, "a task finished meanwhile is left alone")
    }

    func testCompletingARepeatCreatesTheNextAndUndoTakesItBack() {
        let (w, _) = makeWorkspace()
        let t = w.add("gym every day at 6pm", defaultDay: w.today)!
        w.setCompleted(t.id, true)
        XCTAssertEqual(w.data.tasks.count, 2)
        let next = w.open(on: "2026-11-08").first!
        XCTAssertEqual(next.title, "Gym")
        XCTAssertEqual(clock(next.reminderAt), "2026-11-08 18:00")
        XCTAssertNil(next.remoteId)

        w.setCompleted(t.id, false)
        XCTAssertEqual(w.data.tasks.count, 1)
        XCTAssertFalse(w.task(t.id)!.isCompleted)
    }

    func testOverdueCarryForwardAndMoves() {
        let (w, _) = makeWorkspace()
        let old = w.add("old", defaultDay: "2026-11-01")!
        let keep = w.add("keep", defaultDay: w.today)!
        XCTAssertEqual(w.overdue.map(\.id), [old.id])
        w.carryOverdueToToday()
        XCTAssertTrue(w.overdue.isEmpty)
        XCTAssertEqual(w.open(on: w.today).map(\.id), [keep.id, old.id])

        w.move(old.id, to: w.today, before: keep.id)
        XCTAssertEqual(w.open(on: w.today).map(\.id), [old.id, keep.id], "reorder")

        let timed = w.add("timed tomorrow at 5pm", defaultDay: nil)!
        w.move(timed.id, to: "2026-11-10")
        XCTAssertEqual(clock(w.task(timed.id)!.reminderAt), "2026-11-10 17:00", "keeps its time of day")
        w.move(timed.id, to: nil)
        XCTAssertNil(w.task(timed.id)!.reminderAt, "the Inbox has no dates")
        XCTAssertEqual(w.inbox.map(\.id), [timed.id])
    }

    func testDeleteUndo() {
        let (w, _) = makeWorkspace()
        var t = w.add("linked", defaultDay: w.today)!
        w.setRemoteId("R1", for: t.id)
        t = w.task(t.id)!
        w.delete(t.id)
        XCTAssertEqual(w.data.pendingRemoteDeletes, ["R1"])
        w.undoDelete(t.id)
        XCTAssertEqual(w.task(t.id)?.remoteId, "R1")
        XCTAssertTrue(w.data.pendingRemoteDeletes.isEmpty)

        // Undo after sync already removed it from Reminders: must relink, not look "deleted remotely".
        w.delete(t.id)
        w.clearPendingRemoteDeletes(["R1"])
        w.undoDelete(t.id)
        XCTAssertNil(w.task(t.id)?.remoteId)
    }

    func testRemindersRingOnceAndSnoozeRingsAgain() {
        let (w, advance) = makeWorkspace()
        let t = w.add("call in 10 minutes", defaultDay: nil)!
        XCTAssertEqual(w.nextWake(), t.reminderAt)
        XCTAssertTrue(w.takeDueReminders().isEmpty)
        advance(10 * 60)
        XCTAssertEqual(w.takeDueReminders().map(\.id), [t.id])
        XCTAssertTrue(w.takeDueReminders().isEmpty, "rings once")
        XCTAssertNil(w.nextWake())

        w.snooze(t.id)
        advance(4 * 60)
        XCTAssertTrue(w.takeDueReminders().isEmpty)
        advance(60)
        XCTAssertEqual(w.takeDueReminders().map(\.id), [t.id])
    }

    func testStaleRemindersRetireSilently() {
        let (w, advance) = makeWorkspace()
        _ = w.add("call in 10 minutes", defaultDay: nil)!
        advance(3 * 24 * 3600)
        XCTAssertTrue(w.takeDueReminders().isEmpty)
        XCTAssertNil(w.nextWake(), "and doesn't spin the wake timer")
    }

    func testNoteLineBecomesTask() {
        let (w, _) = makeWorkspace()
        let t = w.taskFromNoteLine("- call mom tomorrow at 5pm", day: w.today)!
        XCTAssertEqual(t.title, "Call mom")
        XCTAssertEqual(t.day, "2026-11-08")
        XCTAssertNil(w.taskFromNoteLine("   ", day: w.today))
    }
}

final class FocusTests: XCTestCase {
    func testPausedAndSleepTimeIsNotCounted() {
        let (w, advance) = makeWorkspace()
        let t = w.add("write", defaultDay: w.today)!
        w.focusStart(taskId: t.id, minutes: 25)
        advance(600)
        w.focusPause() // what the sleep notification calls
        advance(3600)
        XCTAssertEqual(w.data.focus.elapsed(at: w.now), 600)
        w.focusResume()
        advance(300)
        XCTAssertEqual(w.data.focus.remaining(at: w.now), 600)
        w.focusStop()
        XCTAssertEqual(w.data.sessions.last?.activeSeconds, 900)
        XCTAssertEqual(w.task(t.id)?.focusedSeconds, 900)
        XCTAssertEqual(w.data.focus.phase, .idle)
    }

    func testCountdownFinishesAndAddFiveContinues() {
        let (w, advance) = makeWorkspace()
        w.focusStart(minutes: 1)
        XCTAssertEqual(w.nextWake(), saturday.addingTimeInterval(60))
        advance(30)
        XCTAssertFalse(w.focusTick())
        advance(90) // the wake-up came late
        XCTAssertTrue(w.focusTick())
        XCTAssertEqual(w.data.focus.phase, .done)
        XCTAssertEqual(w.data.sessions.last?.activeSeconds, 60, "can't count past zero")

        w.focusAddFive()
        XCTAssertEqual(w.data.focus.phase, .running)
        XCTAssertEqual(w.data.focus.remaining(at: w.now), 300)
        advance(100)
        w.focusStop()
        XCTAssertEqual(w.data.sessions.reduce(0) { $0 + $1.activeSeconds }, 160, "second segment only logged once")
    }

    func testStopwatchHasNoEnd() {
        let (w, advance) = makeWorkspace()
        w.focusStart(stopwatch: true)
        XCTAssertNil(w.nextWake())
        advance(7200)
        XCTAssertFalse(w.focusTick())
        XCTAssertEqual(w.data.focus.display(at: w.now), 7200)
        XCTAssertEqual(FocusTimer.clock(7200), "2:00:00")
    }

    func testCrashRecoveryNeverInflates() {
        let (w, advance) = makeWorkspace()
        w.focusStart(minutes: 25)
        advance(600)
        w.focusPause()
        w.focusResume()
        advance(99_999) // app was gone
        w.recoverFocusAfterLaunch()
        XCTAssertEqual(w.data.focus.phase, .paused)
        XCTAssertEqual(w.data.focus.elapsed(at: w.now), 600)
    }
}

final class InsightsTests: XCTestCase {
    func testSummary() {
        let (w, advance) = makeWorkspace()
        // Previous week: one task done.
        let old = w.add("old", defaultDay: "2026-10-28")!
        w.update(old.id) { $0.completedAt = Day.at("2026-10-28", hour: 9, minute: 0, calendar: utc) }
        // This week: two done, one still open.
        let a = w.add("a", defaultDay: w.today)!, b = w.add("b", defaultDay: w.today)!
        _ = w.add("c", defaultDay: w.today)!
        w.setCompleted(a.id, true)
        w.setCompleted(b.id, true)
        w.focusStart(minutes: 60)
        advance(3000) // 10:00–10:50
        w.focusStop()

        let s = w.insights()
        XCTAssertEqual(s.completed, 2)
        XCTAssertEqual(s.previousCompleted, 1)
        XCTAssertEqual(s.planned, 3)
        XCTAssertEqual(s.focusSeconds, 3000)
        XCTAssertEqual(s.activeDays, 1)
        XCTAssertEqual(s.headline, "Momentum is building")
        XCTAssertEqual(s.sentence, "2 tasks done, up from 1 the week before, with 50m focused.")
        XCTAssertEqual(s.peakHour, 10)
        XCTAssertEqual(s.days.count, 7)
        XCTAssertEqual(s.days.last?.day, w.today)
    }

    func testSessionsSplitAcrossHours() {
        let (w, advance) = makeWorkspace(at: Day.at("2026-11-07", hour: 9, minute: 50, calendar: utc))
        w.focusStart(stopwatch: true)
        advance(1800)
        w.focusStop()
        let s = w.insights()
        XCTAssertEqual(s.hourly[9], 600)
        XCTAssertEqual(s.hourly[10], 1200)
        XCTAssertEqual(s.peakHour, 10)
    }

    func testEmptyWeek() {
        let (w, _) = makeWorkspace()
        let s = w.insights()
        XCTAssertEqual(s.headline, "A fresh start")
        XCTAssertNil(s.peakHour)
    }
}

final class ReconcileTests: XCTestCase {
    private let later = saturday.addingTimeInterval(100)
    private let earlier = saturday.addingTimeInterval(-100)

    private func linked(_ title: String, _ remote: String, modified: Date = saturday) -> TaskItem {
        var t = TaskItem(title: title, now: modified)
        t.remoteId = remote
        return t
    }

    private func plan(_ tasks: [TaskItem], _ remote: [RemoteReminder], pending: [String] = []) -> [SyncAction] {
        Reconciler.plan(tasks: tasks, remote: remote, pendingDeletes: pending, calendar: utc)
    }

    func testNewItemsFlowBothWays() {
        let local = TaskItem(title: "local", now: saturday)
        let actions = plan([local], [RemoteReminder(id: "R", title: "remote")])
        XCTAssertEqual(actions, [.createRemote(local.id), .importLocal(RemoteReminder(id: "R", title: "remote"))])
    }

    func testInSyncDoesNothing() {
        let t = linked("same", "R")
        XCTAssertEqual(plan([t], [RemoteReminder(id: "R", title: "same", modifiedAt: later)]), [])
    }

    func testMostRecentEditWins() {
        let t = linked("mine", "R")
        let newer = RemoteReminder(id: "R", title: "theirs", modifiedAt: later)
        XCTAssertEqual(plan([t], [newer]), [.pullLocal(t.id, newer)])
        let older = RemoteReminder(id: "R", title: "theirs", modifiedAt: earlier)
        XCTAssertEqual(plan([t], [older]), [.pushRemote(t.id, remoteId: "R")])
    }

    func testCompletionAndDeletion() {
        let t = linked("t", "R")
        let done = RemoteReminder(id: "R", title: "t", completed: true, modifiedAt: later)
        XCTAssertEqual(plan([t], [done]), [.pullLocal(t.id, done)], "ticked off on iPhone")
        XCTAssertEqual(plan([t], []), [.deleteLocal(t.id)], "deleted in Reminders")
        XCTAssertEqual(plan([], [RemoteReminder(id: "R", title: "t")], pending: ["R"]), [.deleteRemote("R")], "deleted here, not re-imported")
    }

    func testFinishedOnBothSidesUnlinksAndNeverComesBack() {
        var t = linked("t", "R")
        t.completedAt = saturday
        let done = RemoteReminder(id: "R", title: "t", completed: true, modifiedAt: later)
        XCTAssertEqual(plan([t], [done]), [.unlink(t.id)])
        t.remoteId = nil
        XCTAssertEqual(plan([t], [done]), [], "old completed reminders aren't imported")
    }

    func testMassDisappearanceNeverWipesThePlanner() {
        let tasks = (1...5).map { linked("t\($0)", "R\($0)") }
        let actions = plan(tasks, [])
        XCTAssertEqual(actions, tasks.map { .unlink($0.id) })
    }

    func testDueComparisonIgnoresSeconds() {
        var t = linked("t", "R")
        let at = Day.at("2026-11-08", hour: 17, minute: 0, calendar: utc)
        t.reminderAt = at
        t.day = "2026-11-08"
        let remote = RemoteReminder(id: "R", title: "t", due: RemoteDue(day: "2026-11-08", time: at.addingTimeInterval(20)), modifiedAt: later)
        XCTAssertEqual(plan([t], [remote]), [])
    }

    func testDeadlineTravelsInNotes() {
        XCTAssertEqual(DeadlineLine.compose(notes: "hi", deadline: "2026-12-01"), "hi\nDeadline: 2026-12-01")
        let split = DeadlineLine.split("hi\nDeadline: 2026-12-01")
        XCTAssertEqual(split.notes, "hi")
        XCTAssertEqual(split.deadline, "2026-12-01")
        XCTAssertEqual(DeadlineLine.split("Deadline: soon").deadline, nil)
    }

    func testPullKeepsThingsInStepAndRepeatsSpawn() {
        let (w, _) = makeWorkspace()
        let t = w.add("gym every day", defaultDay: w.today)!
        w.setRemoteId("R", for: t.id)
        let remote = RemoteReminder(id: "R", title: "Gym", due: RemoteDue(day: "2026-11-07"), completed: true, modifiedAt: later)
        w.applyRemote(remote, to: t.id)
        XCTAssertTrue(w.task(t.id)!.isCompleted)
        XCTAssertEqual(w.open(on: "2026-11-08").count, 1, "ticking off on iPhone still creates the next one")
        XCTAssertEqual(Reconciler.plan(tasks: [w.task(t.id)!], remote: [remote], pendingDeletes: [], calendar: utc), [.unlink(t.id)], "no ping-pong after a pull")
    }

    func testImportWithoutDateLandsInInbox() {
        let (w, _) = makeWorkspace()
        w.importRemote(RemoteReminder(id: "R", title: "from phone", modifiedAt: later))
        XCTAssertEqual(w.inbox.first?.title, "from phone")
        XCTAssertEqual(w.inbox.first?.remoteId, "R")
    }

    func testImportedPastReminderDoesNotRing() {
        let (w, _) = makeWorkspace()
        w.importRemote(RemoteReminder(id: "R", title: "old", due: RemoteDue(day: "2026-11-07", time: earlier), modifiedAt: later))
        XCTAssertTrue(w.takeDueReminders().isEmpty)
    }
}

final class StoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json")
    }

    func testRoundTripAndFreshStart() throws {
        let store = Store(url: tempURL())
        guard case .fresh = store.load() else { return XCTFail("expected fresh") }
        var data = AppData()
        data.tasks = [TaskItem(title: "t")]
        data.notes["2026-11-07"] = "hello"
        try store.save(data)
        guard case .loaded(let back) = store.load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(back.tasks.first?.title, "t")
        XCTAssertEqual(back.notes["2026-11-07"], "hello")
    }

    func testOlderFilesMissingNewFieldsStillLoad() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString
        try Data(#"{"tasks":[{"id":"\#(id)","title":"old"}]}"#.utf8).write(to: url)
        guard case .loaded(let data) = Store(url: url).load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(data.tasks.first?.title, "old")
        XCTAssertEqual(data.settings.cards.count, 4)
    }

    func testCorruptFileIsSetAsideAndBackupUsed() throws {
        let url = tempURL()
        let store = Store(url: url)
        var data = AppData()
        data.tasks = [TaskItem(title: "good")]
        try store.save(data)
        try store.save(data) // second save creates the backup
        try Data("not json".utf8).write(to: url)
        guard case .recovered(let back, let aside) = store.load() else { return XCTFail("expected recovered") }
        XCTAssertEqual(back.tasks.first?.title, "good")
        XCTAssertEqual(String(decoding: try Data(contentsOf: aside), as: UTF8.self), "not json", "kept for inspection")
    }

    func testRestoreKeepsACopyOfTheCurrentDataThenReplacesIt() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (old, _) = makeWorkspace()
        old.add("restored", defaultDay: nil)
        old.focusStart(minutes: 25)
        let backup = try Store.decoder.decode(AppData.self, from: old.exportJSON())

        let (w, _) = makeWorkspace()
        w.add("current", defaultDay: nil)
        let before = w.data
        let copy = try w.restore(backup, keepingCopyIn: Store(url: url))

        XCTAssertEqual(w.data.tasks.map(\.title), ["Restored"])
        XCTAssertEqual(w.data.focus.phase, .paused, "a timer running in the backup would count all the time since")
        XCTAssertEqual(copy.deletingLastPathComponent(), url.deletingLastPathComponent())
        XCTAssertNotEqual(copy, url)
        XCTAssertEqual(try Store.decoder.decode(AppData.self, from: Data(contentsOf: copy)), before)
        guard case .loaded(let saved) = Store(url: url).load() else { return XCTFail("the restore is on disk before it's shown") }
        XCTAssertEqual(saved.tasks.map(\.title), ["Restored"])
    }

    func testRestoreKeepsFocusTimeThatWasRunningAndDoesntRingOldReminders() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (old, _) = makeWorkspace()
        let call = old.add("call bob at 10:15", defaultDay: nil)!
        let backup = try Store.decoder.decode(AppData.self, from: old.exportJSON())

        let (w, advance) = makeWorkspace()
        w.focusStart(minutes: 25)
        advance(1200)
        let copy = try w.restore(backup, keepingCopyIn: Store(url: url))
        let kept = try Store.decoder.decode(AppData.self, from: Data(contentsOf: copy))
        XCTAssertEqual(kept.focus.phase, .paused, "restoring the copy gives back the 20 minutes of focus")
        XCTAssertEqual(kept.focus.accumulated, 1200)
        XCTAssertEqual(w.task(call.id)?.title, "Call bob")
        XCTAssertTrue(w.takeDueReminders().isEmpty, "a reminder that came due before the restore already rang")
    }

    func testARestoredBackupWinsOverReminders() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func linked(_ title: String, _ remoteId: String?) -> TaskItem {
            var task = TaskItem(title: title, now: saturday.addingTimeInterval(-7200))
            task.remoteId = remoteId
            return task
        }
        var backup = AppData()
        backup.tasks = [linked("Kept", "R1"), linked("Deleted since", "R2"), linked("Never synced", nil)]
        backup.settings.remindersSync = false

        let (w, _) = makeWorkspace()
        w.data.tasks = [linked("Edited since", "R1"), linked("Added since", "R3")]
        w.data.settings.remindersSync = true
        w.data.settings.reminderListId = "L"
        _ = try w.restore(backup, keepingCopyIn: Store(url: url))

        let reminders = [RemoteReminder(id: "R1", title: "Edited since", modifiedAt: saturday.addingTimeInterval(-60)),
                         RemoteReminder(id: "R3", title: "Added since")]
        let ids = backup.tasks.map(\.id)
        XCTAssertEqual(Reconciler.plan(tasks: w.data.tasks, remote: reminders, pendingDeletes: w.data.pendingRemoteDeletes), [
            .deleteRemote("R3"),
            .pushRemote(ids[0], remoteId: "R1"),
            .createRemote(ids[1]),
            .createRemote(ids[2]),
        ], "the backup's version is pushed, a deleted reminder is made again, and one added since goes")
        XCTAssertTrue(w.data.settings.remindersSync, "sync is this Mac's setting, not the backup's")
    }

    func testARestoreKeepsTheRemindersOfTasksStillHere() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let alpha = TaskItem(title: "Alpha", now: saturday.addingTimeInterval(-7200))
        var backup = AppData()
        backup.tasks = [alpha] // saved before sync was turned on, so it has no link

        let (w, _) = makeWorkspace()
        var linked = alpha
        linked.remoteId = "N1"
        var beta = TaskItem(title: "Beta", now: saturday)
        beta.remoteId = "N2"
        w.data.tasks = [linked, beta]
        w.data.settings.reminderListId = "L" // synced before, though sync is off right now
        _ = try w.restore(backup, keepingCopyIn: Store(url: url))

        let reminders = [RemoteReminder(id: "N1", title: "Alpha"), RemoteReminder(id: "N2", title: "Beta")]
        XCTAssertEqual(Reconciler.plan(tasks: w.data.tasks, remote: reminders, pendingDeletes: w.data.pendingRemoteDeletes),
                       [.deleteRemote("N2")], "Alpha keeps its reminder rather than getting a new one")
    }

    func testRestoreChangesNothingIfTheCopyCantBeWritten() {
        let (w, _) = makeWorkspace()
        w.add("current", defaultDay: nil)
        let before = w.data
        var changes = 0
        w.onChange = { changes += 1 }
        var backup = AppData()
        backup.tasks = [TaskItem(title: "restored")]
        XCTAssertThrowsError(try w.restore(backup, keepingCopyIn: Store(url: tempURL()))) // its folder doesn't exist
        XCTAssertEqual(w.data, before)
        XCTAssertEqual(changes, 0, "no save, sync or wake is scheduled either")
    }

    func testFilesThatArentBackupsAreRejected() throws {
        for raw in ["", "not json", "[]", "{}", #"{"tasks":"no"}"#, #"{"tasks":[{"title":"no id"}]}"#] {
            XCTAssertThrowsError(try Store.decoder.decode(AppData.self, from: Data(raw.utf8)), raw) { error in
                XCTAssertTrue(error is DecodingError, "the Settings message relies on it: \(raw)")
            }
        }
        XCTAssertNoThrow(try Store.decoder.decode(AppData.self, from: Workspace().exportJSON()))
    }
}

final class AgentConfigTests: XCTestCase {
    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private let code = AgentClient.all[0]
    private let app = AgentClient.all[1]

    func testConnectKeepsEverythingElseAndPermissions() throws {
        let home = try tempHome()
        let file = home.appendingPathComponent(".claude.json")
        try Data(#"{"oauth":"secret","mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        try AgentConfig.connect(code, executable: "/Applications/Perch.app/Contents/MacOS/Perch", home: home)
        XCTAssertTrue(AgentConfig.isConnected(code, home: home))

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(object["oauth"] as? String, "secret")
        let servers = object["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual((servers["perch"] as! [String: Any])["args"] as? [String], ["--mcp"])

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
        XCTAssertEqual(mode, 0o600, "must not widen a credentials file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".perch-backup"))

        try AgentConfig.disconnect(code, home: home)
        XCTAssertFalse(AgentConfig.isConnected(code, home: home))
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertNotNil((after["mcpServers"] as! [String: Any])["other"])
    }

    func testBrokenConfigIsNeverOverwritten() throws {
        let home = try tempHome()
        let file = home.appendingPathComponent(".claude.json")
        try Data("{ broken".utf8).write(to: file)
        XCTAssertThrowsError(try AgentConfig.connect(code, executable: "/x", home: home))
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "{ broken")
    }

    func testCreatesMissingFileAndFolders() throws {
        let home = try tempHome()
        XCTAssertFalse(AgentConfig.isConnected(app, home: home))
        try AgentConfig.connect(app, executable: "/x", home: home)
        XCTAssertTrue(AgentConfig.isConnected(app, home: home))
    }
}

final class MCPTests: XCTestCase {
    private func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let reply = try JSONSerialization.jsonObject(with: Data(server.handle(line: line)!.utf8)) as! [String: Any]
        let result = reply["result"] as! [String: Any]
        let content = (result["content"] as! [[String: Any]])[0]["text"] as! String
        return (content, result["isError"] as! Bool)
    }

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    func testHandshake() throws {
        let (w, _) = makeWorkspace()
        let server = MCPServer(workspace: w)
        let initialize = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)!
        XCTAssertTrue(initialize.contains(#""protocolVersion":"2025-03-26""#))
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no reply")
        XCTAssertTrue(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!.contains("add_tasks"))
        XCTAssertTrue(server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)!.contains("-32601"))
        XCTAssertTrue(server.handle(line: "not json")!.contains("-32700"))
    }

    func testEveryAdvertisedToolHasValidSchema() throws {
        // Anything non-JSON in the definitions would make tools/list blow up at runtime.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(MCPServer.tools))
        XCTAssertEqual(MCPServer.tools.count, 15)
    }

    func testDemoFlow() throws {
        let (w, _) = makeWorkspace()
        let server = MCPServer(workspace: w)
        let added = try call(server, "add_tasks", ["titles": ["Call mom at 5pm", "Gym after work !high"]])
        XCTAssertFalse(added.isError)
        let tasks = try json(added.text) as! [[String: Any]]
        XCTAssertEqual(tasks.map { $0["title"] as! String }, ["Call mom", "Gym after work"])
        XCTAssertEqual(tasks[1]["priority"] as? String, "high")
        XCTAssertEqual(tasks[1]["day"] as? String, "2026-11-07")

        let listed = try json(try call(server, "list_tasks").text) as! [[String: Any]]
        XCTAssertEqual(listed.count, 2)

        let id = tasks[0]["id"] as! String
        _ = try call(server, "update_task", ["id": id, "project": "Home", "deadline": "friday", "repeat": "every weekday", "steps": ["a", "b"]])
        let task = w.task(UUID(uuidString: id)!)!
        XCTAssertEqual(task.project, "Home")
        XCTAssertEqual(task.deadline, "2026-11-13")
        XCTAssertEqual(task.repeatRule?.kind, .weekdays)
        XCTAssertEqual(task.steps.map(\.title), ["a", "b"])

        _ = try call(server, "set_reminder", ["id": id, "at": "tomorrow at 9am"])
        XCTAssertEqual(clock(w.task(UUID(uuidString: id)!)!.reminderAt), "2026-11-08 09:00")

        _ = try call(server, "write_note", ["text": "from claude"])
        XCTAssertEqual(w.note(on: w.today), "from claude")

        let insights = try json(try call(server, "get_insights").text) as! [String: Any]
        XCTAssertEqual(insights["completed_last_7_days"] as? Int, 0)

        let started = try json(try call(server, "focus_start", ["task_id": id, "minutes": 10]).text) as! [String: Any]
        XCTAssertEqual(started["state"] as? String, "running")
        XCTAssertEqual(started["remaining_seconds"] as? Int, 600)
        _ = try call(server, "focus_pause")
        XCTAssertEqual(w.data.focus.phase, .paused)
        _ = try call(server, "focus_stop")
        XCTAssertEqual(w.data.focus.phase, .idle)

        _ = try call(server, "complete_task", ["id": id])
        XCTAssertTrue(w.task(UUID(uuidString: id)!)!.isCompleted)
    }

    func testBadInputIsRejectedAndChangesNothing() throws {
        let (w, _) = makeWorkspace()
        let server = MCPServer(workspace: w)
        let t = w.add("t", defaultDay: w.today)!
        XCTAssertTrue(try call(server, "add_tasks", ["titles": "not an array"]).isError)
        XCTAssertTrue(try call(server, "complete_task", ["id": "nope"]).isError)
        XCTAssertTrue(try call(server, "complete_task", ["id": UUID().uuidString]).isError)
        XCTAssertTrue(try call(server, "set_reminder", ["id": t.id.uuidString, "at": "whenever"]).isError)
        XCTAssertTrue(try call(server, "read_note", ["day": "sometime"]).isError)
        XCTAssertTrue(try call(server, "focus_start", ["minutes": -5]).isError)
        XCTAssertTrue(try call(server, "no_such_tool").isError)

        let before = w.task(t.id)!
        XCTAssertTrue(try call(server, "update_task", ["id": t.id.uuidString, "title": "changed", "priority": "huge"]).isError)
        XCTAssertEqual(w.task(t.id), before, "a bad field leaves the task untouched")
    }
}

final class CardLayoutTests: XCTestCase {
    func testWidthsFollowWeights() {
        XCTAssertEqual(CardLayout.widths([2, 1, 1], minimums: [0, 0, 0], in: 400), [200, 100, 100])
    }

    func testWidthsNeverGoBelowAMinimum() {
        let widths = CardLayout.widths([0.1, 1, 1], minimums: [150, 0, 0], in: 450)
        XCTAssertEqual(widths, [150, 150, 150])
    }

    func testResizeTradesWidthBetweenTheTwoNeighboursOnly() {
        let weights = CardLayout.resize([2, 1, 1], at: 0, by: -100, minimums: [0, 0, 0], in: 400)
        XCTAssertEqual(weights, [1, 2, 1])
    }

    func testResizeStopsAtEitherNeighboursMinimum() {
        let left = CardLayout.resize([1, 1], at: 0, by: -500, minimums: [150, 150], in: 400)
        XCTAssertEqual(CardLayout.widths(left, minimums: [150, 150], in: 400), [150, 250])
        let right = CardLayout.resize([1, 1], at: 0, by: 500, minimums: [150, 150], in: 400)
        XCTAssertEqual(CardLayout.widths(right, minimums: [150, 150], in: 400), [250, 150])
    }

    func testResizeMovesOnlyTheGapEvenWhenACardIsAtItsMinimum() {
        let minimums: [Double] = [270, 150, 140, 140]
        func widths(_ weights: [Double]) -> [Double] { CardLayout.widths(weights, minimums: minimums, in: 804).map { ($0 * 1000).rounded() / 1000 } }
        let tasksSmall: [Double] = [0.85, 1.9, 1, 1] // Tasks S and the others M sit at their minimums
        XCTAssertEqual(widths(tasksSmall), [270, 254, 140, 140])
        XCTAssertEqual(widths(CardLayout.resize(tasksSmall, at: 0, by: 110, minimums: minimums, in: 804)), [374, 150, 140, 140])
        XCTAssertEqual(widths(CardLayout.resize(tasksSmall, at: 0, by: 0, minimums: minimums, in: 804)), [270, 254, 140, 140], "a click moves nothing")
    }

    func testCustomWidthPersistsAndOlderPresetsStillLoad() throws {
        var card = CardConfig(kind: .notes)
        card.weight = 1.37
        let back = try JSONDecoder().decode(CardConfig.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(back.weight, 1.37)
        let old = try JSONDecoder().decode(CardConfig.self, from: Data(#"{"kind":"tasks","visible":false,"width":"wide"}"#.utf8))
        XCTAssertEqual(old.weight, CardConfig.Width.wide.weight)
        XCTAssertFalse(old.visible)
        let bad = try JSONDecoder().decode(CardConfig.self, from: Data(#"{"kind":"tasks","visible":true,"weight":-3,"width":"wide"}"#.utf8))
        XCTAssertEqual(bad.weight, CardConfig.Width.wide.weight, "a weight that can't lay out falls back to the preset")
        let huge = try JSONDecoder().decode(CardConfig.self, from: Data(#"{"kind":"tasks","visible":true,"weight":1e308}"#.utf8))
        XCTAssertEqual(huge.weight, CardConfig.Width.regular.weight, "it would overflow to NaN, which can't be saved")
    }
}

final class ProtectedFoldersTests: XCTestCase {
    func testAFileIsGoneOnlyWhenNothingIsThere() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("clip.png")
        try Data().write(to: file)
        XCTAssertFalse(FileCheck.isGone(file.path))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        XCTAssertFalse(FileCheck.isGone(file.path), "a file Perch is refused isn't a deleted one")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try fm.removeItem(at: file)
        XCTAssertTrue(FileCheck.isGone(file.path))
    }

    private let folders = ["/Users/me/Desktop", "/Users/me/Documents", "/Volumes"].map { URL(fileURLWithPath: $0) }

    private func mayPrompt(_ path: String, granted: String? = nil) -> Bool {
        ProtectedFolders.mayPrompt(path, granted: granted.map { URL(fileURLWithPath: $0) }, protected: folders)
    }

    func testFilesInsideProtectedFoldersMayPrompt() {
        XCTAssertTrue(mayPrompt("/Users/me/Documents/report.pdf"))
        XCTAssertTrue(mayPrompt("/Users/me/Desktop/a/b.png"))
        XCTAssertTrue(mayPrompt("/Volumes/USB/photo.jpg"))
    }

    func testOtherFilesDoNot() {
        XCTAssertFalse(mayPrompt("/Users/me/Pictures/cat.png"))
        XCTAssertFalse(mayPrompt("/Users/me/Documents Old/notes.txt"), "a sibling with the same prefix isn't inside")
        XCTAssertFalse(mayPrompt("/Users/me/Library/Application Support/Perch/Clips/x.png"))
    }

    func testAGrantedFolderCoversItsWholeProtectedFolder() {
        XCTAssertFalse(mayPrompt("/Users/me/Desktop/shot.png", granted: "/Users/me/Desktop"))
        XCTAssertFalse(mayPrompt("/Users/me/Desktop/shot.png", granted: "/Users/me/Desktop/Screenshots"))
        XCTAssertTrue(mayPrompt("/Users/me/Documents/report.pdf", granted: "/Users/me/Desktop"))
        XCTAssertTrue(mayPrompt("/Users/me/Desktop/shot.png", granted: "/Users/me/Pictures"))
    }

    func testMatchingIgnoresCase() {
        XCTAssertTrue(mayPrompt("/Users/me/desktop/shot.png"), "the default volume opens this as the Desktop")
        XCTAssertFalse(mayPrompt("/Users/me/Desktop/shot.png", granted: "/users/me/desktop"))
    }

    func testAGrantedVolumeCoversOnlyItself() {
        XCTAssertFalse(mayPrompt("/Volumes/USB/shot.png", granted: "/Volumes/USB/Shots"))
        XCTAssertTrue(mayPrompt("/Volumes/NAS/report.pdf", granted: "/Volumes/USB/Shots"))
    }

    func testDefaultsAreTheUsersFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage/Dropbox"]
            .map { "\(home)/\($0)/file" } + ["/Volumes/USB/file"]
        for path in paths {
            XCTAssertTrue(ProtectedFolders.mayPrompt(path, granted: nil), path)
        }
        XCTAssertFalse(ProtectedFolders.mayPrompt("\(home)/Pictures/file", granted: nil))
    }
}
