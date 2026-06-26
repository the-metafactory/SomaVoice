# Ivy Voice (prototype)

A macOS menu-bar app for having an actual spoken conversation with **Ivy** (and
other cortex assistants). Push-to-talk in, voice out — with the assistant's real
personality and skills, because the brain is a live Claude Code session.

## How it works

```
mic ──▶ Apple Speech (on-device STT) ──▶ text
                                          │
                                          ▼
                          claude CLI  (cwd = ~/.claude)
                    └─ loads PAI config: Ivy identity + all skills
                    └─ --resume <session> for per-persona memory
                                          │
                          reply text ◀────┘
                                          │
                                          ▼
                     ElevenLabs TTS (persona voice) ──▶ speaker
```

Four selectable brains (toggle in the UI):

- **pi.dev lean (Soma Ivy)** — `PiBrain`. Spawns the `pi` agent stripped to a
  minimal context (`-ne -ns -nc -nt --thinking off`) with Soma-Ivy's identity
  injected as *static system text* from `~/.soma/profile/*.md` — not the heavy
  live soma extension. Still the Soma projection of Ivy, but **~1.5-3s warm**
  (vs ~11.7s for full pi). Pre-warmed at launch to absorb pi's cold start.
  Memory via per-persona `--session-id`. Routes to any provider (OpenRouter,
  local Ollama, Codex); no extra key. Validated: identity + memory + latency.
- **Fast (Anthropic)** — `ApiBrain`, raw Messages API (Haiku), prompt-cached
  system prompt. ~1-3s/turn. Personality only, no skills. Needs
  `ANTHROPIC_API_KEY`.
- **OpenRouter** — `OpenRouterBrain`, OpenAI-compatible, any model behind one
  key. ~1-3s/turn. Personality only. Needs `OPENROUTER_API_KEY`.
- **Skilled (PAI)** — `WarmBrain`, a resident `claude` session. Full Claude Code
  skills + personality, subscription auth (no key). ~20s/turn — see latency note.

Other choices:

- **STT = Apple Speech, on-device.** Audio never leaves the machine (privacy),
  no cloud API scope. Requires macOS Dictation enabled (an MDM policy can
  disable it; a local whisper.cpp fallback is the alternative — not yet wired).
- **TTS = ElevenLabs** (`eleven_turbo_v2_5`) in the persona's voice — Ivy uses
  the voice id from `~/.env`.
- **Pull, not push.** It only ever speaks in reply to you. Push-to-talk; talk
  again to interrupt (barge-in stops playback immediately).

## Prerequisites

- macOS 14+, Swift 6 toolchain (Command Line Tools are enough).
- `claude` CLI installed and logged in.
- `~/.env` with:
  ```
  ELEVENLABS_API_KEY=...
  ELEVENLABS_VOICE_ID=...        # Ivy's voice
  ```

## Build & run

```bash
./make-app.sh        # builds release + assembles IvyVoice.app + ad-hoc signs
open IvyVoice.app    # waveform icon appears in the menu bar
```

First launch prompts for **Microphone** and **Speech Recognition** permission —
grant both. Click the menu-bar icon, pick a persona, then **Talk** (or press
**Space**), speak, and **Stop & Send**.

## The latency finding (why two brains)

Measured on this machine:

| Path | Per-turn latency |
|------|------------------|
| `claude -p` cold (fresh process) | ~24-26s |
| `claude` warm streaming, turn 2/3 | ~20s |
| Same, with `--model haiku` | no better |

The ~20s is **not** process startup — a warm resident session still pays it
every turn. The global `~/.claude` config (large CLAUDE.md, SessionStart +
prompt-classifier hooks, MCP servers, skill discovery) loads on *every* `claude`
invocation, regardless of model or cwd. A model swap or warm process can't escape
it. So the CLI can't be a snappy voice loop.

The fix is to bypass the CLI harness entirely for conversation: hit a chat API
directly (no hooks, no MCP, no skill discovery). That's the **Fast** brain. The
**Skilled** brain keeps the full `claude` session for when you actually want
skills and can tolerate the wait — or dispatch that work async to Cortex.

## Known limitations (prototype)

- Fast brain needs `ANTHROPIC_API_KEY` in `~/.env` (separate from the
  subscription the CLI uses). Until added, use the Skilled toggle.
- Fast brain has no Claude Code skills — personality only. Skill work belongs on
  the Skilled brain or an async Cortex dispatch.
- Push-to-talk is in-window (menu-bar popover). A true global hotkey needs
  Accessibility permission — not wired yet.
- "Others" ships with Ivy + Echo; Echo uses an ElevenLabs preset voice. Swap in
  the real cortex assistant voices and wire persona → cortex dispatch later.
- STT needs macOS Dictation enabled. A local whisper.cpp fallback (you already
  have `whisper` + ggml models installed) would remove that dependency.

## Next steps

- Stream API replies sentence-by-sentence into TTS for lower perceived latency.
- Persona → Cortex dispatch envelope when a turn produces real work.
- Global push-to-talk hotkey; earcons for listening/thinking states.
- whisper.cpp STT fallback (no Dictation dependency, fully local).
