# Quality fixture attribution

## four_speakers_en_ami

An excerpt of a genuine recorded meeting, used as the real-audio counterpart to
the synthetic `*_de` fixtures.

- **Source:** [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/),
  University of Edinburgh.
- **Licence:** [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
  Both the signals and the manual annotations are released under it, which is
  what permits redistributing this excerpt inside the repository.
- **Excerpt:** meeting `ES2004a`, `Mix-Headset` channel, seconds 948.019 to
  1041.810 (93.79 s), resampled to 16 kHz mono 16-bit.
- **Ground truth:** derived from the AMI manual annotations v1.6.2
  (`words/` and `segments/`), not from any ASR output.
- **Changes made:** cut to the window above, downmixed and resampled; the
  transcript was assembled from the published word and segment annotations.
  Speaker labels A/B/C/D are the corpus's own anonymous participant letters.

Regenerate with `scripts/generate_real_meeting_fixture.sh`. It re-downloads the
source material, rebuilds both files from the window constants in
`scripts/lib/ami_fixture_truth.py`, and verifies the audio against a committed
SHA-256 so the reproducibility claim fails loudly rather than silently if the
upstream recording, `sox`, or those constants ever change.

## Synthetic fixtures (`two_speakers_de`, `three_speakers_de`)

Generated locally by `scripts/generate_quality_fixtures.sh` from the macOS `say`
voices. No third-party material, no attribution required.
