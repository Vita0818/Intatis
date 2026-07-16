# Syntax highlighting third-party notices

## Adopted highlight.js resources

- Engine upstream: <https://github.com/highlightjs/highlight.js>
- Engine version: `11.11.1`
- Engine upstream tag commit: `08cb242e7d4aee787114eb04cc7ab18314d82f92`
- Engine generated-byte repository:
  <https://github.com/highlightjs/cdn-release/tree/91724c0adaf7bea7e5c5c85e4ea1d672f6c0ed23>
- Engine exact byte source: `highlightjs/cdn-release` tag `11.11.1`, commit
  `91724c0adaf7bea7e5c5c85e4ea1d672f6c0ed23`, path
  `build/highlight.min.js` (generated header revision `08cb242e7d`)
- Theme-adaptation byte-source mirror:
  <https://github.com/smittytone/HighlighterSwift/tree/fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0>
- Theme-adaptation version/commit: HighlighterSwift `3.1.0`,
  `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`
- Local reuse mode: `vendored` (three selected highlight.js files only)
- Licenses: highlight.js engine/theme lineage under BSD-3-Clause;
  HighlighterSwift theme adaptations under MIT
- Product role: upstream language grammars, token classification, and the two
  light/dark a11y color themes used by Intatis code blocks

`highlight.min.js` is the official 11.11.1 common-language CDN release build;
its 36 registered grammars cover the languages exposed by the Intatis alias
adapter. An earlier candidate copied from HighlighterSwift still carried the
11.11.1 package version but was generated from a post-release development
revision, so it was rejected rather than mislabeled as tag-exact bytes. The two
CSS files are byte-identical to HighlighterSwift 3.1.0's adjusted 11.11.1
themes, not to the official highlight.js source-theme files. HighlighterSwift's
3.1.0 README describes theme adjustments for its processor, so the MIT
modification provenance is retained alongside highlight.js's BSD-3-Clause
lineage. Intatis does **not** ship or link the HighlighterSwift Swift wrapper.
The project-owned runtime code is only a thin JavaScriptCore-to-
`NSAttributedString` adapter and surrounding SwiftUI code-block interface; it
does not implement a lexer, language grammar, token classifier, or syntax-color
engine.

### Exact vendored file inventory

| Intatis path | SHA-256 | Exact byte source | Upstream role |
| --- | --- | --- | --- |
| `Packages/IntatisSharedUI/Sources/MessageRendering/Resources/highlight.min.js` | `c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381` | `highlightjs/cdn-release` 11.11.1 commit `91724c0adaf7bea7e5c5c85e4ea1d672f6c0ed23`, `build/highlight.min.js` | official highlight.js 11.11.1 common-language engine and grammars |
| `Packages/IntatisSharedUI/Sources/MessageRendering/Resources/a11y-light.css` | `8dc8508231539c9f0942e2bf9244e1dab8d4aa1334c486649ab831695b3792d5` | HighlighterSwift 3.1.0 `Sources/Assets/styles/a11y-light.css` | adapted highlight.js `a11y-light` theme; author/maintainer `@ericwbailey` |
| `Packages/IntatisSharedUI/Sources/MessageRendering/Resources/a11y-dark.css` | `1819a72f11c6edb3ea07d32f19f0ac410da8e387673791f6b6e3a9387b314d48` | HighlighterSwift 3.1.0 `Sources/Assets/styles/a11y-dark.css` | adapted highlight.js `a11y-dark` theme; author/maintainer `@ericwbailey` |

The two CSS files preserve their upstream headers, including their stated
lineage from the Tomorrow Night Eighties theme. No other highlight.js theme,
image, sample, wrapper source, or package resource is vendored.

### Security compatibility restriction

The upstream 11.11.1 issue
[`highlightjs/highlight.js#4362`](https://github.com/highlightjs/highlight.js/issues/4362)
documents quadratic backtracking in the C/C++ `FUNCTION_DECLARATION` grammar.
Intatis therefore does not invoke the bundled engine for normalized `c` or
`cpp` blocks: those blocks keep the complete code container and raw copy source
but display plaintext. The affected Arduino grammar is not part of this common
bundle. Intatis does not patch or fork the upstream grammars; C/C++ highlighting
can return only after a fixed release is adopted and the bytes, license,
language inventory, performance, and regression behavior are re-audited.

## Explicitly rejected packages/assets

- **The HighlighterSwift package/wrapper is not adopted.** Builds of the audited
  package proved that its resource bundle copies the full theme directory,
  including `nnfx` and `kimbie` themes with CC BY-SA licensing. That resource
  scope does not meet Intatis' dependency policy. Only the three files in the
  inventory above are copied under their respective MIT/BSD provenance.
- **CodeEditor is not adopted.** No CodeEditor wrapper, source, or asset is
  linked, vendored, or copied into Intatis.

This selective vendoring is intentional: an upgrade must reverify the exact
engine version, all three file hashes, theme attribution/license, language
coverage, and JavaScriptCore security behavior before replacing any file.

## MIT License — HighlighterSwift theme adaptations

Copyright © 2026, Tony Smith (@smittytone)

Portions copyright © 2016, Juan Pablo Illanes

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## BSD 3-Clause License — highlight.js 11.11.1

The vendored minified engine preserves its generated-file header:
`Copyright (c) 2006-2024 Josh Goebel <hello@joshgoebel.com> and other
contributors.` The highlight.js source-tag root license identifies
`Copyright (c) 2006, Ivan Sagalaev`; the exact `cdn-release` byte-source
repository identifies `Copyright (c) 2006-2019, Ivan Sagalaev`. The latter
byte-source license notice is reproduced below while both provenance notices
are retained here:

Copyright (c) 2006-2019, Ivan Sagalaev. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
