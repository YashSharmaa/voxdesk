#!/bin/bash
# Writes test clips for `VoxDesk --transcribe` into a folder (default: .build/test-audio).
# Uses `say -o` (writes a file, plays nothing) and ffmpeg for silence and noise.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-.build/test-audio}"
mkdir -p "$out"
fmt=(--file-format=WAVE --data-format=LEI16@16000)

say -v Samantha "${fmt[@]}" -o "$out/tech.wav" \
  "Run pnpm install, then push the TypeScript fix to GitHub and check the Postgres logs in Docker. \
Ask Claude to call the OpenAI API from the CLI, and send the result to Telegram and iMessage."

say -v Samantha -r 200 "${fmt[@]}" -o "$out/paragraph15.wav" \
  "This morning I refactored the authentication module so that every request goes through one middleware. \
The old code checked tokens in three different places, which made bugs hard to find. \
Next, I will write tests for the expired token case, update the README, and open a pull request for review."

# The same paragraph with the short pauses people leave between sentences (450 ms).
say -v Samantha -r 200 "${fmt[@]}" -o "$out/paragraph15_pauses.wav" \
  "This morning I refactored the authentication module so that every request goes through one middleware. [[slnc 450]] \
The old code checked tokens in three different places, which made bugs hard to find. [[slnc 450]] \
Next, I will write tests for the expired token case, update the README, and open a pull request for review."

say -v Rishi "${fmt[@]}" -o "$out/tech_en_in.wav" \
  "Please run npm test, fix the JavaScript and Python errors, and deploy the Docker image with the new API key."

if say -v '?' | grep -q '^Lekha'; then
  say -v Lekha "${fmt[@]}" -o "$out/hindi.wav" "नमस्ते, आज हम नया फ़ीचर बनाएंगे और कल उसे रिलीज़ करेंगे।"
  say -v Lekha "${fmt[@]}" -o "$out/hinglish.wav" "भाई, कल तक ये API endpoint deploy कर देना, और GitHub पे PR भी खोल देना।"
fi
say -v Rishi "${fmt[@]}" -o "$out/hinglish_roman.wav" "Bhai, kal tak yeh API endpoint deploy kar dena, aur GitHub pe PR bhi khol dena."

# Short replies, and speech followed by silence and by noise (trimming and gating mid-clip).
say -v Samantha "${fmt[@]}" -o "$out/short_yes.wav" "Yes."
say -v Samantha "${fmt[@]}" -o "$out/short_ship.wav" "Ship it."
ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -c:a pcm_s16le "$out/silence.wav"
ffmpeg -loglevel error -y -f lavfi -i "anoisesrc=d=3:c=white:r=16000:a=0.05" -c:a pcm_s16le "$out/noise_white.wav"
ffmpeg -loglevel error -y -f lavfi -i "anoisesrc=d=3:c=pink:r=16000:a=0.2" -c:a pcm_s16le "$out/noise_pink.wav"
ffmpeg -loglevel error -y -f lavfi -i "anoisesrc=d=3:c=brown:r=16000:a=0.3" -c:a pcm_s16le "$out/noise_brown.wav"
ffmpeg -loglevel error -y -i "$out/short_ship.wav" -f lavfi -t 4 -i anullsrc=r=16000:cl=mono \
  -filter_complex "[0][1]concat=n=2:v=0:a=1" -c:a pcm_s16le "$out/ship_then_silence.wav"
ffmpeg -loglevel error -y -i "$out/noise_pink.wav" -i "$out/short_ship.wav" -i "$out/noise_pink.wav" \
  -filter_complex "[0][1][2]concat=n=3:v=0:a=1" -c:a pcm_s16le "$out/noise_ship_noise.wav"
# The same tech sentence as AAC in .m4a, to exercise the compressed-file path.
ffmpeg -loglevel error -y -i "$out/tech.wav" -c:a aac -b:a 96k "$out/tech.m4a"

for f in "$out"/*; do
  printf '%-22s %6.2fs\n' "$(basename "$f")" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")"
done
