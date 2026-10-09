# Third-party components

SpatialAudioBridge uses these Rust components, pinned by `Cargo.lock`. Their original license texts are retained under `licenses/`. Preserve those texts with binary distributions.

| Component | Version | Declared license |
|---|---|---|
| truehd | 0.7.2 | Apache-2.0 |
| dca | 0.8.0 | Apache-2.0 |
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

The speaker renderer and Swift host layer are implemented in this project. Test media is obtained separately by the person running fixture validation.
