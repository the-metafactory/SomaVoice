#!/usr/bin/env bash
# Proves the chain works without the GUI/mic: pi (Soma Ivy) -> ElevenLabs TTS -> speaker.
# Usage: ./smoke.sh "your text here"
set -euo pipefail
cd "$(dirname "$0")"
set -a; . "$HOME/.env"; set +a
TXT="${1:-Hi Jens-Christian, this is a smoke test. If you hear this, the chain works.}"

echo "[1/3] pi (Soma Ivy) thinking..."
t0=$(python3 -c 'import time;print(time.time())')
REPLY=$(pi -p --mode json --session-id ivy-voice-smoke "$TXT" 2>/dev/null | python3 -c "
import sys,json
last=''
for l in sys.stdin:
    try: ev=json.loads(l)
    except: continue
    if ev.get('type')=='message_end' and ev.get('message',{}).get('role')=='assistant':
        last=''.join(b.get('text','') for b in ev['message'].get('content',[]) if b.get('type')=='text')
print(last.strip())")
echo "      ($(python3 -c "print(f'{$(python3 -c 'import time;print(time.time())')-$t0:.1f}s')")) Ivy: $REPLY"

echo "[2/3] ElevenLabs TTS..."
REPLY="$REPLY" python3 -c "import json,os;open('/tmp/ivy_body.json','w').write(json.dumps({'text':os.environ['REPLY'],'model_id':'eleven_turbo_v2_5'}))"
code=$(curl -s -o /tmp/ivy_smoke.mp3 -w "%{http_code}" -X POST \
  "https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_VOICE_ID}" \
  -H "xi-api-key: ${ELEVENLABS_API_KEY}" -H "Content-Type: application/json" \
  -d @/tmp/ivy_body.json)
echo "      http=$code bytes=$(wc -c </tmp/ivy_smoke.mp3 | tr -d ' ')"

echo "[3/3] playing..."
afplay /tmp/ivy_smoke.mp3
echo "OK — if you heard Ivy speak, the brain+voice chain works."
