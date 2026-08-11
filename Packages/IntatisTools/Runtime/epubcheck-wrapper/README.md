# Intatis EPUBCheck wrapper

This project-owned launcher exposes the fixed executable name expected by
`DocumentBackendProcessRunner` while delegating EPUB conformance checks to the
unmodified official EPUBCheck distribution.

Runtime layout:

```text
document-runtime/
  bin/intatis-epubcheck
  lib/epubcheck-5.3.0/
    epubcheck.jar
    lib/*.jar
    LICENSE.txt
    THIRD-PARTY.txt
    licenses/*
```

The wrapper accepts no Intatis-specific command language. It forwards the
host-owned fixed argv to `/usr/bin/java -Djava.awt.headless=true -jar ...`.
The model cannot choose the executable, JAR, environment, network policy, or
runtime directory.

The local development runtime uses the official W3C release asset:

- release: `w3c/epubcheck` `v5.3.0`
- asset: `epubcheck-5.3.0.zip`
- asset SHA-256:
  `6c07e68584b2e2ce2f89fe06e1246dfead3eb36b46b340e7d93524f29dcff6c5`
- source URL:
  `https://github.com/w3c/epubcheck/releases/download/v5.3.0/epubcheck-5.3.0.zip`

The upstream distribution is intentionally not committed here. A packaged
Intatis release must preserve the distribution's `LICENSE.txt`,
`THIRD-PARTY.txt`, and `licenses/` directory and separately close signing,
architecture, Java-runtime, SBOM, and clean-machine verification gates.
