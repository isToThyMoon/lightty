import LighttyCore
import Testing

struct AgentDiagnosticTests {
    /// 诊断的公开标识必须跨进程一致，异常字段不能变成任意正文输出通道。
    @Test func publicFieldsAreValidatedAndSessionIDsAreCanonical() {
        let id = "01a0d992-037e-7f10-8aaa-9452ab2e0c3c"
        let hook = AgentDiagnostic(.hookSend, .sent, agent: .codex, session: id, hook: "Stop")
        let received = AgentDiagnostic(.statusIngest, .accepted, agent: .codex, session: id.uppercased())
        #expect(hook.sessionIdentifier == received.sessionIdentifier)
        #expect(hook.sessionIdentifier == id.uppercased())
        #expect(hook.hook == "Stop")
        for value in ["", "/private/task.md", "a prompt\nwith content", id + " extra"] {
            let invalid = AgentDiagnostic(.hookRoute, .missingRoute, session: value, hook: value)
            #expect(invalid.sessionIdentifier == nil)
            #expect(invalid.hook == nil)
        }
    }
}
