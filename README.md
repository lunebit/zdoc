# zdoc

Offline lookup for the Zig standard library, built for coding agents.

`zdoc show ArrayList.append` prints the signature, the doc comment and the
exact `file:line` — in 6 lines instead of the 2 499-line source file an agent
would otherwise have to read.

```
$ zdoc show ArrayList.append
ArrayList.append  (/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/array_list.zig:903)

Extend the list by 1 element. Allocates more memory as necessary.
Invalidates element pointers if additional memory is needed.

pub fn append(self: *Self, gpa: Allocator, item: T) Allocator.Error!void
```

## Why

An LLM writing Zig has two bad options when it needs an API it isn't sure
about:

1. **Recall it from training data.** Zig's standard library changes fast.
   0.16 alone moved `std.net` into `std.Io.net`, removed `std.Thread.Pool`
   and `std.time.sleep`, and made `ArrayList` allocator-parameterised. A
   model trained before the release confidently writes code that no longer
   compiles.
2. **Read the source.** Correct, but expensive: the agent runs
   `zig env`, guesses a file, greps for a name, then `sed`s a line range —
   several tool round-trips, and any file it opens costs thousands of tokens.

`zdoc` removes both problems. It parses the std library **actually installed
on the machine**, so answers match the compiler in use rather than the
model's memory, and it returns only the declaration asked for.

Measured against reading the file the symbol lives in:

| Query | `zdoc` output | Source file | Ratio |
|---|---|---|---|
| `Io.Dir.readFileAlloc` | 911 B | `Io/Dir.zig` — 80 457 B | 88× |
| `ArrayList.append` | 287 B | `array_list.zig` — 97 347 B | 339× |
| `http.Client.FetchOptions` | 711 B | `http/Client.zig` — 71 392 B | 100× |

It needs no network, so it works in sandboxed and air-gapped environments
where documentation sites are unreachable.

## Requirements

- Zig 0.16.0 to build.
- A `zig` on `PATH` at run time (used to locate the std library), or an
  explicit `--std` / `ZDOC_STD_DIR`.

## Install

```sh
git clone https://github.com/lunebit/zdoc.git && cd zdoc
zig build -Drelease
```

The binary lands in `zig-out/bin/zdoc`. Put it on your `PATH`:

```sh
ln -s "$PWD/zig-out/bin/zdoc" /usr/local/bin/zdoc
```

Upgrading your Zig toolchain does **not** require a rebuild — the std
library directory is resolved at run time via `zig env`, not baked in.

## Usage

```
zdoc show <Module>            Module docs + everything it exposes
zdoc show <Path.To.Symbol>    Signature, doc comment, fields and members
zdoc find [--docs] <text>     Search; prints dotted paths ready for `show`
zdoc which                    Print the resolved std lib directory
```

Options:

| Flag | Meaning |
|---|---|
| `--std <path>` | Use this std directory instead of asking `zig env` |
| `--docs` | Make `find` search doc comment text, not just names |

`ZDOC_STD_DIR` does the same as `--std`.

### The intended workflow: drill down

Paths are dotted, exactly as you would write them through `std` (a leading
`std.` is optional). Rather than guessing a path, start at the module —
every level tells you what the next level can be:

```sh
zdoc show http                      # -> Client, Server, Method, Status, ...
zdoc show http.Client               # -> fetch(), request(), FetchOptions, ...
zdoc show http.Client.fetch         # -> pub fn fetch(client: *Client, options: FetchOptions) ...
zdoc show http.Client.FetchOptions  # -> every field, with types and defaults
```

That last step is the one that matters most in practice: for an options
struct the **fields are the API**, and they are what a model is most likely
to hallucinate.

```
$ zdoc show http.Client.FetchOptions
http.Client.FetchOptions  (/opt/.../std/http/Client.zig:1754)

pub const FetchOptions = struct { ... }

Fields (/opt/.../std/http/Client.zig):
  redirect_buffer: ?[]u8 = null
  redirect_behavior: ?Request.RedirectBehavior = null
  response_writer: ?*Writer = null
  location: Location
  method: ?http.Method = null
  payload: ?[]const u8 = null
  keep_alive: bool = true
  ...

Declarations (/opt/.../std/http/Client.zig):
  Location
```

Enum tags and union variants are listed the same way, so
`zdoc show http.Method` answers "is it `.GET` or `.get`?" directly.

### Searching

Every `find` result is a dotted path that can be pasted straight back into
`show`:

```sh
$ zdoc find readFileAlloc
Io.Dir.ReadFileAllocError  (/opt/.../std/Io/Dir.zig:1312)
Io.Dir.readFileAlloc  (/opt/.../std/Io/Dir.zig:1326)
Io.Dir.readFileAllocOptions  (/opt/.../std/Io/Dir.zig:1346)
```

`find` matches declaration names by default. When a conceptual query finds
nothing, `--docs` also searches doc comment text — it will surface
`math.lerp` for `--docs monotonic`, whose name contains no such word.

## Using it with agents

`zdoc` is a plain CLI, so any agent that can run shell commands can use it.
The only integration needed is a line in that agent's instruction file
telling it to prefer `zdoc` over reading std sources.

### Claude Code

This repository is also a skill: `SKILL.md` at its root is written for the
agent. Link the directory into your skills folder and Claude Code will load
it on demand:

```sh
ln -s "$PWD" ~/.claude/skills/zdoc          # available in every project
# or, for one project:
mkdir -p .claude/skills && ln -s "$PWD" .claude/skills/zdoc
```

Claude then invokes it automatically when a Zig std question comes up, and
you can also trigger it explicitly with `/zdoc`.

### GitHub Copilot

Add to `.github/copilot-instructions.md` (repository-wide custom
instructions, honoured by Copilot Chat and the coding agent):

```markdown
When you need a Zig standard library signature, doc comment or field list,
run `zdoc show <Path.To.Symbol>` (e.g. `zdoc show ArrayList.append`) or
`zdoc find <name>` in the terminal instead of reading files under the Zig
std directory or recalling the API from memory. Zig's std library changes
between releases; `zdoc` reports the version actually installed.
```

### Cursor

Same text, as a rule file — `.cursor/rules/zdoc.mdc`:

```markdown
---
description: Look up Zig std APIs with zdoc instead of guessing
alwaysApply: true
---
Use `zdoc show <Path.To.Symbol>` / `zdoc find <name>` for any Zig standard
library question. Start from `zdoc show <module>` and drill down.
```

### Codex CLI, Jules, Devin, and others using `AGENTS.md`

Drop the same paragraph into `AGENTS.md` at the repository root.

### Any other agent

Put this in whatever system prompt or rules file the tool supports:

```
Zig std lookups: prefer `zdoc show <Path.To.Symbol>` and `zdoc find <name>`
over reading std source files or answering from memory. Drill down from
`zdoc show <module>`. Paths from `find` can be passed directly to `show`.
```

Two properties make this reliable in an agent loop: output is small enough
to keep in context, and paths printed by `find` always resolve in `show`, so
the agent can chain the two without a human in between.

## How it works

`zdoc` parses std library sources with `std.zig.Ast` — the same parser the
compiler uses — and resolves a dotted path by walking declarations:

- The first segment is looked up as a `pub` member of `std.zig`'s root (the
  canonical `std.X` spelling), falling back to a module file of that name.
- Each further segment is a member of the current namespace: a nested
  `struct`/`enum`/`union`, an `@import` of another file, an alias chain, or
  a generic factory. For factories such as
  `pub fn ArrayList(comptime T: type) type { return array_list.Aligned(T, null); }`
  it follows the `return` expression through identifier aliases,
  `@import(...).Field` access and calls to reach the struct produced.
- `find` walks the namespace graph reachable from `std` rather than the file
  tree, because a symbol's dotted path does not mirror its location on disk:
  `crypto/md5.zig` is reached as `crypto.Md5`, and
  `crypto/pcurves/secp256k1.zig` as `crypto.ecc.Secp256k1`. This is what
  guarantees that `find` output round-trips into `show`.

## Limitations

- Syntax analysis, not comptime evaluation. Type factories that branch on
  comptime conditions in non-trivial ways cannot be followed; `show` says so
  and names the file it reached.
- `find` reports only what is reachable from the `std` root — the same set
  `show` can address. Purely internal files that nothing re-exports are not
  listed.
- Standard library only. Project-local sources are out of scope.
- A missing name is usually a real answer, not a failure:
  `zdoc show ArrayHashMap.get` fails because 0.16 replaced it with
  `array_hash_map.Auto` / `.String` / `.Custom`.

## Development

```sh
zig build          # debug build into zig-out/bin/zdoc
zig build run -- show mem.eql
```

The whole implementation is a single file, `src/main.zig`.
