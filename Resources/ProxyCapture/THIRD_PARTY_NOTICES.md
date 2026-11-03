# Bundled proxy engine

Runbar includes mitmproxy 12.3.1, licensed under the MIT license. See
`mitmproxy-LICENSE.txt` in this directory. Upstream:
https://github.com/mitmproxy/mitmproxy/releases/tag/v12.3.1

The official, self-contained macOS distributions are preserved as signed
bundles in `Runbar.app/Contents/Helpers/RunbarProxy-arm64.app` and
`Runbar.app/Contents/Helpers/RunbarProxy-x86_64.app` (as appropriate for the
architectures included in the build). They include Python, OpenSSL and other
dependencies. Their packaged third-party notices, licenses and distribution
metadata remain inside each helper's `Contents/Resources` and
`Contents/Frameworks`; nothing is stripped from the upstream bundles.

Version, official archive URLs and SHA-256 hashes are pinned in the source
repository's `scripts/proxy-engine.lock.json`. The build verifies the archive
hashes, Mach-O architectures and original publisher code signatures. It does
not install software globally, change certificate trust, execute the proxy, or
upload anything to Apple's notarization service.
