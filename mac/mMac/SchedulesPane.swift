import MuseBackend
import MuseKit
import SwiftUI

/// Settings › Scheduled, as Desktop's Scheduled page.
/// Errors from its actions show in the Settings window's alert, through `settings`.
struct SchedulesPane: View {
  let settings: SettingsModel
  @State private var editing: ScheduleInput?
  @State private var deleting: ScheduleEntry?
  /// The name in the Delete alert's title. Kept after the alert closes, so the title never reads
  /// with an empty name while it animates away.
  @State private var deletingName = ""
  /// A switch's new value until the backend's list confirms or refuses it, so it does not flicker.
  @State private var pendingEnabled: [String: Bool] = [:]

  private var workspace: Workspace { settings.workspace }

  var body: some View {
    Form {
      Section {
        Text(
          "Muse runs these tasks on this Mac while mMac is open. A run that was missed while the Mac slept runs once when it wakes, if it is less than seven days old."
        )
        .foregroundStyle(.themeSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        if workspace.schedules.isEmpty {
          Text("No scheduled tasks yet.").foregroundStyle(.themeSecondary)
        }
        ForEach(workspace.schedules) { entry in row(entry) }
      }
      Section {
        HStack {
          Spacer()
          Button {
            editing = ScheduleInput(
              name: "", prompt: "", folder: workspace.project, preset: "daily", minute: 0, hour: 9, weekday: 1,
              approvalMode: ApprovalMode.promptUnmatched.rawValue)
          } label: {
            Label("Add task", systemImage: "plus")
          }
          .accessibilityIdentifier("schedule-add")
        }
      }
    }
    .formStyle(.grouped)
    .task { await workspace.loadSchedules() }
    .sheet(item: Binding(get: { editing.map(EditingInput.init) }, set: { editing = $0?.input })) { item in
      ScheduleForm(workspace: workspace, input: item.input) { editing = nil }
    }
    .alert(
      "Delete the scheduled task \(deletingName)?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { entry in
      Button("Cancel", role: .cancel) { deleting = nil }
      Button("Delete", role: .destructive) {
        deleting = nil
        perform { await workspace.removeSchedule(id: entry.schedule.id) }
      }
    }
  }

  /// Runs a Workspace action, then moves any error it reported to the Settings window's alert:
  /// the Workspace's own alert is in the conversation window.
  private func perform(_ action: @escaping @MainActor () async -> Void, then: (@MainActor () -> Void)? = nil) {
    Task {
      await action()
      then?()
      if let error = workspace.errorMessage {
        settings.errorMessage = error
        workspace.errorMessage = nil
      }
    }
  }

  /// Name and switch, then the trigger and next run, then the actions: three lines, so a long name
  /// or a narrow window never pushes a control out of view.
  private func row(_ entry: ScheduleEntry) -> some View {
    let schedule = entry.schedule
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(schedule.name).bold().lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
        let enabled = pendingEnabled[schedule.id] ?? schedule.enabled
        Toggle(
          "Active",
          isOn: Binding(
            get: { enabled },
            set: { value in
              pendingEnabled[schedule.id] = value
              // The reload after the call gives the backend's value, kept or refused.
              perform({ await workspace.setScheduleEnabled(id: schedule.id, enabled: value) }) {
                if pendingEnabled[schedule.id] == value { pendingEnabled[schedule.id] = nil }
              }
            })
        )
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityLabel("\(schedule.name) active")
        .help(enabled ? "Active: runs on its schedule" : "Paused: runs only with Run now")
        .accessibilityIdentifier("schedule-active-\(schedule.id)")
      }
      // "Paused" is written out, so the switch's colour is never the only sign.
      Text("\(ScheduleRules.trigger(schedule)) \u{00B7} \(ScheduleRules.nextRun(entry, now: .now))")
        .font(.caption)
        .foregroundStyle(.themeSecondary)
        .lineLimit(2)
      HStack(spacing: 8) {
        Button("Run now") { perform { await workspace.runSchedule(id: schedule.id) } }
          .accessibilityLabel("Run \(schedule.name) now")
          .accessibilityIdentifier("schedule-run-\(schedule.id)")
        Button("Edit") { editing = ScheduleRules.input(from: schedule) }
          .accessibilityLabel("Edit \(schedule.name)")
          .accessibilityIdentifier("schedule-edit-\(schedule.id)")
        Spacer(minLength: 0)
        Button(role: .destructive) {
          deletingName = schedule.name
          deleting = entry
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .accessibilityLabel("Delete \(schedule.name)")
        .accessibilityIdentifier("schedule-delete-\(schedule.id)")
      }
      .controlSize(.small)
      if !entry.history.isEmpty {
        DisclosureGroup("History") {
          ForEach(Array(entry.history.prefix(5).enumerated()), id: \.offset) { _, run in
            Text(ScheduleRules.historyLine(run, now: .now))
              .font(.caption)
              .lineLimit(3)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .font(.caption)
        .accessibilityLabel("History of \(schedule.name)")
      }
    }
    .padding(.vertical, 2)
  }
}

/// `ScheduleInput` with an identity for `.sheet(item:)`.
private struct EditingInput: Identifiable {
  let input: ScheduleInput
  var id: String { input.id ?? "new" }
}

/// Add task and Edit's form. Save keeps it open with the backend's message, or closes it.
struct ScheduleForm: View {
  let workspace: Workspace
  @State var input: ScheduleInput
  let done: () -> Void
  @State private var message: String?
  @State private var saving = false

  var body: some View {
    Form {
      TextField("Name", text: $input.name)
      TextField("Instructions", text: $input.prompt, axis: .vertical).lineLimit(3...8)
      Picker("Folder", selection: $input.folder) {
        if input.folder.isEmpty { Text("Choose a folder").tag("") }
        ForEach(folders, id: \.self) { path in
          Text(ProjectPath.name(of: path)).lineLimit(1).truncationMode(.middle).tag(path)
        }
      }
      .help(input.folder)
      Picker("Trigger", selection: $input.preset) {
        Text("Hourly").tag("hourly")
        Text("Daily").tag("daily")
        Text("Weekdays").tag("weekdays")
        Text("Weekly").tag("weekly")
        Text("Manual").tag("manual")
        Text("Custom (cron)").tag("custom")
      }
      if input.preset == "hourly" {
        Stepper("At minute \(input.minute)", value: $input.minute, in: 0...59)
      }
      if ["daily", "weekdays", "weekly"].contains(input.preset) {
        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
      }
      if input.preset == "weekly" {
        Picker("Day", selection: $input.weekday) {
          // 0 is Sunday, as `weekdaySymbols` and the backend count.
          ForEach(0..<7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day]).tag(day) }
        }
      }
      if input.preset == "custom" {
        TextField("Cron expression", text: Binding(get: { input.cron ?? "" }, set: { input.cron = $0 }))
          .font(.body.monospaced())
      }
      Picker("Permission mode", selection: $input.approvalMode) {
        if ApprovalMode(rawValue: input.approvalMode) == nil {
          Text(input.approvalMode).tag(input.approvalMode)
        }
        ForEach(ApprovalMode.allCases) { mode in Text(mode.label).tag(mode.rawValue) }
      }
      Picker(
        "Model", selection: Binding(get: { input.modelId ?? "" }, set: { input.modelId = $0.isEmpty ? nil : $0 })
      ) {
        Text("CLI default").tag("")
        if let id = input.modelId, !workspace.models.contains(where: { $0.modelId == id }) {
          Text(id).tag(id)
        }
        ForEach(workspace.models) { model in Text(model.displayLabel).lineLimit(1).tag(model.modelId) }
      }
      Toggle("Start in a new Git worktree", isOn: $input.worktree)
      if let message {
        // The symbol and the words carry it, not the red alone.
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("schedule-form-message")
      }
    }
    .formStyle(.grouped)
    // Escape and Command-period close a sheet without its Cancel button.
    .interactiveDismissDisabled(saving)
    .frame(minWidth: 380, idealWidth: 460, maxWidth: 560)
    .toolbar {
      // Not while saving: the form stays until the backend answers, then closes or shows why.
      ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done).disabled(saving) }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          guard !saving else { return }
          saving = true
          Task {
            message = await workspace.saveSchedule(input)
            saving = false
            if message == nil { done() }
          }
        }
        .disabled(saving)
        .accessibilityIdentifier("schedule-save")
      }
    }
  }

  /// The recent projects, and the task's own folder when it is not one of them.
  private var folders: [String] {
    let recent = workspace.preferences.recentProjects
    return input.folder.isEmpty || recent.contains(input.folder) ? recent : recent + [input.folder]
  }

  private var timeBinding: Binding<Date> {
    Binding(
      get: { Calendar.current.date(from: DateComponents(hour: input.hour, minute: input.minute)) ?? .now },
      set: { date in
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        input.hour = parts.hour ?? 9
        input.minute = parts.minute ?? 0
      })
  }
}
