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

Five selectable brains (toggle in the UI):

- **Router (fast + deep)** — `RouterBrain`, default. One Ivy, two speeds. A fast
  OpenRouter model answers directly (~2s) and routes itself via tools: `recall`
  (fast read-only memory grep over `~/.claude` + Soma, returned inline) and
  `delegate` (hand off to deep Ivy — full pi with skills/tools/memory). On
  delegate it speaks a short bridge ("let me look into that") so the voice never
  goes silent during the slow deep turn. System 1 / System 2. Needs
  `OPENROUTER_API_KEY`. Validated: direct/recall/delegate routing + recall
  round-trip.
  - **Deep substrate is selectable** (picker, shown when Router is active):
    **pi.dev** (`PiBrain` full), **Codex** (`codex exec`, read-only sandbox), or
    **Claude Code** (`WarmBrain`, full PAI skills). Soma projects Ivy into all
    three. Note: Codex runs read-only-sandboxed, so it reads files/memory but
    network tasks (email/calendar) won't run there — use pi.dev or Claude Code
    for those.
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

- **Deep turns are slow** (~60–90s): when the router delegates a skill task
  (email, calendar), deep pi explores the skill step-by-step from a cold spawn.
  Not a hang — the app speaks a bridge then reassures every ~22s while it works,
  and a watchdog caps it. Repeat calls in the same session are faster (skill
  already loaded). Future: warm/persistent deep session, or stream pi's progress
  to voice.
- Fast brain needs `ANTHROPIC_API_KEY` in `~/.env` (separate from the
  subscription the CLI uses). Until added, use the Skilled toggle.
- Fast brain has no Claude Code skills — personality only. Skill work belongs on
  the Skilled brain or an async Cortex dispatch.
- **Tap ⌃⌥ (Control+Option) anywhere to start/stop a hands-free conversation** —
  Ivy listens, VAD ends each utterance on a ~1.2s pause, she responds, then
  auto-listens for the next turn until you tap ⌃⌥ again. Plus Talk / Space inside
  the popover for a single turn. The global hotkey needs **Accessibility
  permission** (System Settings → Privacy & Security → Accessibility → enable
  IvyVoice); the app prompts on first launch.
- VAD thresholds (speech > −30 dBFS, 1.2s silence to end, 15s max) are starting
  values — may need tuning to your mic/room.
- "Others" ships with Ivy + Echo; Echo uses an ElevenLabs preset voice. Swap in
  the real cortex assistant voices and wire persona → cortex dispatch later.
- STT needs macOS Dictation enabled. A local whisper.cpp fallback (you already
  have `whisper` + ggml models installed) would remove that dependency.

## Next steps

- Stream API replies sentence-by-sentence into TTS for lower perceived latency.
- Persona → Cortex dispatch envelope when a turn produces real work.
- Earcons for listening/thinking states; configurable hotkey binding.
- whisper.cpp STT fallback (no Dictation dependency, fully local).
