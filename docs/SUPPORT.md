# Support and verification

Tested: Windows x64; filter 0.60.0-rc4; Delphi 11 dcc64 35.0; Doxygen 1.18.0;
Graphviz 7.1.0; Python 3.11 for 67 synthetic regression tests.

| Area | Documentation behavior |
|---|---|
| Types | Namespaced units, generics/constraints, nested types, aliases, helpers, records/managed operators, interfaces, attributes and visibility |
| Routines | Methods, overload declarations, named/class constructors, callback types, original signatures and implementation comments |
| Encoding | UTF-8, BOM-detected UTF-16, explicit fallback codepages, Unicode source paths |
| Conditional source | Explicit Delphi/platform profiles, defines/includes, supported expressions and option snapshots |
| Graphs | Unique static targets across local units, fields/properties, locals and ancestors |
| TODOs | Delphi comments, original metadata/location, active include/init/main/trailing comments |

Delphi 12 multiline strings and selected Delphi 13 syntax have synthetic parsing
coverage. These tests do not certify all valid source or compiler conformance.

## Limits

- Delphi 12/13/13.2 compiler execution is unverified.
- PUSHOPT subset syntax is unsupported; full PUSHOPT/POPOPT is supported.
- `.dproj` settings and `.dpk` manifests are not imported automatically.
- Only a Windows x64 executable is supplied; source target profiles are separate.
- Other Doxygen/Graphviz versions have not been independently accepted.
- Unit lookup uses the input directory and a nearby project marker, at most two
  parent levels up. Generated/version-control directories are skipped. Duplicate
  names and unknown external libraries are not guessed.
- Ambiguous same-arity overloads, dynamic references/dispatch and uncertain
  `with` scopes are incomplete.
- Parameterless anonymous callback sites can appear under the containing routine,
  labelled to distinguish a source call site from proven execution.
- Named nested routines, parameterized/local-variable anonymous routines, bare
  `inherited;`, program entry and complete init/final call graphs are not fully
  modeled. TODO scanning of those source areas is supported separately.
- Overloads may have `__overload_...` graph names to avoid wrong Doxygen targets;
  original declarations remain in the documentation.
- Graph output adds generated definition/comment lines. `-i` preserves declaration
  locations but omits implementation graphs and implementation TODOs.
- Keep executable paths space-free on Windows. Unicode input filenames are tested;
  executable command quoting is a separate limitation.
- The binary is unsigned. Compare downloads with the release SHA-256 list.

Zero callers does not prove a routine is unused. Parsing and graph generation
do not prove application runtime behavior.

Official references: [Doxygen configuration](https://www.doxygen.nl/manual/config.html),
[todo command](https://www.doxygen.nl/manual/commands.html#cmdtodo),
[Delphi To-Do list](https://docwiki.embarcadero.com/RADStudio/Athens/en/To-Do_List).
