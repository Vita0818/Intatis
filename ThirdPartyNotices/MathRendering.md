# Math rendering third-party notices

## iosMath

- Upstream: <https://github.com/kostub/iosMath>
- Version/tag: `2.5.0`
- Commit: `838cddc01fdd67efd530f8bb67959ad2715f9b06`
- Local reuse mode: `dependency + adapted MIT sample source`
- Product role: TeX math parsing and layout on macOS and iOS
- Adapted source: upstream `SwiftMathExample/MathLabel.swift` at the pinned
  tag/commit, selectively rewritten into
  `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMathView.swift`
  for the macOS/iOS SwiftUI bridge, dynamic color, accessibility, sizing, and
  fallback behavior. No parser or layout-engine source is copied into Intatis.
- License files reviewed: root `LICENSE`, `iosMath/fonts/*.txt`, and the font
  inventory in `README.md` at the pinned commit
- Engine license: MIT
- Resource behavior: the SwiftPM target uses `.copy("fonts")`, so all eight
  listed OpenType fonts are bundled as unmodified upstream resources

### MIT License — iosMath

Copyright (c) 2013 MathChat

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Bundled font inventory and license mapping

The following files are bundled by iosMath and are not Intatis-owned assets:

| Bundled font | Upstream attribution | License |
| --- | --- | --- |
| Latin Modern Math | Boguslaw Jackowski, Piotr Strzelczyk, Piotr Pianowski; math extensions copyright 2012-2014 on behalf of TeX Users Groups | GUST Font License (LPPL 1.3c or later) |
| New Computer Modern Math | Antonis Tsolomitis | GUST Font License (LPPL 1.3c or later) |
| TeX Gyre Pagella Math | Boguslaw Jackowski, Janusz M. Nowacki, Piotr Strzelczyk; GUST e-foundry | GUST Font License (LPPL 1.3c or later) |
| TeX Gyre Termes Math | Boguslaw Jackowski, Piotr Strzelczyk, Piotr Pianowski; math extensions copyright 2012-2014 on behalf of TeX Users Groups | GUST Font License (LPPL 1.3c or later) |
| XITS Math 1.302 | STI Pub Companies; MicroPress, Inc.; Elsevier, Inc.; (URW)++ Design & Development; Khaled Hosny; Daniel Benjamin Miller | SIL Open Font License 1.1; reserved names include STIX Fonts and TM Math |
| STIX Two Math | Copyright 2001-2021 The STIX Fonts Project Authors | SIL Open Font License 1.1; reserved font name `TM Math`; STIX Fonts is an IEEE trademark |
| Fira Math | Copyright 2018-2020 The Fira Math Project Authors | SIL Open Font License 1.1 |
| Noto Sans Math | Copyright 2022 The Noto Project Authors | SIL Open Font License 1.1 |

Cambria Math is proprietary and is intentionally not bundled upstream or by
Intatis.

The GUST Font License is an LPPL-based font license rather than one of the
repository policy's automatically accepted permissive software licenses. This
notice records the implementation choice and license terms; it does not
constitute the explicit license approval required by `docs/OPEN_SOURCE_REUSE.md`.
Project approval must explicitly confirm the unmodified-font distribution
obligations before retaining this dependency for distribution or shipping a
binary.

## GUST Font License notice

The following is the license notice shipped by iosMath as
`iosMath/fonts/GUST-FONT-LICENSE.txt`:

> This is a preliminary version (2006-09-30), barring acceptance from the
> LaTeX Project Team and other feedback, of the GUST Font License. (GUST is the
> Polish TeX Users Group, <http://www.gust.org.pl>.)
>
> For the most recent version of this license see
> <http://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt> or
> <http://tug.org/fonts/licenses/GUST-FONT-LICENSE.txt>.
>
> This work may be distributed and/or modified under the conditions of the
> LaTeX Project Public License, either version 1.3c of this license or (at your
> option) any later version.
>
> Please also observe the following clause: it is requested, but not legally
> required, that derived works be distributed only after changing the names of
> the fonts comprising this work and given in an accompanying "manifest", and
> that the files comprising the Work, as listed in the manifest, also be given
> new names. Any exceptions to this request are also given in the manifest.
>
> We recommend the manifest be given in a separate file named
> `MANIFEST-<fontid>.txt`, where `<fontid>` is some unique identification of
> the font family. If a separate "readme" file accompanies the Work, we
> recommend a name of the form `README-<fontid>.txt`.
>
> The latest version of the LaTeX Project Public License is in
> <http://www.latex-project.org/lppl.txt> and version 1.3c or later is part of
> all distributions of LaTeX version 2006/05/20 or later.

Intatis distributes these fonts unmodified under their upstream filenames.

## SIL Open Font License 1.1 attributions

The copyright and reserved-name statements shipped with the four OFL fonts
are preserved below:

- XITS Math: Copyright (c) 2001-2010, STI Pub Companies, consisting of the
  American Institute of Physics, the American Chemical Society, the American
  Mathematical Society, the American Physical Society, Elsevier, Inc., and The
  Institute of Electrical and Electronic Engineers, Inc. (`www.stixfonts.org`),
  with Reserved Font Name STIX Fonts; STIX Fonts is a trademark of IEEE.
  Copyright (c) 1998-2003, MicroPress, Inc. (`www.micropress-inc.com`), with
  Reserved Font Name TM Math. Copyright (c) 1990, Elsevier, Inc. Copyright (c)
  2014, 2015, (URW)++ Design & Development. Copyright (c) 2009-2019, Khaled
  Hosny. Copyright (c) 2019, Daniel Benjamin Miller.
- STIX Two Math: Copyright 2001-2021 The STIX Fonts Project Authors
  (<https://github.com/stipub/stixfonts>), with Reserved Font Name `TM Math`.
  STIX Fonts is a trademark of The Institute of Electrical and Electronics
  Engineers, Inc.
- Fira Math: Copyright 2018-2020 The Fira Math Project Authors
  (<https://github.com/firamath/firamath>).
- Noto Sans Math: Copyright 2022 The Noto Project Authors
  (<https://github.com/notofonts/math>).

### SIL Open Font License Version 1.1 — 26 February 2007

PREAMBLE

The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership with
others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The fonts,
including any derivative works, can be bundled, embedded, redistributed
and/or sold with any software provided that any reserved names are not used by
derivative works. The fonts and derivatives, however, cannot be released under
any other type of license. The requirement for fonts to remain under this
license does not apply to any document created using the fonts or their
derivatives.

DEFINITIONS

"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may include
source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting, or
substituting -- in part or in whole -- any of the components of the Original
Version, by changing formats or by porting the Font Software to a new
environment.

"Author" refers to any designer, engineer, programmer, technical writer or
other person who contributed to the Font Software.

PERMISSION & CONDITIONS

Permission is hereby granted, free of charge, to any person obtaining a copy
of the Font Software, to use, study, copy, merge, embed, modify, redistribute,
and sell modified and unmodified copies of the Font Software, subject to the
following conditions:

1. Neither the Font Software nor any of its individual components, in Original
   or Modified Versions, may be sold by itself.
2. Original or Modified Versions of the Font Software may be bundled,
   redistributed and/or sold with any software, provided that each copy
   contains the above copyright notice and this license. These can be included
   either as stand-alone text files, human-readable headers or in the
   appropriate machine-readable metadata fields within text or binary files as
   long as those fields can be easily viewed by the user.
3. No Modified Version of the Font Software may use the Reserved Font Name(s)
   unless explicit written permission is granted by the corresponding
   Copyright Holder. This restriction only applies to the primary font name as
   presented to the users.
4. The name(s) of the Copyright Holder(s) or the Author(s) of the Font Software
   shall not be used to promote, endorse or advertise any Modified Version,
   except to acknowledge the contribution(s) of the Copyright Holder(s) and
   the Author(s) or with their explicit written permission.
5. The Font Software, modified or unmodified, in part or in whole, must be
   distributed entirely under this license, and must not be distributed under
   any other license. The requirement for fonts to remain under this license
   does not apply to any document created using the Font Software.

TERMINATION

This license becomes null and void if any of the above conditions are not met.

DISCLAIMER

THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT,
TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR
ANY CLAIM, DAMAGES OR OTHER LIABILITY, INCLUDING ANY GENERAL, SPECIAL,
INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF THE USE OR INABILITY TO USE
THE FONT SOFTWARE OR FROM OTHER DEALINGS IN THE FONT SOFTWARE.
