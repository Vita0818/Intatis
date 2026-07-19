# Math rendering distribution status

## Current status: not distributed

TeX/math parsing and rendering are disabled in the current
SwiftStreamingMarkdown derivative used by Intatis. The LaTeX preprocessor,
math attachments, block-math view, inline math provider, and their public
first-release configuration surface were removed from the derivative.

The current root `Package.swift`, `Package.resolved`, and derivative manifest
contain no iosMath dependency. No iosMath parser/layout code and none of its
bundled OpenType math fonts are intended to be present in a current macOS or
iOS product artifact. Text that resembles TeX remains ordinary byte-preserving
message content; Intatis does not claim to interpret or typeset it.

## Historical provenance

Intatis previously linked iosMath 2.5.0 and documented its MIT-licensed engine,
GUST Font License / LPPL fonts, and SIL Open Font License fonts. That provenance
remains available in Git history, but iosMath and its font resources are not
part of the current renderer or distribution notice set. Reintroducing math
rendering requires a new exact-version code/font audit, restored license texts
and copyright notices, artifact inventory, accessibility and performance
validation, and an update to `NOTICE.md` before release.
