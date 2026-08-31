import Foundation

struct AskConversationTurn: Equatable {
    let question: String
    let response: String
}

/// Builds the instruction-mode request used by the built-in Ask action.
/// Networking, provider selection, model selection, limits, and response
/// handling continue to go through the existing AiClient prompt-mode path.
enum AskRequest {
    static let systemPrompt =
        "Use the provided context and the user's instruction to produce the requested response. " +
        "If the user is asking how to reply, write a natural reply in the appropriate language. " +
        "Return only the useful requested output unless the user explicitly asks for an explanation."

    static func userMessage(context: String, instruction: String) -> String {
        """
        Context:
        <context>
        \(context)
        </context>

        User instruction:
        <instruction>
        \(instruction)
        </instruction>
        """
    }

    static func followUpMessage(
        context: String,
        turns: [AskConversationTurn],
        instruction: String
    ) -> String {
        let conversation = turns.enumerated().map { index, turn in
            """
            <turn number="\(index + 1)">
            <user>\(turn.question)</user>
            <assistant>\(turn.response)</assistant>
            </turn>
            """
        }.joined(separator: "\n")

        return """
        Context:
        <context>
        \(context)
        </context>

        Conversation so far:
        <conversation>
        \(conversation)
        </conversation>

        Follow-up instruction:
        <instruction>
        \(instruction)
        </instruction>

        Respond to the follow-up using the context and conversation above.
        Return only the new response.
        """
    }
}
