# Third-party notices

Meeting Transcriber itself is MIT licensed (see `LICENSE`).

**Scope, stated so nothing here is mistaken for a completeness claim:** this
file covers third-party **data resources** bundled into the shipped
application. It does not yet enumerate the source dependencies compiled into
the app binary (WhisperKit, FluidAudio, AudioTapLib and their own
dependencies), which are also redistributed and carry their own attribution
terms. That gap is known and not addressed here.

## LocalVQE

Acoustic echo cancellation: the inference library, statically linked into the
app binary, and the model weights, bundled as
`Contents/Resources/localvqe-v1.4-aec-200K-f32.gguf`.

- **Project:** <https://github.com/localai-org/LocalVQE>
- **Weights:** <https://huggingface.co/LocalAI-io/LocalVQE>, revision
  `29ca38495cba9d6393a92a4dd890f28dd81f758d`, file
  `localvqe-v1.4-aec-200K-f32.gguf`
- **Copyright:** 2024-2026 Richard Sherwood Palethorpe
- **License:** Apache License 2.0. The full text ships alongside the model as
  `Contents/Resources/LocalVQE-LICENSE.txt`, and is kept in this repository at
  `licenses/LocalVQE-LICENSE.txt`.

LocalVQE is a streaming, CPU-tuned derivative of DeepVQE (Indenbom et al.,
Interspeech 2023, <https://arxiv.org/abs/2306.03177>).

The macOS `.xcframework` this app links is built from that source and published
separately, because upstream ships no macOS artifact; `app/MeetingTranscriber/Package.swift`
pins it by checksum. `scripts/fetch-localvqe-model.sh` pins the weights the same
way, by revision and SHA-256, and `scripts/lib/localvqe-resources.sh` installs
the model and this licence into the bundle together.

The weights are also mirrored, unmodified, at
<https://github.com/pasrom/localvqe-xcframework/releases/tag/model-v1.4-aec-200K>,
and the build fetches that copy first so a release does not depend on a single
external host staying up. The mirror is a convenience for availability and not a
source of authority: the SHA-256 above is verified whichever host answers, and
the upstream revision named above remains the provenance.
