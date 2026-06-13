# CosmWasm Optimizing Compiler


This is a Docker build with a locked set of dependencies to produce
reproducible builds of cosmwasm smart contracts. It also does heavy
optimization on the build size, using binary stripping and `wasm-opt`.


---

# Terp Network Fork

This is a fork of `cosmwasm/optimizer:0.17.0` customized for the Terp Network ecosystem.
Published as `terpnetwork/optimizer-arm64:0.17.0`.

## Architecture

The Terp fork adds three capabilities on top of the upstream optimizer:

1. **Workspace root detection** — walks up from `PROJECT_DIR` to find the nearest `Cargo.toml` with `[workspace]`, so `bob` runs from the correct level regardless of nested workspace structure.

2. **Multi-level dependency resolution** — mounts the full dependency tree (all crates under one parent directory) into `/workspace`, so path dependencies across sibling repositories (`../cosmos-rust/`, `../../cw-orchestrator/`, etc.) resolve correctly.

3. **Wasm-safe dependency pinning** — `cosmrs`, `cosmos-sdk-proto`, and `abstract-interface` are set to `default-features = false` (or target-cfg'd behind `not(target_arch = "wasm32")`) to prevent `tokio/net` → `mio` from being compiled for wasm targets.

## Usage

### Standard workspace (single directory, all deps at one level)

```sh
cd /path/to/workspace
docker run --rm \
  -v "$(pwd)":/code \
  --mount type=volume,source="$(basename "$(pwd)")_cache",target=/target \
  --mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
  terpnetwork/optimizer-arm64:0.17.0
```

### Multi-repo workspace (dependencies in sibling directories)

The `crates/` folder contains all sibling repos (`abstract/`, `cosmos-rust/`, `cw-orchestrator/`, `xion-account/`, etc.).
Mount the parent directory that CONTAINS all of them, then set `PROJECT_DIR` to the subdirectory being built:

```sh
# Mount crates/ at /workspace so all path deps resolve
cd /path/to/crates
docker run --rm \
  -v "$(pwd):/workspace" \
  -e PROJECT_DIR=/workspace/abstract/framework \
  terpnetwork/optimizer-arm64:0.17.0
```

The optimizer finds `framework/Cargo.toml` as the workspace root, runs `bob` from there,
and cargo resolves all `path = "../../cosmos-rust/..."` dependencies against the mounted tree.

### Nested workspace (Abstract SDK pattern)

The Abstract SDK has:
- `packages/` — abstract-std, abstract-sdk, abstract-interface
- `framework/` — contracts/ (target contracts) + framework/packages/ (framework-specific deps)
- `framework/contracts/native/ibc-host/` — target contract

The workspace root is `abstract/framework/Cargo.toml`. Bob scans its `[workspace] members`,
finds contracts under `contracts/`, and builds each one. All sibling path deps resolve
because `crates/` (which contains both `abstract/` and the other repos) is mounted at `/workspace`:

```sh
cd /path/to/crates
docker run --rm \
  -v "$(pwd):/workspace" \
  -e PROJECT_DIR=/workspace/abstract/framework \
  terpnetwork/optimizer-arm64:0.17.0
```

Artifacts appear in `crates/abstract/framework/artifacts/`.

### Dependencies pinned for wasm safety

The workspace `Cargo.toml` must contain:

```toml
[workspace.dependencies]
cosmrs            = { path = "../../cosmos-rust/cosmrs", default-features = false }
cosmos-sdk-proto  = { path = "../../cosmos-rust/cosmos-sdk-proto", default-features = false }
```

And `abstract-adapter/Cargo.toml` must have `abstract-interface` under:

```toml
[target.'cfg(not(target_arch = "wasm32"))'.dependencies]
abstract-interface = { workspace = true }
```

These prevent `grpc-transport` → `tokio/net` → `mio` from leaking into wasm builds.

## Building the optimizer

```sh
cd ~/abstract/optimizer
make build-arm64       # local ARM build (Mac M1/M2/M3)
make build-amd64       # local AMD build (Intel)
make build-all         # both architectures
make publish-arm64     # build + push to registry
make publish-amd64     # build + push to registry
```

<!-- ## Default Cosmwasm 

| Image                                | Description                                                       | x86_64 images (default)                                                                                                                                                                             | ARM images (experimental<sup>1</sup>)                                                                                                                                                                                 |
| ------------------------------------ | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| optimizer                            | Combines rust-optimizer and workspace-optimizer in a single image | cosmwasm/optimizer<br />[![DockerHub](https://img.shields.io/docker/v/cosmwasm/optimizer?sort=semver&style=plastic)](https://hub.docker.com/r/cosmwasm/optimizer)                                   | cosmwasm/optimizer-arm64<br />[![DockerHub](https://img.shields.io/docker/v/cosmwasm/optimizer-arm64?sort=semver&style=plastic)](https://hub.docker.com/r/cosmwasm/optimizer-arm64)                                   |
| ~~rust-optimizer~~ _deprecated_      | ~~Single contract builds~~                                        | ~~cosmwasm/rust-optimizer~~<br />[![DockerHub](https://img.shields.io/docker/v/cosmwasm/rust-optimizer?sort=semver&style=plastic)](https://hub.docker.com/r/cosmwasm/rust-optimizer)                | ~~cosmwasm/rust-optimizer-arm64~~<br />[![DockerHub](https://img.shields.io/docker/v/cosmwasm/rust-optimizer-arm64?sort=semver&style=plastic)](https://hub.docker.com/r/cosmwasm/rust-optimizer-arm64)                |
| ~~workspace-optimizer~~ _deprecated_ | ~~Multi-contract workspaces (e.g. cosmwasm-plus)~~                | ~~cosmwasm/workspace-optimizer~~<br />[![DockerHub](https://img.shields.io/docker/v/cosmwasm/workspace-optimizer?sort=semver&style=plastic)](https://hub.docker.com/r/cosmwasm/workspace-optimizer) | ~~cosmwasm/workspace-optimizer-arm64~~<br />[![DockerHub](https://img.shields.io/docker/v/cosmwasm/workspace-optimizer-arm64?sort=semver&style=plastic)](https://hub.docker.com/r/cosmwasm/workspace-optimizer-arm64) |

<sup>1</sup> ARM images do not produce the same output as the default images and are discouraged for production use. See [Notice](#notice) below. -->

## Usage

_This works for most cases, for monorepo builds see advanced_

The easiest way is to simply use the [published docker image](https://hub.docker.com/r/cosmwasm/optimizer).
You must set the local path to the smart contract you wish to compile and
it will produce an `artifacts` directory with `<crate_name>.wasm`
and `checksums.txt` containing the hashes. This is just one file.

Run it a few times on different computers
and use `sha256sum` to prove to yourself that this is consistent. I challenge
you to produce a smaller build that works with the cosmwasm integration tests
(and if you do, please make an issue/PR):

```sh
docker run --rm -v "$(pwd)":/code \
  --mount type=volume,source="$(basename "$(pwd)")_cache",target=/target \
  --mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
  cosmwasm/optimizer:0.17.0
```

Demo this with `cosmwasm-examples` (going into eg. `erc20` subdir before running),
with `cosmwasm-plus`, or with a sample app from `cosmwasm-template`.

Note that we use one registry cache (to avoid excessive downloads), but the target cache is a different volume per
contract that we compile. This means no interference between contracts, but very fast recompile times when making
minor adjustments to a contract you had previously created an optimized build for.

## Mono Repos

### Contracts as Workspace Members

_This is designed for cosmwasm-plus samples. We use a separate docker image_

Sometime you want many contracts to be related and import common functionality. This is
exactly the case of [`cosmwasm-plus`](https://github.com/CosmWasm/cosmwasm-plus).
In such a case, we can often not just compile from root, as the compile order is
not deterministic and there are feature flags shared among the repos.
This has lead to [issues in the past](https://github.com/CosmWasm/rust-optimizer/issues/21).

For this use-case we made a second docker image, which will compile all the
`contracts/*` folders inside the workspace and do so one-by-one in alphabetical order.
It will then add all the generated wasm files to an `artifacts` directory with a checksum,
just like the basic docker image (same output format).

To compile all contracts in the workspace deterministically, you can run:

```shell
docker run --rm -v "$(pwd)":/code \
  --mount type=volume,source="$(basename "$(pwd)")_cache",target=/target \
  --mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
  cosmwasm/optimizer:0.17.0
```

The downside is that to verify one contract in the workspace, you need to compile them
all, but the majority of the build time is in dependencies, which are shared and cached
between the various contracts and thus the time is sub-linear with respect to number
of contracts.

### Contracts excluded from Workspace

_This is designed for cosmwasm samples. You cannot provide automatic verification for these_

If you have a more complex build environment, you need to pass a few more
arguments to define how to run the build process.

[`cosmwasm`](https://github.com/CosmWasm/cosmwasm) has a root workspace
and many contracts under `./contracts/*`, which are **excluded** in the
top-level `Cargo.toml`. In this case, we compile each contract separately
with it's own cache. However, since they may refer to packages via path
(`../../packages/std`), we need to run the script in the repo root. In this
case, we can use the optimize.sh command:

```shell
docker run --rm -v "$(pwd)":/code \
  --mount type=volume,source="devcontract_cache_burner",target=/code/contracts/burner/target \
  --mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
  cosmwasm/optimizer:0.17.0 ./contracts/burner
```

## Caches

The build system uses the folder `/target` in its local file system for all Rust compilation results.
This ensures there is no conflict with the target folder of the source repository.
It also means that for each compilation, Cargo will have an empty target folder and have to re-compile
all contracts and all dependencies. In order to avoid this, you can optionally mount a Docker volume
into the file system, as highlighted here:

```diff
 docker run --rm -v "$(pwd)":/code \
+  --mount type=volume,source="$(basename "$(pwd)")_cache",target=/target \
   --mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
   cosmwasm/rust-optimizer:0.15.0
```

Using this cache is considered best practice and included in all our example call snippets.

Before version 0.13.0, the target folder was located at `/code/target`. This
[caused situations](https://github.com/CosmWasm/rust-optimizer/issues/89) in which
rust-optimizer/workspace-optimizer wrote to the target folder of the host
in an unintended way. By ensuring the target location is not a subfolder of the mounted
source code we can avoid those sort of problems.

## Development

Take a look at the [Makefile](https://github.com/CosmWasm/rust-optimizer/blob/master/Makefile)
You can edit the Dockerfile (in a fork), and run `make build` to compile it.

## Notice

This has been tested on Linux (Ubuntu / Debian). There are currently versions of both optimizers for two processor
architectures: Intel/Amd 64-bits, and Arm 64-bits (these run natively on Mac M1 machines).

**However**, the native Arm version produces different wasm artifacts than the Intel version. Given that that impacts
reproducibility, non-Intel images contain a "-arm64" suffix to differentiate them.

Arm images are released to ease development and testing on Mac M1 machines. **For release / production use,
only contracts built with the Intel optimizers must be used.**
