# Third-party notices

Meeting Transcriber itself is MIT licensed (see `LICENSE`).

**Scope:** this file covers every third-party component redistributed in the
shipped application, whether statically linked into the app binary or bundled as
a data resource. The licence text of each ships inside the app at
`Contents/Resources/licenses/`, and the same files are kept in this repository
under `licenses/`.

Not covered, because they are not redistributed: dependencies used only to build
the app (`swift-syntax`, which runs as a compiler macro plugin) and dependencies
used only to run its tests (ViewInspector, swift-snapshot-testing,
swift-custom-dump, xctest-dynamic-overlay). `swift-argument-parser` is likewise
absent, since it is linked only into `tools/mt-cli`, a developer client that is
not part of the `.app`. `AudioTapLib` is first-party code in this repository
(`tools/audiotap`), not a third-party component.

## WhisperKit

Speech recognition (the default transcription engine), statically linked into
the app binary.

- **Project:** <https://github.com/argmaxinc/WhisperKit>
- **Version:** 1.1.0, pinned in `app/MeetingTranscriber/Package.resolved`
- **Copyright:** Copyright (c) 2024 argmax, inc.
- **License:** MIT. MIT requires the copyright notice and permission notice in
  all copies, and a binary is a copy, so the text ships as
  `Contents/Resources/licenses/WhisperKit-LICENSE.txt`.

WhisperKit is MIT licensed but incorporates Apache-2.0 code, and discharges that
obligation through a `NOTICES` file rather than by restating the terms in its
own licence. Section 4d of Apache-2.0 requires that a NOTICE travelling with a
work be propagated by anyone who redistributes it, so that file ships unmodified
as `Contents/Resources/licenses/WhisperKit-NOTICES.txt`. It attributes portions
derived from swift-transformers (<https://github.com/huggingface/swift-transformers>,
Copyright 2022 Hugging Face SAS) and carries the full Apache-2.0 text those
portions are licensed under.

## FluidAudio

Speaker diarization, voice activity detection, speaker embeddings and the
Parakeet and Nemotron live-caption engines, statically linked into the app
binary.

- **Project:** <https://github.com/FluidInference/FluidAudio>
- **Version:** 0.15.6, pinned in `app/MeetingTranscriber/Package.resolved`
- **Copyright:** the upstream `LICENSE` is the unmodified Apache-2.0 text with
  the boilerplate `Copyright [yyyy] [name of copyright owner]` line left as
  written, so it names no holder. The project is published by FluidInference.
- **License:** Apache License 2.0. Section 4a requires a copy of the License
  with any redistribution, so the text ships as
  `Contents/Resources/licenses/FluidAudio-LICENSE.txt`. Upstream carries no
  NOTICE file, so section 4d imposes nothing further here.

FluidAudio vendors third-party code of its own, which this app therefore
redistributes as well, so those notices ship too:

- **fastcluster** (<https://github.com/fastcluster/fastcluster>), BSD-2-Clause,
  © 2011 Daniel Müllner and, from version 1.1.24 on, © Google Inc. Upstream C++
  source sits in FluidAudio's `Sources/FastClusterWrapper`, a target the
  `FluidAudio` library depends on directly, so it is compiled into the app
  binary. BSD-2-Clause requires binary redistributions to reproduce the
  copyright notice in the materials accompanying the distribution, which is what
  `Contents/Resources/licenses/FluidAudio-fastcluster-LICENSE.txt` is.
- **VBx** (<https://github.com/BUTSpeechFIT/VBx>), Apache License 2.0,
  © 2021-2024 BUT Speech@FIT. FluidAudio's variational Bayes clustering is a
  Swift implementation based on it, and cites it as such. Shipped as
  `Contents/Resources/licenses/FluidAudio-VBx-LICENSE.txt`.

### NVIDIA NeMo

FluidAudio's Sortformer diarization is ported from NeMo's implementation, which
its own source files state. That is the same relationship its VBx entry above
records, and it is user-reachable through the Sortformer diarization mode.

- **Project:** <https://github.com/NVIDIA/NeMo>
- **Copyright:** NVIDIA Corporation
- **License:** Apache License 2.0, shipping as
  `Contents/Resources/licenses/FluidAudio-NeMo-LICENSE.txt`. NeMo publishes no
  NOTICE file, so section 4(d) adds nothing here.

### NemoTextProcessing

From FluidAudio 0.15.6 on, text normalization runs through a prebuilt Rust
static library rather than Swift code, so a further set of components is
redistributed inside the app binary. FluidAudio declares it as a `binaryTarget`,
which means it appears in no dependency manifest of ours and its own
dependencies appear nowhere at all; the accounting below comes from reading the
shipped archive (`libtext_processing_rs.a`, 44 Rust crates) rather than from any
manifest.

- **Project:** <https://github.com/FluidInference/text-processing-rs>
- **Version:** 0.3.0, pinned by checksum in FluidAudio's `Package.swift`
- **Copyright:** 2026 FluidInference
- **License:** Apache License 2.0, shipping as
  `Contents/Resources/licenses/NemoTextProcessing-LICENSE.txt`. Upstream carries
  no NOTICE file, so section 4(d) imposes nothing further.

It is a Rust port of NVIDIA's NeMo text processing, which its README states.
That is a different upstream from the NeMo entry above, which covers the
Sortformer port, so it is attributed separately:

- **Project:** <https://github.com/NVIDIA/NeMo-text-processing>
- **Copyright:** the upstream `LICENSE` is the unmodified Apache-2.0 text with
  the `Copyright [yyyy] [name of copyright owner]` line left as written, so it
  names no holder. The project is published by NVIDIA Corporation.
- **License:** Apache License 2.0, shipping as
  `Contents/Resources/licenses/NemoTextProcessing-NVIDIA-LICENSE.txt`.

#### Rust crates and standard library

The archive statically links 43 further crates: the project's own dependency
tree, together with the parts of the Rust standard library and its unwinding
and compiler support that any Rust binary carries. Nearly all of them are
offered under a choice of licenses. Where Apache-2.0 is among the choices this
project elects it, so one licence text covers that whole set:

- **License:** Apache License 2.0, shipping as
  `Contents/Resources/licenses/Rust-LICENSE-APACHE.txt`. This is the elected
  licence for the dual-licensed crates and for the Rust standard library.

Five crates offer no Apache-2.0 option, so MIT is elected for them and their
copyright notices are reproduced as that licence requires:

- **generic-array** 1.4.3, **nom** 7.1.3, **ordered-float** 5.3.0,
  **simd-adler32** 0.3.9 and **memchr** 2.8.3. Their notices and the licence
  text ship together as `Contents/Resources/licenses/Rust-LICENSE-MIT.txt`,
  which also carries the Rust standard library's own MIT notice.

One component is not a choice but a conjunction:

- **compiler-builtins** carries the compiler-rt routines that Rust code calls
  for arithmetic the hardware does not implement directly, and is licensed
  `MIT AND Apache-2.0 WITH LLVM-exception`. Both apply at once, so its combined
  licence file ships verbatim as
  `Contents/Resources/licenses/Rust-compiler-builtins-LICENSE.txt`.

## LocalVQE

Acoustic echo cancellation: the inference library, statically linked into the
app binary, and the model weights, bundled as
`Contents/Resources/localvqe-v1.4-aec-200K-f32.gguf`.

- **Project:** <https://github.com/localai-org/LocalVQE>
- **Weights:** <https://huggingface.co/LocalAI-io/LocalVQE>, revision
  `29ca38495cba9d6393a92a4dd890f28dd81f758d`, file
  `localvqe-v1.4-aec-200K-f32.gguf`
- **Copyright:** 2024-2026 Richard Sherwood Palethorpe
- **License:** Apache License 2.0. Bundling the weights is redistribution just
  as linking the library is, so the full text ships as
  `Contents/Resources/licenses/LocalVQE-LICENSE.txt`.

LocalVQE is a streaming, CPU-tuned derivative of DeepVQE (Indenbom et al.,
Interspeech 2023, <https://arxiv.org/abs/2306.03177>).

The macOS `.xcframework` this app links is built from that source and published
separately, because upstream ships no macOS artifact; `app/MeetingTranscriber/Package.swift`
pins it by checksum. `scripts/fetch-localvqe-model.sh` pins the weights the same
way, by revision and SHA-256.

The weights are also mirrored, unmodified, at
<https://github.com/pasrom/localvqe-xcframework/releases/tag/model-v1.4-aec-200K>,
and the build fetches that copy first so a release does not depend on a single
external host staying up. The mirror is a convenience for availability and not a
source of authority: the SHA-256 above is verified whichever host answers, and
the upstream revision named above remains the provenance.

### ggml

That archive is not LocalVQE alone. It statically links ggml, which supplies the
tensor library, the CPU and BLAS backends and the GGUF reader, and which is a
separate project under its own terms rather than part of LocalVQE's grant. It
reaches this app only through the `CLocalVQE` binary target, so it is invisible
in `Package.resolved` and easy to miss: verified by listing the objects in the
linked archive, where ggml accounts for most of them.

- **Project:** <https://github.com/ggml-org/ggml>
- **Copyright:** 2023-2026 The ggml authors
- **License:** MIT. The full text ships as
  `Contents/Resources/licenses/ggml-LICENSE.txt`.

## How these files get into the bundle

`scripts/lib/bundle-licenses.sh` copies everything in `licenses/` into
`Contents/Resources/licenses/`, and both `scripts/build_release.sh` and
`scripts/run_app.sh` call it. It loops over the directory rather than naming
components, so attributing a new dependency means adding its licence file to
`licenses/` and nothing else.
