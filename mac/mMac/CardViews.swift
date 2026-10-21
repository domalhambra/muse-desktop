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
      MonospacedBox(text: ApprovalPresentation.subject(approval))
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
          // By index: two options with the same label must still be two rows.
          ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
            Button {
              form.choose(option.label, in: prompt.id)
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(prompt, option))
                VStack(alignment: .leading, spacing: 1) {
                  Text(option.label).bold()
                  if let description = option.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.label)
            .accessibilityAddTraits(form.isChosen(option.label, in: prompt.id) ? .isSelected : [])
          }
          TextField(
            "Or write your own answer…",
            text: Binding(get: { form.freeText(in: prompt.id) }, set: { form.write($0, in: prompt.id) })
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Your answer: \(prompt.header)")
        }
      }
      HStack {
        Spacer()
        Button("Skip question") { Task { await workspace.skip(question) } }
        Button(sending ? "Sending…" : "Continue") {
          Task { await workspace.answer(question, answers: form.submission) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!form.canContinue)
      }
      .disabled(sending)
    }
    .cardStyle()
  }

  private func icon(_ prompt: UserQuestion.Prompt, _ option: UserQuestion.Option) -> String {
    let chosen = form.isChosen(option.label, in: prompt.id)
    if prompt.selection.mode == "multiple" { return chosen ? "checkmark.square.fill" : "square" }
    return chosen ? "largecircle.fill.circle" : "circle"
  }
}
