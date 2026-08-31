import XCTest
@testable import Plyph

final class AskRequestTests: XCTestCase {
    func testSystemPromptDefinesAskBehavior() {
        XCTAssertTrue(AskRequest.systemPrompt.contains("provided context"))
        XCTAssertTrue(AskRequest.systemPrompt.contains("natural reply"))
        XCTAssertTrue(AskRequest.systemPrompt.contains("appropriate language"))
        XCTAssertTrue(AskRequest.systemPrompt.contains("only the useful requested output"))
    }

    func testUserMessageKeepsContextAndInstructionSeparate() {
        let message = AskRequest.userMessage(
            context: "Könnten Sie morgen gegen 14 Uhr vorbeikommen?",
            instruction: "reply that 14 is too early and ask if 16 works")

        XCTAssertTrue(
            message.contains(
                "<context>\nKönnten Sie morgen gegen 14 Uhr vorbeikommen?\n</context>"))
        XCTAssertTrue(
            message.contains(
                "<instruction>\nreply that 14 is too early and ask if 16 works\n</instruction>"))
    }

    func testFollowUpMessageIncludesContextHistoryAndNewInstruction() {
        let message = AskRequest.followUpMessage(
            context: "A meeting request for 14:00.",
            turns: [
                AskConversationTurn(
                    question: "Write a polite reply.",
                    response: "Thank you. Could we meet at 16:00 instead?")
            ],
            instruction: "Make it shorter.")

        XCTAssertTrue(message.contains("<context>\nA meeting request for 14:00.\n</context>"))
        XCTAssertTrue(message.contains("<user>Write a polite reply.</user>"))
        XCTAssertTrue(
            message.contains(
                "<assistant>Thank you. Could we meet at 16:00 instead?</assistant>"))
        XCTAssertTrue(message.contains("<instruction>\nMake it shorter.\n</instruction>"))
        XCTAssertTrue(message.contains("Return only the new response."))
    }
}
