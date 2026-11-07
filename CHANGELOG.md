# Changelog

## 1.0.0

First public release.

- Fast English engine: Parakeet TDT 0.6B v2 through FluidAudio 0.18.2, the default. Text appears about
  0.15 s after the key is released (Whisper took about 1.0 s). The vocabulary list is applied as Parakeet
  keyword boosting (Parakeet CTC 110M) plus a spelling pass.
- Multilingual engine: Whisper large-v3-turbo through WhisperKit 1.1.1, for Hindi and Hinglish.
- Engine setting in the menu and the settings window; only the selected engine is loaded and kept warm.
- Hold-to-talk or tap-to-toggle shortcut, Right Option trigger, live overlay, clipboard-restoring paste.
- Silence and noise paste nothing (energy gate, Silero VAD, stock-phrase filter).
- Launch at login.
- `VoxDesk --version`, `--transcribe` (with `--engine`), `--self-test`.
- install.sh and a Homebrew formula.
