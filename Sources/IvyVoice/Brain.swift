import Foundation

/// Two brains, same interface, deliberately different tradeoffs:
///
/// - `ApiBrain` (fast): raw Anthropic Messages API. No CLI, no PAI hooks, no MCP,
///   no skill discovery — so it's 1-3s/turn instead of ~20s. Keeps Ivy's
///   personality (system prompt) but NOT Claude Code skills.
/// - `WarmBrain` (skilled): the real `claude` session — full skills + personality,
///   but ~20s/turn because the whole PAI harness loads on every turn.
///
/// The design-doc split: conversational turns go to the fast brain; when a turn
/// needs real skill work, dispatch it async to the skilled brain (or Cortex),
/// where the latency doesn't break the conversation.
protocol Brain: AnyObject {
    func ask(_ text: String, persona: Persona) async throws -> String
    func warmUp(_ persona: Persona)
}

extension WarmBrain: Brain {}
