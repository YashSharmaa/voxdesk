# Third-party notices

VoxDesk's own code is MIT licensed (see LICENSE). It is built with the Swift packages below, and downloads the
model weights below on first use. Licence texts are at the linked sources.

## Swift packages (compiled into the app)

| Component | Version | Use | Licence |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio), FluidInference | 0.18.2 | Parakeet speech recognition and keyword boosting on Core ML | Apache-2.0 |
| [fastcluster](https://danifold.net/fastcluster.html), Daniel Müllner and Google Inc. (bundled in FluidAudio as `FastClusterWrapper`) | as in FluidAudio 0.18.2 | Linked as part of FluidAudio; not used by VoxDesk | BSD-2-Clause |
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (argmax-oss-swift), Argmax, Inc. | 1.1.1 | Whisper speech recognition on Core ML | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser), Apple Inc. | 1.8.2 | In WhisperKit's package graph | Apache-2.0 |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), Sindre Sorhus | 3.1.0 | Global shortcut and recorder | MIT |

FluidAudio is built with its package traits turned off (`traits: []`), so its text-to-speech code and data
files, its diarization code and its prebuilt text normaliser are not part of VoxDesk. With a Swift toolchain
older than 6.2, VoxDesk builds without FluidAudio at all (Multilingual engine only).

fastcluster notice, as required by its licence:

> Copyright: Until package version 1.1.23: © 2011 Daniel Müllner. All changes from version 1.1.24 on:
> © Google Inc. All rights reserved. Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are met: (1) Redistributions of source
> code must retain the above copyright notice, this list of conditions and the following disclaimer.
> (2) Redistributions in binary form must reproduce the above copyright notice, this list of conditions and
> the following disclaimer in the documentation and/or other materials provided with the distribution.
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
> WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
> PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
> ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
> TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
> HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
> NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
> POSSIBILITY OF SUCH DAMAGE.

## Model weights (downloaded on first use, not shipped in the repository)

| Model | Source | Use | Licence |
|---|---|---|---|
| Parakeet TDT 0.6B v2, NVIDIA | [nvidia/parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2); Core ML build [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) | Fast English engine | CC-BY-4.0 |
| Parakeet TDT-CTC 110M, NVIDIA | [nvidia/parakeet-tdt_ctc-110m](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m); Core ML build [FluidInference/parakeet-ctc-110m-coreml](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml) | Vocabulary keyword boosting for Fast English | CC-BY-4.0 |
| Whisper large-v3-turbo (and small, base), OpenAI | [openai/whisper](https://github.com/openai/whisper); Core ML builds [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) | Multilingual engine | MIT |
| Silero VAD v6, Silero Team | [snakers4/silero-vad](https://github.com/snakers4/silero-vad); Core ML build [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml) | Voice activity detection | MIT |

Attribution for the CC-BY-4.0 weights: "Parakeet TDT 0.6B v2" and "Parakeet TDT-CTC 110M" by NVIDIA,
licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The Core ML conversions by
FluidInference change the format of the weights, not the model. VoxDesk shows this credit in its settings
window (About) and menu.
