# Homebrew Packaging

This directory contains a formula template for publishing `zwgsl` from GitHub
release assets. Publishing still requires a Homebrew tap repository and real
SHA-256 checksums from a tagged release.

Typical release flow:

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
shasum -a 256 dist/zwgsl-*.tar.gz
```

Copy `zwgsl.rb.template` into the tap as `Formula/zwgsl.rb`, replace the
placeholder URL and checksum values, then run `brew audit --strict zwgsl`.
