import Foundation
import Testing
@testable import LighttyCore

/// 行形状照本机日志裁剪（Claude Code 2.1.310 transcript、Codex rollout，2026-10-26）。
struct TranscriptSpeedTests {
    private func samples(_ lines: [String], format: AgentSpec.TranscriptFormat) -> [TranscriptSpeedSample] {
        var parser = TranscriptSpeedParser(format: format)
        return lines.compactMap { parser.consume(Data($0.utf8)) }
    }

    private func claudeAssistant(_ id: String, _ time: String, tokens: Int, block: String = "text",
                                 text: String = "", thinking: Int? = nil, sidechain: Bool = false) -> String {
        let details = thinking.map { #","output_tokens_details":{"thinking_tokens":\#($0)}"# } ?? ""
        return #"{"type":"assistant","timestamp":"2026-10-26T06:01:\#(time)Z","isSidechain":\#(sidechain),"message":{"id":"\#(id)","model":"claude-opus-5-5","content":[{"type":"\#(block)","\#(block == "thinking" ? "thinking" : "text")":"\#(text)"}],"usage":{"input_tokens":2,"output_tokens":\#(tokens)\#(details)}}}"#
    }

    private func claudeRequest(_ time: String, source: String = "repl_main_thread") -> String {
        #"{"type":"api-request","timestamp":"2026-10-26T06:01:\#(time)Z","querySource":"\#(source)","params":{"model":"claude-opus-5-5"}}"#
    }

    private func claudeUser(_ time: String) -> String {
        #"{"type":"user","timestamp":"2026-10-26T06:01:\#(time)Z","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","content":"\"type\":\"assistant\" in tool output"}]}}"#
    }

    @Test func claudeMeasuresFromRequestToLastBlockOfTheMessage() {
        let found = samples([
            claudeUser("20.000"),
            claudeRequest("20.100"),
            // A side request (title generation) is not the turn's request start.
            claudeRequest("21.000", source: "generate_session_title"),
            // Thinking text and tool input are not visible output; only text blocks count.
            claudeAssistant("msg_1", "24.100", tokens: 400, block: "thinking", text: "hidden", thinking: 120),
            claudeAssistant("msg_1", "24.600", tokens: 400, text: "主动型 Agent", thinking: 120),
            claudeAssistant("msg_1", "25.100", tokens: 400, block: "tool_use", thinking: 120),
            // Subagent lines belong to another conversation.
            claudeAssistant("msg_side", "25.500", tokens: 900, sidechain: true),
            claudeUser("25.200"),
            claudeRequest("25.300"),
            claudeAssistant("msg_2", "27.300", tokens: 100),
        ], format: .claudeTranscript)
        #expect(found.map(\.id) == ["msg_1", "msg_1", "msg_1", "msg_2"])
        #expect(found.map(\.outputTokens) == [400, 400, 400, 100])
        #expect(found.map(\.reasoningTokens) == [120, 120, 120, nil])
        // Characters accumulate across one message's blocks, then restart with the next message.
        #expect(found.map(\.visibleCharacters) == [0, 9, 9, 0])
        #expect(abs(found[2].duration - 5.0) < 0.001)
        #expect(abs(found[3].duration - 2.0) < 0.001)
    }

    @Test func claudeWithoutRequestRecordsFallsBackToTheLastUserEntry() {
        let found = samples([claudeUser("10.000"), claudeAssistant("msg", "12.500", tokens: 250)],
                            format: .claudeTranscript)
        #expect(found.count == 1)
        #expect(abs((found.first?.duration ?? 0) - 2.5) < 0.001)
    }

    @Test func startingMidFileDropsTheRequestWithoutAKnownStart() {
        #expect(samples([claudeAssistant("msg", "12.500", tokens: 250)], format: .claudeTranscript).isEmpty)
        #expect(samples([codex("03:26:56.041", "token_usage_record", usage: 138)], format: .codexRollout).isEmpty)
    }

    private func codex(_ time: String, _ type: String, payload: String? = nil, usage: Int? = nil,
                       reasoning: Int = 0) -> String {
        let body = usage.map { #"{"usage":{"input_tokens":20255,"output_tokens":\#($0),"reasoning_output_tokens":\#(reasoning)}}"# }
            ?? payload ?? "{}"
        return #"{"timestamp":"2026-10-26T\#(time)Z","type":"\#(type)","payload":\#(body)}"#
    }

    @Test func codexMeasuresFromTheLatestInputBoundaryToTheUsageRecord() {
        let found = samples([
            codex("03:26:46.724", "event_msg", payload: #"{"type":"task_started"}"#),
            codex("03:26:49.094", "response_item", payload: #"{"type":"message","role":"user"}"#),
            // The response's own items are output, not a new start.
            codex("03:26:54.488", "response_item",
                  payload: #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"先看日志"}]}"#),
            codex("03:26:55.921", "response_item", payload: #"{"type":"custom_tool_call"}"#),
            codex("03:26:56.041", "token_usage_record", usage: 138),
            codex("03:26:56.042", "response_item", payload: #"{"type":"custom_tool_call_output"}"#),
            codex("03:26:58.812", "response_item", payload: #"{"type":"reasoning"}"#),
            // Codex runs tools before the response closes: an output that lands before the
            // record neither starts the next request nor drops this request's text.
            codex("03:27:00.000", "response_item",
                  payload: #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}"#),
            codex("03:27:00.100", "response_item", payload: #"{"type":"custom_tool_call_output"}"#),
            codex("03:27:01.611", "token_usage_record", usage: 130, reasoning: 9),
            // A tool output that lands after the record still starts the next request.
            codex("03:27:04.321", "response_item", payload: #"{"type":"function_call_output"}"#),
            codex("03:27:08.813", "token_usage_record", usage: 73),
        ], format: .codexRollout)
        #expect(found.map(\.outputTokens) == [138, 130, 73])
        #expect(found.map(\.reasoningTokens) == [0, 9, 0])
        #expect(found.map(\.visibleCharacters) == [4, 2, 0])
        let durations = found.map { ($0.duration * 1000).rounded() / 1000 }
        #expect(durations == [6.947, 5.569, 4.492])
        #expect(Set(found.map(\.id)).count == 3)
    }

    @Test func windowAddsUpRecentRequestsAndIgnoresTinyOnes() {
        let start = Date(timeIntervalSince1970: 0)
        func sample(_ id: String, _ tokens: Int, _ seconds: TimeInterval) -> TranscriptSpeedSample {
            TranscriptSpeedSample(id: id, outputTokens: tokens, start: start, end: start.addingTimeInterval(seconds))
        }
        var window = TranscriptSpeedWindow()
        #expect(window.tokensPerSecond == nil)
        window.record(sample("a", 400, 4))
        // The same message reported again (one line per content block) replaces, not doubles.
        window.record(sample("a", 400, 5))
        window.record(sample("tiny", 8, 2))
        window.record(sample("b", 600, 5))
        #expect(window.tokensPerSecond == 100)
        for index in 0..<TranscriptSpeedWindow.capacity { window.record(sample("c\(index)", 300, 10)) }
        #expect(window.samples.count == TranscriptSpeedWindow.capacity)
        #expect(window.tokensPerSecond == 30)
        #expect(window.charactersPerSecond == nil)
        // Tool-only requests have no text and stay out of the character rate.
        window.record(TranscriptSpeedSample(id: "text", outputTokens: 300, visibleCharacters: 500,
                                            start: start, end: start.addingTimeInterval(5)))
        #expect(window.charactersPerSecond == 100)
    }

    @Test func tailReadsOnlyCompleteAppendedLinesAndRestartsAfterTruncation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = TranscriptTail(url: url)
        #expect(tail.readLines().isEmpty)
        try Data("one\ntw".utf8).write(to: url)
        #expect(tail.readLines() == [Data("one".utf8)])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("o\nthree\n".utf8))
        try handle.close()
        #expect(tail.readLines() == [Data("two".utf8), Data("three".utf8)])
        #expect(tail.readLines().isEmpty)
        try Data("new\n".utf8).write(to: url)
        #expect(tail.readLines() == [Data("new".utf8)])
    }

    @Test func tailStartsLargeFilesAtALineBoundaryNearTheEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: "x", count: Int(TranscriptTail.bootstrapBytes) + 10)
        try Data("\(filler)\nlast\n".utf8).write(to: url)
        #expect(TranscriptTail(url: url).readLines() == [Data("last".utf8)])
    }
}
