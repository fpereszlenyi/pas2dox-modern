# Contributing

For a bug report, include a small publishable Delphi reproducer, filter/Doxygen
versions, source encoding, target profile/options and expected versus actual
output. Synthetic examples are preferable to confidential application files.

Build with `build.cmd`, then run `python -X utf8 tests/run_tests.py`. Add a focused
test for parser/renderer changes. Graph fixes should assert actual Doxygen
`references`/`referencedby` relations and an appropriate negative case.

The tests use Python's standard library. A licensed Delphi compiler is needed to
rebuild the filter. No hosted CI compiler workflow is assumed: GitHub-hosted
runners do not supply this project's Delphi installation/license.

Keep UTF-8 output, failure codes, original declarations and source provenance
consistent. Avoid guessed graph edges. Preserve third-party notices; PasDoc
changes should update `source/pasdoc/ORIGIN.md` and `CHANGES.patch`.

Generated documentation, intermediates and EXEs stay out of Git. Binary releases
include the exact corresponding source/build scripts. See [RELEASING.md](docs/RELEASING.md).
