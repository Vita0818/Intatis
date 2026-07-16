# Markdown rendering third-party notices

This notice covers the exact SwiftPM dependency graph used for Markdown
rendering. No source from these repositories is copied into Intatis; each item
is consumed as an upstream package. Intatis' renderer adapter and safety policy
are project-owned code.

## MarkdownUI

- Upstream: <https://github.com/gonzalezreal/swift-markdown-ui>
- Version/tag: `2.4.1`
- Commit: `5f613358148239d0292c0cef674a3c2314737f9e`
- Local reuse mode: `dependency`
- Product role: CommonMark parsing model and SwiftUI Markdown rendering
- License file reviewed: `LICENSE` at the pinned commit
- License: MIT

### MIT License

Copyright (c) 2020 Guillermo Gonzalez

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

## NetworkImage

- Upstream: <https://github.com/gonzalezreal/NetworkImage>
- Version/tag: `6.0.0`
- Commit: `7aff8d1b31148d32c5933d75557d42f6323ee3d1`
- Local reuse mode: `dependency` (direct exact constraint for MarkdownUI's
  otherwise ranged dependency)
- Product role: dependency-graph compatibility; Intatis replaces MarkdownUI's
  default image providers and does not permit implicit remote image loading
- License file reviewed: `LICENSE` at the pinned commit
- License: MIT

### MIT License

Copyright (c) 2020 Guille Gonzalez

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

## swift-cmark

- Upstream: <https://github.com/swiftlang/swift-cmark>
- Version/tag: `0.5.0`
- Commit: `3ccff77b2dc5b96b77db3da0d68d28068593fa53`
- Local reuse mode: `dependency` (direct exact constraint for MarkdownUI's
  otherwise ranged dependency)
- Product role: CommonMark C parser linked through MarkdownUI
- License file reviewed: `COPYING` at the pinned commit
- Runtime-source licenses: BSD-2-Clause and MIT-derived portions

The upstream repository also licenses its CommonMark specification test data
under CC BY-SA 4.0. Those test/specification assets are not SwiftPM resources
of the Intatis application products and are not copied into Intatis. The
runtime-source notices that apply to the linked parser follow.

### Core cmark code — BSD 2-Clause License

Copyright (c) 2014, John MacFarlane

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

### MIT-derived runtime portions

The upstream `COPYING` file identifies these derived portions:

- `houdini.h`, `houdini_href_e.c`, `houdini_html_e.c`, and `houdini_html_u.c`,
  derived from `vmg/houdini`, copyright (c) 2012 Vicent Marti.
- `buffer.h`, `buffer.c`, and `chunk.h`, derived from code copyright (c) 2012
  GitHub, Inc.
- UTF-8 implementation files derived from utf8proc, copyright (c) 2009 Public
  Software Group e. V., Berlin, Germany.

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

## swift-snapshot-testing

- Upstream: <https://github.com/pointfreeco/swift-snapshot-testing>
- Version/tag: `1.12.0`
- Commit: `26ed3a2b4a2df47917ca9b790a57f91285b923fb`
- Local reuse mode: `dependency` (exact test-side graph constraint)
- Product role: MarkdownUI package test dependency; not linked into an Intatis
  application product
- License file reviewed: `LICENSE` at the pinned commit
- License: MIT

### MIT License

Copyright (c) 2019 Point-Free, Inc.

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
