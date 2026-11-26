# Harmony

**Content-addressed functions for the BEAM.** Every function is identified by a hash of what it does, not by its name. Deploys ship only the functions that changed, renames ship nothing, and every version stays runnable side by side.

> [!IMPORTANT]
> Harmony is a proof of concept inspired by [Unison](https://www.unison-lang.org/). Today it reads a deliberately tiny demo syntax so the code-identity and deployment model is easy to see. The goal is to hash ordinary compiled Elixir instead; see [Where it's going](#where-its-going).

## What it can do

- **Hash every function by content.** A function's hash covers its body. Calls refer to the callee's *hash*, never its name.
- **Rehash precisely.** Changing a function changes its hash and the hashes of its callers, and nothing else.
- **Rename for free.** Renaming a function changes no hash, not even its callers'. The deploy writes zero bytes of code.
- **Deduplicate.** Two identical definitions are one object.
- **Deploy differentially.** A deploy writes only the objects the store doesn't already have, then records an immutable release that maps names to hashes.
- **Run any release, and roll back instantly.** Releases never change. Rolling back moves `HEAD`; no code is rebuilt or re-uploaded.
- **Run old and new code in one VM at once.** Each function compiles to a BEAM module named after its hash (`harmony_<hash>`). New versions are new modules, so there's nothing to purge or replace: in-flight calls keep their code, and the next call through the name table gets the new one.
- **Run in a fresh [libbeam](https://github.com/leostera/libbeam) Isolate** (optional), a BEAM that boots in milliseconds, so each call can start from a clean world.

## Quickstart

You need Elixir 1.18+ on OTP 27+.

```sh
git clone https://github.com/leostera/harmony.git && cd harmony
mix deps.get && mix test
```

Deploy three versions of [the greeter example](examples/greeter):

```console
$ mix harmony.deploy examples/greeter/v1.hm
Release 1
  objects: 4 new, 0 reused, 2524 bytes written
  + greeting
  + health
  + main
  + punctuation

$ mix harmony.deploy examples/greeter/v2.hm     # edits `greeting`
Release 2 (was 1)
  objects: 2 new, 2 reused, 1364 bytes written
  ~ greeting
  ~ main

$ mix harmony.deploy examples/greeter/v3.hm     # renames `greeting` to `salute`
Release 3 (was 2)
  objects: 0 new, 4 reused, 0 bytes written
  > greeting -> salute (same code)
```

`main` changed in release 2 even though its text didn't, because it calls `greeting`, whose hash changed. In release 3, nothing was written.

Run, inspect and roll back:

```console
$ mix harmony.run main Joe
Howdy, Joe!

$ mix harmony.run main Joe --release 1
Hello, Joe!

$ mix harmony.log
* 3  health@258788d00b main@4d71fd5bed punctuation@e26227ea16 salute@a40e2cb4c6
  2  greeting@a40e2cb4c6 health@258788d00b main@4d71fd5bed punctuation@e26227ea16
  1  greeting@454e7525aa health@258788d00b main@7b64c46d1b punctuation@e26227ea16

$ mix harmony.rollback 1 && mix harmony.run main Joe
Release 1 is current
Hello, Joe!
```

`mix harmony.hash FILE` prints hashes without deploying. Every command takes `--store DIR` (default `.harmony`).

## The demo syntax

Harmony's identity model doesn't depend on a language. The demo frontend reads a minimal syntax where every function takes one binary, `input`, and returns a binary.

```text
-- comments start with two dashes
punctuation = "!"
greeting = "Hello, " ++ input ++ punctuation(input)
main = greeting(input)
```

| Form | Meaning |
| --- | --- |
| `"text"` | a binary literal (`\n`, `\"` and `\\` escapes) |
| `input` | the function's argument |
| `name(expr)` | call another function |
| `a ++ b` | concatenate binaries |

That's all of it. There are no recursive definitions yet, no other types, and no effects.

## How it works

1. **Parse** each `name = expr` line ([`Harmony.Syntax`](lib/harmony/syntax.ex)).
2. **Resolve** names to hashes, callees first, and **hash** each body: SHA-256 over a versioned, canonical byte encoding in which a call is the callee's hash ([`Harmony.Codebase`](lib/harmony/codebase.ex)). The encoding is Harmony's own, so hashes don't depend on the Erlang term format or compiler.
3. **Compile** each unique hash to one BEAM module, `harmony_<hash>`, exporting `run/1`. Calls compile to remote calls to the callee's hash module ([`Harmony.Object`](lib/harmony/object.ex)).
4. **Deploy** into an append-only store ([`Harmony.Store`](lib/harmony/store.ex)):

   ```text
   .harmony/objects/<hash>.beam   one function, written once and never changed
   .harmony/releases/<n>.json     names -> hashes, plus the call graph
   .harmony/HEAD                  the current release
   ```

   Objects are written first, then the release, then `HEAD` is moved atomically. A failed deploy never changes the current release.
5. **Run** a name: look it up in a release, walk the call graph to its closure, check each object's module matches its hash, load what isn't loaded yet, and call it ([`Harmony.Runtime`](lib/harmony/runtime.ex)).

### On libbeam

[libbeam](https://github.com/leostera/libbeam) is an embeddable BEAM where each Isolate is a separate, fast-booting world. Harmony can run any release's closure in a fresh Isolate:

```sh
git clone https://github.com/leostera/libbeam.git ../libbeam   # needs Bazel and a C++17 compiler
HARMONY_LIBBEAM=1 mix deps.get
LIBBEAM_SOURCE=$PWD/../libbeam deps/libbeam_elixir/native/build.sh
HARMONY_LIBBEAM=1 mix harmony.run main Joe --libbeam
HARMONY_LIBBEAM=1 mix test     # also runs the libbeam test
```

libbeam loads a module group before an Isolate starts, so here a new release means a new Isolate with the full closure, not a live update. Differential storage means the host already holds most of that closure. On the regular BEAM (`Harmony.Runtime`), versions coexist in one live VM.

## Limits

- **The demo syntax is a toy.** Binary in, binary out, no recursion, no data types, no effects.
- **One module per function** is the simplest mapping onto the BEAM, not an efficient one. Large programs would mean many tiny modules and atoms.
- **No garbage collection.** Old objects stay in the store forever.
- **No distribution.** Syncing stores between machines (sending a peer only the hashes it lacks) is the natural next step but isn't built.
- **Trusted code only.** Hashes give identity and integrity, not safety.

## Where it's going

Replace the demo syntax with ordinary Elixir: compile the project, then hash each function's Core Erlang after macro expansion, with calls replaced by callee hashes and recursive groups hashed together. Elixir modules are values (structs, protocols, exceptions, `apply/3`), so shipped modules keep their real names; hashes drive identity, diffs and deduplication, and each release runs in its own [libbeam](https://github.com/leostera/libbeam) Isolate.

Also: store-to-store sync and garbage collection of unreachable objects.

## License

[MIT](LICENSE)
