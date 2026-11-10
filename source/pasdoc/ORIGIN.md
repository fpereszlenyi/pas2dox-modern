# PasDoc source subset

Upstream: https://github.com/pasdoc/pasdoc

Pinned commit: `dbc50ba9ecb05b38d82855f0659b4dc2b827e242`.
Copyright 1998-2026 PasDoc developers. GPL-2.0-or-later; see LICENSE.
Original per-file copyright/license notices are retained.

The subset contains 13 units and 3 include files needed by this Windows filter.
Upstream generators, test corpus and the full application are not bundled.

Local modifications dated 2026-11-10:

- `PasDoc_Items.pas`: declaration/source metadata, scoped enums, redacted body
  tokens and transient source TODO records.
- `PasDoc_Parser.pas`: modern declarations, HelpInsight/source provenance,
  implementation matching, token capture and active TODO capture.
- `PasDoc_Scanner.pas`: conditional expressions/directives, target/options,
  include provenance and consumed-token notification.
- `PasDoc_Tokenizer.pas`: fallback/BOM encoding, modern strings, provenance and
  duplicate body-token recording protection.

`CHANGES.patch` is the complete diff of these four files against the pinned
revision. Apply inside upstream `source/component`. Original file hashes are
in `UPSTREAM.json`. Header references in this public layout point to this file;
parser behavior is unchanged from the tested 0.60.0-rc4 implementation.

Added metadata is transient; upstream serialized-cache compatibility is not
asserted. The filter does not use those caches or upstream generators.
