# Changelog

## 0.60.0-rc4 - 2026-11-10

- Convert Delphi TODO comments to Doxygen entries with original metadata/location.
- Include active body, include, initialization/main and trailing TODOs; exclude
  inactive branches and string literals.
- Add 11 TODO tests: the public suite now contains 67 tests.
- Prepare public examples, portable tests and English documentation.

## 0.60.0-rc3 - 2026-11-10

- Emit static call sites directly through the native Doxygen input filter.
- Resolve local cross-unit receivers, fields/properties, locals and ancestors.
- Include labelled parameterless anonymous callback sites.
- Verify actual Doxygen edges and both graph directions with native tests.

## Earlier local development

Modern declarations, Unicode/codepages, conditional parsing and a PasDoc-based
Doxygen renderer preceded this public candidate. Legacy Flex and private
project-documentation tools are not included here.
