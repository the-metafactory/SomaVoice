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

Design choices (see the voice design doc):

- **Brain = the real `claude` CLI**, run from `~/.claude`. That's how Ivy's
  personality and every skill come through for free — we don't reimplement them.
  Continuity via `claude --resume <session_id>`, one session per persona.
- **STT = Apple Speech, on-device.** Audio never leaves the machine (privacy),
  and it needs no extra cloud API scope.
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

## Known limitations (prototype)

- **First-turn latency is high.** `claude --resume` spawns a fresh process and
  reloads the session + MCP/skills each turn — measured ttft ~20s on a cold
  start in this PAI setup. This is the documented tradeoff: we chose
  personality + skills over a warm low-latency loop. The warm path (Anthropic
  Messages API directly, prompt-cached, for the conversational turn) is the next
  step — keep the CLI brain for the *work* path only.
- Push-to-talk is in-window (menu-bar popover). A true global hotkey needs
  Accessibility permission — not wired yet.
- "Others" ships with Ivy + Echo; Echo uses an ElevenLabs preset voice. Swap in
  the real cortex assistant voices and wire persona → cortex dispatch later.
- ElevenLabs STT was avoided: the current key lacks the `speech_to_text` scope.
  Apple Speech replaced it (and is the better local-first choice anyway).

## Next steps

- Warm conversational brain via Messages API + prompt caching.
- Persona → cortex dispatch envelope when a turn produces real work.
- Global push-to-talk hotkey; earcons for listening/thinking states.
