import Foundation
import LighttyCore
import Testing

struct AgentHookEventTests {
    private func decode(_ fields: [String: Any]) throws -> AgentHookEvent? {
        AgentHookEvent(try JSONSerialization.data(withJSONObject: fields))
    }

    /// 合成载荷：可选字段坏了不能吞掉有效的状态；新增字段也不能影响已有语义。
    @Test func optionalFieldsAreIndependentOfTheLifecycleEvent() throws {
        let cases: [(String, [String: Any], PaneActivity?)] = [
            ("SessionStart", [:], .idle), ("SessionEnd", [:], .idle),
            ("UserPromptSubmit", [:], .thinking), ("PreToolUse", [:], .tool),
            ("PostToolUse", [:], .thinking), ("Stop", [:], .done),
            ("Interrupt", [:], .idle), ("PermissionRequest", [:], .attention),
            ("PostToolUseFailure", ["is_interrupt": true], .idle),
            ("PostToolUseFailure", ["is_interrupt": "unknown"], .thinking),
            ("Notification", ["notification_type": "idle_prompt"], nil),
            ("Notification", ["notification_type": "future_intervention"], .attention),
            ("FutureEvent", [:], nil),
        ]
        for (name, extra, activity) in cases {
            var wire: [String: Any] = ["hook_event_name": name, "session_id": 42,
                "tool_name": [], "tool_input": "unexpected", "cwd": NSNull(),
                "transcript_path": true, "futureField": ["anything": "ignored"]]
            wire.merge(extra) { _, new in new }
            let event = try decode(wire)
            #expect(event?.activity == activity, "\(name)")
            #expect(event?.sessionID == nil)
            #expect(event?.tool == nil)
            #expect(event?.detail == nil)
            #expect(event?.workingDirectory == nil)
            #expect(event?.transcriptPath == nil)
        }
        for text in ["", "{broken", "[]", "null", #"{"hook_event_name":123}"#, #"{"hook_event_name":"  "}"#] {
            #expect(AgentHookEvent(Data(text.utf8)) == nil)
        }
    }

    @Test func toolDetailsAndTranscriptPathsRespectWireLimits() throws {
        let id = UUID().uuidString
        let longPath = "/tmp/" + String(repeating: "目录", count: 190) + "/.codex/sessions/rollout.jsonl"
        var wire: [String: Any] = ["hook_event_name": " PreToolUse\n", "session_id": " \(id)\n",
            "tool_name": " Edit ", "cwd": " /work ", "transcript_path": longPath,
            "tool_input": ["file_path": " \(longPath) ", "command": "not the chosen field"]]
        let event = try #require(try decode(wire))
        #expect(event.name == "PreToolUse")
        #expect(event.sessionID == id)
        #expect(event.tool == "Edit")
        #expect(event.workingDirectory == "/work")
        #expect(event.detail == "…" + String(longPath.suffix(79)))
        #expect(event.transcriptPath == nil, "Byte limit, not character count")
        #expect(event.inferredAgent(environment: [:]) == "codex", "Detection still uses the original path")
        for size in [1024, 1025] {
            wire["transcript_path"] = String(repeating: "a", count: size)
            #expect(try decode(wire)?.transcriptPath?.utf8.count == (size == 1024 ? 1024 : nil))
        }
        wire["tool_input"] = ["file_path": " \n", "command": "first\nsecond"]
        #expect(try decode(wire)?.detail == "first second")
        wire["tool_input"] = ["command": String(repeating: "🙂", count: 100)]
        #expect(try decode(wire)?.detail == String(repeating: "🙂", count: 79) + "…")
        wire["hook_event_name"] = "PostToolUse"
        #expect(try decode(wire)?.detail == nil, "Tool completion must not repeat its input")
    }

    @Test func contextReplyPreservesTheDocumentAndEventName() throws {
        let body = "# 交接\n\"quotes\" \\path\t🙂\u{0}"
        for name in ["SessionStart", "UserPromptSubmit"] {
            let event = try #require(try decode(["hook_event_name": name]))
            let output = try event.contextOutput(body)
            let envelope = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
            let specific = try #require(envelope["hookSpecificOutput"] as? [String: String])
            #expect(specific == ["hookEventName": name, "additionalContext": body])
            #expect(envelope.count == 1)
        }
    }
}
