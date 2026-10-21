import Foundation
import MuseBackend
import Testing
@testable import MuseKit

private func question(mode: String, min: Int? = nil, max: Int? = nil) throws -> UserQuestion {
  let json = """
    {"userInputId":"u1","sessionId":"s1","questions":[
      {"id":"q1","header":"Pick","question":"Which?","options":[{"label":"A"},{"label":"B"},{"label":"C"}],
       "selection":{"mode":"\(mode)"\(min.map { ",\"minSelections\":\($0)" } ?? "")\(max.map { ",\"maxSelections\":\($0)" } ?? "")}},
      {"id":"q2","header":"Name","question":"Your name?","options":[],"selection":{"mode":"single"}}]}
    """
  return try JSONDecoder().decode(UserQuestion.self, from: Data(json.utf8))
}

@Test func aSingleChoiceAndFreeTextAnswerEveryPrompt() throws {
  var form = QuestionForm(try question(mode: "single"))
  #expect(!form.canContinue)
  form.choose("B", in: "q1")
  #expect(!form.canContinue)
  form.write("  ", in: "q2")
  #expect(!form.canContinue)
  form.write("Dom", in: "q2")
  #expect(form.canContinue)
  #expect(form.submission == [
    QuestionAnswer(questionId: "q1", selectedLabel: "B"),
    QuestionAnswer(questionId: "q2", freeText: "Dom"),
  ])
}

@Test func selectionAndFreeTextReplaceEachOther() throws {
  var form = QuestionForm(try question(mode: "single"))
  form.choose("A", in: "q1")
  form.write("Other", in: "q1")
  #expect(!form.isChosen("A", in: "q1"))
  #expect(form.freeText(in: "q1") == "Other")
  form.choose("C", in: "q1")
  #expect(form.freeText(in: "q1") == "")
  #expect(form.isChosen("C", in: "q1"))
}

@Test func multipleChoiceRespectsMinAndMax() throws {
  var form = QuestionForm(try question(mode: "multiple", min: 2, max: 2))
  form.write("Dom", in: "q2")
  form.choose("A", in: "q1")
  #expect(!form.canContinue)
  form.choose("B", in: "q1")
  #expect(form.canContinue)
  form.choose("C", in: "q1")
  #expect(!form.canContinue)
  form.choose("C", in: "q1")
  #expect(form.canContinue)
  #expect(form.submission.first == QuestionAnswer(questionId: "q1", selectedLabels: ["A", "B"]))
  // As Electron: with a minimum of 0, any answer to a multiple-choice prompt counts, even blank text.
  var optional = QuestionForm(try question(mode: "multiple", min: 0))
  optional.write("Dom", in: "q2")
  #expect(!optional.canContinue)
  optional.write("", in: "q1")
  #expect(optional.canContinue)
}

@Test func freeTextStopsAt500Characters() throws {
  var form = QuestionForm(try question(mode: "single"))
  form.write(String(repeating: "x", count: 600), in: "q2")
  #expect(form.freeText(in: "q2").count == 500)
}

@Test func approvalButtonsFollowElectron() throws {
  let json = #"""
    [{"choiceId":"c1","label":"Allow once","decision":"approved","scope":"once"},
     {"choiceId":"c2","label":"Always","decision":"approvedForSession","scope":"localPersistent","rulePreview":"Allow rm"},
     {"choiceId":"c3","label":"Deny","decision":"denied","scope":"session"},
     {"choiceId":"c4","label":"Policy","decision":"approved","scope":"policy"}]
    """#
  let choices = try JSONDecoder().decode([Approval.Choice].self, from: Data(json.utf8))
  #expect(choices.map(ApprovalPresentation.isPrimary) == [true, true, false, true])
  #expect(choices.map(ApprovalPresentation.savesRule) == [false, true, false, false])
  #expect(choices.map(ApprovalPresentation.help) == [
    "Applies once", "Allow rm", "Applies for this session", "Applies as a saved policy",
  ])
}

@Test func theApprovalSubjectPrefersTheCommand() throws {
  let json = #"{"approvalId":"a","sessionId":"s","toolName":"shell","rawArgs":"raw","subject":{"kind":"path","path":"/etc/hosts"},"availableChoices":[]}"#
  let approval = try JSONDecoder().decode(Approval.self, from: Data(json.utf8))
  #expect(ApprovalPresentation.subject(approval) == "/etc/hosts")
  #expect(ApprovalPresentation.heading(approval) == "Muse would like permission to use shell.")
}
