# Harmony

**Content-addressed functions for the BEAM.** Harmony reads your compiled Elixir, Erlang or Gleam and gives every function a hash of what it does, not its name, and does the same for the library code it calls. Deploys ship only the functions that changed, renames ship nothing, and every version stays runnable side by side.

> [!IMPORTANT]
> Harmony is a proof of concept inspired by [Unison](https://www.unison-lang.org/). It works on a [subset](#the-subset) of what BEAM languages can do and isn't ready for production.

## What it can do

- **Hash every function by content.** A function's hash covers its compiled body. Calls to your own functions refer to the callee's *hash*, never its name.
- **Rehash precisely.** Changing a function changes its hash and the hashes of its callers, and nothing else.
- **Rename for free.** Renaming a function or a variable, moving a function to another module, or adding comments and blank lines changes no hash. The deploy writes zero bytes of code.
- **Deduplicate.** Identical functions are one object, even in different modules.
- **Handle recursion.** Self- and mutually recursive functions are hashed together as a group.
- **Mix languages.** An Elixir function calling an Erlang function is linked by hash like any other call.
- **Hash libraries too.** Calls into Elixir, OTP or your dependencies pull the library functions they reach into the codebase, hashed like your own. What can't be hashed (protocol dispatch on a runtime module, NIFs) is pinned to its module's exact build.
- **Deploy differentially.** A deploy writes only the objects the store doesn't have, then records an immutable release that maps names to hashes.
- **Run any release, and roll back instantly.** Releases never change. Rolling back moves `HEAD`, with nothing rebuilt or re-uploaded.
- **Run old and new code in one VM.** Each function compiles to a BEAM module named after its hash (`harmony_<hash>`). New versions are new modules, so nothing is purged or replaced: calls already running keep their code, and the next call gets the new one.
- **Run in a fresh [libbeam](https://github.com/leostera/libbeam) Isolate** (optional), a BEAM that boots in milliseconds.

## Quickstart

You need Elixir 1.18+ on OTP 27+.

```sh
git clone https://github.com/leostera/harmony.git && cd harmony
mix deps.get && mix test
```

The [greeter example](examples/greeter) is three versions of one ordinary Elixir module:

```elixir
defmodule Greeter do
  def main(name), do: greeting(name)

  def greeting(name), do: "Hello, " <> name <> punctuation()

  defp punctuation, do: "!"

  def health(_input), do: "ok"
end
```

v2 changes `"Hello, "` to `"Howdy, "`. v3 renames `greeting/1` to `salute/1` and `name` to `who`.

```console
$ mix harmony.deploy examples/greeter/v1
Release 1
  objects: 4 new, 0 reused, 2480 bytes written
  + Greeter.greeting/1
  + Greeter.health/1
  + Greeter.main/1
  + Greeter.punctuation/0

$ mix harmony.deploy examples/greeter/v2
Release 2 (was 1)
  objects: 2 new, 2 reused, 1328 bytes written
  ~ Greeter.greeting/1
  ~ Greeter.main/1

$ mix harmony.deploy examples/greeter/v3
Release 3 (was 2)
  objects: 0 new, 4 reused, 0 bytes written
  > Greeter.greeting/1 -> Greeter.salute/1 (same code)
```

`main/1` changed in release 2 even though its source didn't, because it calls `greeting/1`, whose hash changed. Release 3 wrote nothing.

Run, inspect and roll back:

```console
$ mix harmony.run Greeter.main Joe
Howdy, Joe!

$ mix harmony.run Greeter.main Joe --release 1
Hello, Joe!

$ mix harmony.log
* 3  Greeter.health/1@59fdf02080 Greeter.main/1@98fdbfb7ff Greeter.punctuation/0@f08ce8b3c7 Greeter.salute/1@fe19c41165
  2  Greeter.greeting/1@fe19c41165 Greeter.health/1@59fdf02080 Greeter.main/1@98fdbfb7ff Greeter.punctuation/0@f08ce8b3c7
  1  Greeter.greeting/1@1e7b3f9e14 Greeter.health/1@59fdf02080 Greeter.main/1@39321f6553 Greeter.punctuation/0@f08ce8b3c7

$ mix harmony.rollback 1 && mix harmony.run Greeter.main Joe
Release 1 is current
Hello, Joe!
```

The [mixed example](examples/mixed) is Elixir calling a recursive Erlang module, which calls OTP's `lists`:

```console
$ mix harmony.deploy examples/mixed --store /tmp/mixed
Release 1
  objects: 9 new (4 from libraries), 0 reused, 6656 bytes written
  ...
$ mix harmony.run Shouter.main joe --store /tmp/mixed
HEY JOE!
$ mix harmony.run Shouter.total 100 --store /tmp/mixed
1 + ... + 100 = 5050
```

The [words example](examples/words) uses Elixir's standard library:

```elixir
def main(text), do: text |> String.split() |> Enum.map(&String.capitalize/1) |> Enum.join(" ")
```

```console
$ mix harmony.deploy examples/words --store /tmp/words
Release 1
  objects: 832 new (831 from libraries), 0 reused, 969304 bytes written
  pinned: 38 library functions called by name (mix harmony.hash --pinned lists them)
  + Words.main/1
$ mix harmony.run Words.main "hello big world" --store /tmp/words
Hello Big World
```

That one line reaches 845 library functions: `Enum.map/2` dispatches through `Enumerable` to every implementation, and error paths reach `Inspect` and `:io_lib_format`. Harmony hashes them once, so the next release that uses them writes nothing for them.

### In your own project

```elixir
# mix.exs
{:harmony, github: "leostera/harmony", only: :dev, runtime: false}
```

With no paths, `mix harmony.deploy` and `mix harmony.hash` compile the current project and read its `ebin`.

### Commands

| Command | Does |
| --- | --- |
| `mix harmony.hash [PATH...]` | print each function's hash (`--library`, `--pinned` for library functions) |
| `mix harmony.deploy [PATH...]` | write new objects and a new release |
| `mix harmony.run NAME [INPUT]` | call `NAME` (e.g. `Greeter.main`, `:text.shout`) with `INPUT` as a binary |
| `mix harmony.log` | list releases |
| `mix harmony.rollback N` | make release `N` current |

A PATH is a `.beam` file, a directory of them such as an `ebin` (that's how Gleam projects come in: `build/dev/erlang/<app>/ebin`), or an `.ex` or `.erl` source, which Harmony compiles first. Every command takes `--store DIR` (default `.harmony`).

## The subset

Harmony reads any BEAM module compiled with `debug_info` (the default in Mix, Rebar3 and Gleam), as long as:

- **every call reaches a function that exists**, in your code or on the code path.
- **your module names are only used to call functions.** No structs, protocols, exceptions, `__MODULE__`, `apply/3` or a module chosen at runtime (`mod.f()`) in your own code. In Erlang that also rules out `?MODULE` and atoms that happen to equal one of your module names.

Anything else is refused with the function and the reason:

```text
M.f/1 calls Enum.nope/1, which isn't defined
M.__struct__/0 uses the module M as a value (structs, protocols, exceptions, __MODULE__ and apply/3 aren't supported); your module names can only be used to call functions
```

The second rule is what makes per-function objects sound. BEAM languages use module names as values (a struct carries its module, protocols dispatch on it), and your modules stop existing under their names once each function lives in a module named after its hash.

### Library code

Calls outside your code reach one of three kinds of function:

- **Hashed.** A library function that would pass the rules above is read from the code path and hashed like your code, callees first. `Enum.map/2`, `String.split/1` and `:lists.seq/2` are hashed.
- **Primitive.** Built-in functions of any module (`:erlang`, `lists:reverse/2`, `maps:get/2`) and modules preloaded into the VM are called as they are.
- **Pinned.** A library function that can't be hashed is called by name: dispatch on a module chosen at runtime (`:file.close/1`), `apply/3`, a NIF, or a private function that calls one of those. The caller's hash covers the MD5 of the pinned function's module, and the runtime refuses to run a release on a VM whose module differs:

  ```text
  this release was built against Enum 0000000000, but this VM has c0fc26bcb8; deploy again from this VM
  ```

Library modules can be data, like an exception's struct name or `Enum` itself, because they keep their names. They're pinned the same way.

## How it works

1. **Read** each BEAM file's Erlang abstract code from its `debug_info` chunk ([`Harmony.Beam`](lib/harmony/beam.ex)). This is the compiled program after macro expansion, from any BEAM language. Harmony doesn't hash raw instructions: the compiler optimizes a whole module at once, so a function's instructions can change when a neighbour changes.
2. **Check and normalize** each function ([`Harmony.Codebase`](lib/harmony/codebase.ex)). Apply the subset rules, drop line numbers, rename variables by first use, and mark every call.
3. **Pull in libraries.** Read each library function a call reaches from the code path and normalize it the same way, until the closure is complete. Decide which are hashed and which are pinned.
4. **Hash** callees first. Recursive groups are hashed together: members are ordered by their shape, and each member's hash is the group's hash plus its position in it. A call inside a hash is the callee's hash, or the name of a pinned function, whose module's MD5 is in the hash too.
5. **Compile** each unique hash to one BEAM module, `harmony_<hash>`, exporting `run/N`, from the same normalized code that was hashed. An object's bytes depend only on its hash ([`Harmony.Object`](lib/harmony/object.ex)).
6. **Deploy** into an append-only store ([`Harmony.Store`](lib/harmony/store.ex)):

   ```text
   .harmony/objects/<hash>.beam   one function, written once and never changed
   .harmony/releases/<n>.json     names -> hashes, the call graph, and pinned modules by MD5
   .harmony/HEAD                  the current release
   ```

   Objects are written first, then the release, then `HEAD` is moved atomically. A failed deploy never changes the current release.
7. **Run** a name: look it up in a release, walk the call graph to its closure, check the VM has each pinned module at its MD5 and each object's module matches its hash, load what isn't loaded, and call it ([`Harmony.Runtime`](lib/harmony/runtime.ex)).

### On libbeam

[libbeam](https://github.com/leostera/libbeam) is an embeddable BEAM where each Isolate is a separate, fast-booting world. Harmony can run any release's closure in a fresh Isolate:

```sh
git clone https://github.com/leostera/libbeam.git ../libbeam   # needs Bazel and a C++17 compiler
HARMONY_LIBBEAM=1 mix deps.get
LIBBEAM_SOURCE=$PWD/../libbeam deps/libbeam_elixir/native/build.sh
HARMONY_LIBBEAM=1 mix harmony.run Greeter.main Joe --libbeam
HARMONY_LIBBEAM=1 mix test     # also runs the libbeam tests
```

libbeam loads a module group before an Isolate starts, so here a new release means a new Isolate with the full closure, not a live update. On the regular BEAM ([`Harmony.Runtime`](lib/harmony/runtime.ex)), versions coexist in one live VM.

An Isolate holds only Harmony objects, so hashed library code runs in it (`Shouter.total` runs OTP's `lists` in an Isolate), but a closure with pinned functions is refused, since the Isolate doesn't have their modules.

## Limits

- **Library closures are large.** Touching `Enum` reaches hundreds of functions. They're hashed once per store, but every build reads and hashes them again (about 3 s for the words example).
- **Pinning is coarse.** A pinned module's MD5 changes with any edit to that module, so its callers rehash even if the function they call didn't change.
- **Hashes depend on the compiler.** A new Elixir or OTP may compile the same source to different abstract code, and so to new hashes.
- **No line numbers in stack traces**, since objects are compiled from normalized code.
- **libbeam can't run pinned code**, and its loader rejects some functions compiled without line numbers that the BEAM accepts (`:io_lib.write_string_bin/3`, for one).
- **One module per function** is the simplest mapping onto the BEAM, not an efficient one.
- **No garbage collection** of old objects, and **no distribution**: syncing stores between machines (sending only the hashes a peer lacks) isn't built.
- **Trusted code only.** Hashes give identity and integrity, not safety.

## License

[MIT](LICENSE)
