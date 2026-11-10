# Pas2Dox Modern 0.60.0-rc4

**Pre-release candidate for Windows x64.**

A standalone Delphi Doxygen input filter with modern declarations, static
call/caller graphs and Delphi IDE TODO conversion. Runtime use requires Doxygen
and Graphviz; Python and Delphi are not required to run the executable.

Includes a synthetic public example and 67 regression tests. The filter and
positive compiler fixtures were built with Delphi 11. See `VALIDATION.json` and
`docs/SUPPORT.md` for the measured results and exact limits.

## Assets

- `pas2dox-modern-0.60.0-rc4-windows-x64.zip`: EXE, exact corresponding source/build
  scripts, licenses, documentation, examples and tests.
- `pas2dox-modern-0.60.0-rc4-source.zip`: source-only GitHub-ready tree.
- `SHA256SUMS.txt`: archive checksums.

Extract to a path without spaces and follow `README.md`. Run
`doxygen examples\Doxyfile` for the example documentation.

Known limits include incomplete dynamic graphs, unknown external libraries,
selected nested-routine cases and lack of Delphi 12/13/13.2 compiler verification.
The binary is unsigned. Reports with small publishable reproductions are welcome.
