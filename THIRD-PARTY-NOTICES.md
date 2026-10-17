# Third-party components

SpatialAudioBridge uses these Rust components, pinned by `Cargo.lock`. Their original license texts are retained under `licenses/`. Preserve those texts with binary distributions.

The core's frameworks also contain the Rust standard library, under MIT OR Apache-2.0 with the notices of its own dependencies. `scripts/build-core.sh` copies those notices from the toolchain that built the frameworks to `licenses/rust-std-<version>/COPYRIGHT-library.html`. Release archives contain `LICENSE`, this file and the whole `licenses/` directory, including those notices.

For apps, `scripts/build-core.sh` also writes `Sources/SpatialAudioBridge/Resources/ThirdPartyNotices.txt`: this project's license, the license texts of the crates linked into the core (build-time crates such as `syn` are left out) and the Rust standard library's notices converted to text, with each distinct license text listed once. The package bundles it, and `SpatialAudioBridgeNotices.text` returns it. Commit it whenever it changes; a release refuses to build when it is out of date.

| Component | Version | Declared license |
|---|---|---|
| truehd | 0.7.2 | Apache-2.0 |
| dca | 0.8.0 | Apache-2.0, but ported from FFmpeg; see [below](#dca-and-the-lgpl) |
| oamd | 0.1.0 | Apache-2.0 |
| anyhow | 1.0.104 | MIT OR Apache-2.0 |
| autocfg | 1.5.1 | Apache-2.0 OR MIT |
| bitstream-io | 4.10.0 | MIT/Apache-2.0 |
| log | 0.4.34 | MIT OR Apache-2.0 |
| memchr | 2.8.3 | Unlicense OR MIT |
| no_std_io2 | 0.9.4 | Apache-2.0 OR MIT |
| num-complex | 0.4.6 | MIT OR Apache-2.0 |
| num-integer | 0.1.47 | MIT OR Apache-2.0 |
| num-traits | 0.2.19 | MIT OR Apache-2.0 |
| primal-check | 0.3.4 | MIT OR Apache-2.0 |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 |
| quote | 1.0.47 | MIT OR Apache-2.0 |
| rustfft | 6.4.1 | MIT OR Apache-2.0 |
| strength_reduce | 0.2.4 | MIT OR Apache-2.0 |
| syn | 3.0.6 | MIT OR Apache-2.0 |
| thiserror / thiserror-impl | 2.0.21 | MIT OR Apache-2.0 |
| transpose | 0.2.3 | MIT OR Apache-2.0 |
| unicode-ident | 1.0.26 | (MIT OR Apache-2.0) AND Unicode-3.0 |

The TrueHD decoder uses the [harletty fork of truehdd](https://github.com/harletty/truehdd/tree/5c8b880405946e7ff1aee884cf9988415fe2c3a9), commit `5c8b880405946e7ff1aee884cf9988415fe2c3a9`. DTS decoding uses the standalone [dca crate](https://github.com/harletty/harletty-bridge/tree/a717bae441b116485f0254603dc20a6ede65d8c6/dca), commit `a717bae441b116485f0254603dc20a6ede65d8c6`. Only these decoder crates are linked from their workspaces. Apple's frameworks are supplied by the operating system.

The IMAX component metadata test vector in `Rust/SpatialAudioCore/src/decode.rs` is adapted from `dca/src/dcadec/xmeta.rs` at the pinned dca revision, under Apache-2.0. Its license is retained in `licenses/dca-0.8.0/LICENSE`.

## dca and the LGPL

The `dca` crate declares Apache-2.0, but its sources describe it as a port of FFmpeg's DTS decoder: its core, XLL, EXSS, synthesis and header parsing name the FFmpeg files they were ported from, and its tables are generated from FFmpeg's. Those files are licensed under the LGPL, version 2.1 or later. Mixed with the crate's Apache-2.0 code, which is incompatible with version 2.1, the crate can only be used under the LGPL, version 3 or later.

Only `dca` is under the LGPL. Everything else in the core, including this project's code, stays under its own license, Apache-2.0 for this project: the LGPL 3.0 lets a work that links the library keep its own terms if users can modify the library and relink it (section 4). This project's sources are public, so anyone can rebuild the core with a modified `dca`. The core ships as the dynamic `SpatialAudioCore.framework`, so an app that embeds it, as SwiftPM and Xcode do, lets its users replace it with such a build, and the app itself keeps its own license. Apps must not link the core statically. `licenses/dca-0.8.0/` holds the crate's Apache-2.0 license, the LGPL 2.1 and 3.0 texts, the GPL 3.0 text the LGPL 3.0 incorporates, and `NOTICE-FFmpeg`, which lists the FFmpeg files and their copyright holders. This is not legal advice.

The speaker renderer and Swift host layer are implemented in this project. Test media is obtained separately by the person running fixture validation.
