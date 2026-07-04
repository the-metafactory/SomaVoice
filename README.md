# SomaVoice

A macOS menu-bar assistant you talk to out loud, and that can glance at a window on your screen when you ask. Wake word or hotkey in, spoken reply out. The default agent is Ivy; you can rename her.

It has two senses:

- Voice: a wake word ("hey ivy"), a global hotkey, or a Talk button. Speech-to-text runs on-device, replies come back through ElevenLabs, and a fast router brain either answers directly or hands off to a deeper one.
- Sight: say "watch this window", pick a window (the pick is the consent), then ask about it. One window, one glance, then it forgets. Windows you mark confidential are answered entirely on your Mac, with no network traffic.

---

## Requirements

- macOS 14 or later. macOS 26 (Tahoe) adds on-device Apple Foundation Models, which SomaVoice uses for confidential-tier reasoning. On earlier macOS, use Ollama for that path instead (see [Local reasoning](#local-reasoning-optional)).
- A Swift 6 toolchain. The Xcode Command Line Tools are enough (`xcode-select --install`).
- An ElevenLabs account for speech, and an OpenRouter key for the router brain. Everything else is optional.

---

## Setup

```bash
git clone https://github.com/the-metafactory/SomaVoice.git
cd SomaVoice
```

### 1. Add your keys

SomaVoice reads keys from `~/.env` (and `~/.zshenv`). A menu-bar app launched from Finder doesn't inherit your shell environment, so put them in `~/.env`:

```bash
# ~/.env
ELEVENLABS_API_KEY=...     # required: speech out
OPENROUTER_API_KEY=...     # required: the router brain
ELEVENLABS_VOICE_ID=...    # optional: the agent's voice (there's a fallback)
ANTHROPIC_API_KEY=...      # optional: the "Fast (Anthropic)" brain + open-tier screen vision
```

`~/.env` is git-ignored, so it never lands in the repo.

### 2. Create a signing identity

macOS ties microphone, speech, and screen permissions to the app's code signature. Keep the signature stable and you grant those once, then they survive rebuilds. Create a local self-signed identity (this needs your login-keychain password, once):

```bash
./create-signing-cert.sh     # creates a "MetaFactoryDev" code-signing cert
```

### 3. Build

```bash
./make-app.sh                # builds a release, assembles SomaVoice.app, signs it
open SomaVoice.app           # a waveform icon appears in the menu bar
```

To sign with a different identity, set `SIGN_IDENTITY=...` before running `make-app.sh`.

### 4. Grant permissions on first launch

- Microphone and Speech Recognition are prompted on first launch. Grant both.
- Screen Recording isn't needed. Sight captures through the system window picker, which authorizes each pick on its own.
- Accessibility is only for the global ⌃⌥ hotkey. It's off by default; turn it on from the menu when you want it (see [The global hotkey](#the-global-hotkey-optional)).

That's it. Click the menu-bar icon and press Talk (or Space) to say something.

---

## Configuration

Everything below is optional. SomaVoice runs on the two required keys alone, and most settings live in the menu-bar popover.

### Keys

| Key | Needed for | Required? |
|-----|-----------|-----------|
| `ELEVENLABS_API_KEY` | Speech out (TTS) | Yes |
| `OPENROUTER_API_KEY` | The router brain and its fast reflex tier | Yes |
| `ELEVENLABS_VOICE_ID` | The agent's voice | No (has a fallback) |
| `ANTHROPIC_API_KEY` | The "Fast (Anthropic)" brain and open-tier screen vision | No |
| `OPENAI_API_KEY`, `GEMINI_API_KEY` | Passed through to the deep brains if they use them | No |

### Brains

Pick a brain in the popover. Each one trades speed for depth:

- Router (fast + deep) is the default. A fast model answers directly and routes itself: `recall` for a quick memory lookup, `delegate` to hand a real task to a deeper agent. Needs `OPENROUTER_API_KEY`.
- pi.dev lean runs the `pi` agent with a light Soma-Ivy identity, warm in a couple of seconds. No extra key.
- Fast (Anthropic) hits the Messages API directly. Personality, no skills. Needs `ANTHROPIC_API_KEY`.
- OpenRouter gives you any model behind one key. Personality, no skills.
- Skilled (PAI) is a full `claude` session with all skills. Slower, and it uses your subscription.

When Router is active, a second picker chooses the deep substrate it hands off to: pi.dev, Codex, or Claude Code. The `pi`, `codex`, and `claude` CLIs need to be installed and logged in for the brains that use them.

### Speech-to-text

Apple (on-device) keeps audio on your Mac. It needs macOS Dictation enabled. EN and DE-CH run on-device; DE may fall back to server recognition. ElevenLabs (Scribe) is the cloud option: more accurate and multilingual, with about a second of network latency. The wake word always uses Apple on-device recognition.

### The agent's name and voice

Type a name in the popover to change what she calls herself and how she's labeled. The name is saved between launches. Her voice comes from `ELEVENLABS_VOICE_ID` in `~/.env`, and the wake word is set separately, so renaming her doesn't touch either.

### Wake word

Turn on the wake word and say your phrase (default "hey ivy") to start a conversation hands-free. "Learn phrase" records you saying it once and stores that as the phrase. Say "stop" or "das war's" to end a conversation.

### The global hotkey (optional)

Tapping ⌃⌥ (Control+Option) anywhere can start or stop a hands-free conversation, but that needs Accessibility permission. It's off by default and never prompts on its own. When you want it, click "Enable…" next to the hotkey hint in the popover, which asks for the grant once. Until then, use the wake word or the Talk button.

### Local reasoning (optional)

Confidential windows (see [Sight](#sight)) are answered without any network call, using a local model. On macOS 26 with Apple Intelligence enabled, that's Apple Foundation Models, with nothing to install. The fallback, and the only local option before macOS 26, is Ollama:

```bash
brew install ollama
ollama serve
ollama pull llama3.2
```

SomaVoice talks to it at `localhost:11434`. If neither is available, a confidential glance tells you so rather than reaching for the cloud.

### Voice-activity tuning

Under "VAD tuning" you can set how far above the noise floor counts as speech, the pause that ends a turn, and the maximum turn length. The defaults suit a quiet room. Adjust them for your mic.

---

## Using it

### Talking

Start a turn with the wake word, the ⌃⌥ hotkey (if you enabled it), or the Talk button (Space also works) for a single turn. The conversation is half-duplex: she answers, then listens for your next turn. Say "stop" to end.

### Sight

1. Say "watch this window." The system picker opens; click the window you want her to see. She confirms out loud.
2. Ask about it, for example "what does it say?". She captures that one window, reads it, answers, and forgets it.

A watched window is confidential by default, answered on your Mac with zero network egress. To let a window use the cloud for a better answer, enroll it with "watch this public window" (or "das darf raus").

---

## How sight stays private

Confidential windows never leave the Mac. They're read with on-device OCR and answered by a local model, so the frame and its text make no network call. Only windows you explicitly mark public may use the cloud, and those go straight to Anthropic.

You always choose what she sees. Capture is only ever the single window you pick in the system picker; there's no whole-screen capture anywhere in the app.

Nothing is written to disk. The frame lives in memory for the length of the turn, then it's gone.

And screen text can't act. Whatever she reads on screen is treated as data, not instructions, so a glance can describe something but can't trigger an action.

---

## Troubleshooting

- Mic or speech re-prompts after a rebuild. This shouldn't happen with a stable signing identity; if it does, the signature changed. Check it with `./check-tcc.sh`.
- A confidential glance says it can't answer locally. Enable Apple Intelligence (macOS 26), or run `ollama serve` with a pulled model. It won't fall back to the cloud for a confidential window.
- She doesn't speak. Check `ELEVENLABS_API_KEY`.
- The router errors out. Check `OPENROUTER_API_KEY`.
- Public-tier glances fail. Those need `ANTHROPIC_API_KEY`.

## Project layout

```
Sources/SomaVoice/     Swift sources (SomaVoiceApp entry point)
make-app.sh            build + assemble + sign SomaVoice.app
create-signing-cert.sh create the local code-signing identity
check-tcc.sh           report the app's signature and permission state
```
