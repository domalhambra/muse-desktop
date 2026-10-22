import MuseBackend
import MuseKit
import SwiftUI

extension View {
  /// The look of approval and question cards.
  func cardStyle() -> some View {
    padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.5)))
  }
}

/// "Approval required", as Electron's `ApprovalCard`.
struct ApprovalCard: View {
  let approval: Approval
  let workspace: Workspace

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Approval required", systemImage: "hand.raised").font(.headline)
      Text(ApprovalPresentation.heading(approval))
      MonospacedBox(text: ApprovalPresentation.subject(approval), label: "Approval request")
      HStack(alignment: .top, spacing: 8) {
        ForEach(approval.availableChoices) { choice in
          VStack(spacing: 2) {
            choiceButton(choice)
            if ApprovalPresentation.savesRule(choice) {
              Text("Saves a rule").font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
      }
      .disabled(workspace.decidingApprovals.contains(approval.approvalId))
    }
    .cardStyle()
  }

  @ViewBuilder private func choiceButton(_ choice: Approval.Choice) -> some View {
    let button = Button(choice.label) {
      Task { await workspace.approve(approval, choice: choice) }
    }
    .help(ApprovalPresentation.help(choice))
    if ApprovalPresentation.isPrimary(choice) {
      button.buttonStyle(.borderedProminent)
    } else {
      button.buttonStyle(.bordered)
    }
  }
}

/// "Input required", as Electron's `QuestionCard`.
struct QuestionCard: View {
  let question: UserQuestion
  let workspace: Workspace
  @State private var form: QuestionForm

  init(question: UserQuestion, workspace: Workspace) {
    self.question = question
    self.workspace = workspace
    _form = State(initialValue: QuestionForm(question))
  }

  var body: some View {
    let sending = workspace.answeringQuestions.contains(question.userInputId)
    VStack(alignment: .leading, spacing: 12) {
      Label("Input required", systemImage: "questionmark.bubble").font(.headline)
      Text("Muse has a question before continuing.")
      ForEach(question.questions) { prompt in
        VStack(alignment: .leading, spacing: 6) {
          Text(prompt.question).bold()
          if prompt.selection.mode == "multiple" {
            ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
              Toggle(
                isOn: Binding(
                  get: { form.isChosen(option.label, in: prompt.id) },
                  set: { _ in form.choose(option.label, in: prompt.id) })
              ) {
                OptionLabel(option: option)
              }
              .toggleStyle(.checkbox)
              .accessibilityLabel(option.label)
              .accessibilityHint(option.description ?? "")
            }
          } else {
            // Rows go by index, so two options with the same label are still two rows. The answer
            // goes by label, so the first of them shows as chosen.
            Picker(
              prompt.header,
              selection: Binding(
                get: { prompt.options.firstIndex { form.isChosen($0.label, in: prompt.id) } },
                set: { index in if let index { form.choose(prompt.options[index].label, in: prompt.id) } })
            ) {
              ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                // Without `.ignore`, the radio button joins its own text to these: "Blue, Blue".
                OptionLabel(option: option)
                  .tag(Optional(index))
                  .accessibilityElement(children: .ignore)
                  .accessibilityLabel(option.label)
                  .accessibilityHint(option.description ?? "")
              }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
          }
          TextField(
            "Or write your own answer…",
            text: Binding(get: { form.freeText(in: prompt.id) }, set: { form.write($0, in: prompt.id) })
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Your answer: \(prompt.header)")
          .onSubmit(submit)
        }
      }
      HStack {
        Spacer()
        Button("Skip question") { Task { await workspace.skip(question) } }
        Button(sending ? "Sending…" : "Continue", action: submit)
        .buttonStyle(.borderedProminent)
        .disabled(!form.canContinue)
      }
      .disabled(sending)
    }
    .cardStyle()
    // A question asked again under the same id with new prompts starts a fresh form.
    .onChange(of: question) { _, new in form = QuestionForm(new) }
  }

  /// Continue, and Return in a free-text field: only when the form can continue and is not sent.
  private func submit() {
    guard form.canContinue, !workspace.answeringQuestions.contains(question.userInputId) else { return }
    Task { await workspace.answer(question, answers: form.submission) }
  }
}

/// An option's label, bold as in Electron, with its description under it.
struct OptionLabel: View {
  let option: UserQuestion.Option

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(option.label).bold()
      if let description = option.description {
        Text(description).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
