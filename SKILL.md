---
name: zdoc
description: Look up Zig std lib declarations (signature + doc comment) by dotted path instead of grepping/sedding std source files. Use whenever you'd otherwise do `S=$(zig env ...); sed -n 'N,Mp' $S/Foo.zig` or grep through the Zig standard library to check a function signature, its doc comment, or where it's defined.
metadata:
  category: programming-language
  language: zig
---

# zdoc

A small Zig-native CLI that resolves a dotted symbol path (`Io.Reader.read`,
`ArrayList.append`, `mem.eql`, ...) directly to its signature, doc comment,
and `file:line`, by parsing the installed Zig std lib with `std.zig.Ast`.
Use it instead of manually locating and `sed`-ing std lib source files —
it's cheaper in tokens and doesn't require guessing line numbers.

## Usage

```sh
zdoc show <Module>            # module doc + everything it exposes
zdoc show <Path.To.Symbol>    # signature + doc comment (+ fields/members)
zdoc find [--docs] <text>     # search; prints dotted paths ready for `show`
zdoc which                    # print the resolved std lib directory
```

### Recommended workflow: drill down

Don't guess dotted paths — start at the module and walk down. Each level
prints what the next level can be:

```sh
zdoc show http                      # -> lists Client, Method, Status, ...
zdoc show http.Client               # -> lists fetch(), request(), FetchOptions, ...
zdoc show http.Client.fetch         # -> signature: takes FetchOptions
zdoc show http.Client.FetchOptions  # -> every field, with types and defaults
```

This is the fastest path from "I need to do X" to a compiling call, and it
never requires reading a std source file.

### `show` — exact lookup

Path segments are dotted, matching how you'd reference the symbol through
`std` (a leading `std.` is optional and stripped automatically):

```sh
zdoc show Io.Reader.readSliceAll
zdoc show mem.eql
zdoc show fmt.allocPrint
zdoc show fs.path.dirname
zdoc show process.fatal
zdoc show ArrayList.append
zdoc show ArrayList.initCapacity
zdoc show StringHashMap.get
zdoc show std.Thread.spawn
```

Output (paths are always absolute — safe to feed straight into a file-read
tool):

```
Io.Reader.readSliceAll  (/opt/homebrew/.../lib/zig/std/Io/Reader.zig:660)

Fill `buffer` with the next `buffer.len` bytes from the stream, advancing
the seek position.
...

pub fn readSliceAll(r: *Reader, buffer: []u8) Error!void
```

If the path resolves to a namespace (struct/enum/union, or a generic factory
function like `pub fn ArrayList(comptime T: type) type { ... }`), the
declaration line is truncated at its opening brace and followed by what it
contains, so you know what to `show` next instead of guessing:

- **`Fields:`** — struct fields, enum tags and union variants, with their
  types and default values. For an options struct or an enum these *are*
  the API, so read this before constructing a value:

  ```
  http.Client.FetchOptions  (/opt/homebrew/.../std/http/Client.zig:1754)

  pub const FetchOptions = struct { ... }

  Fields (/opt/homebrew/.../std/http/Client.zig):
    redirect_behavior: ?Request.RedirectBehavior = null
    location: Location
    method: ?http.Method = null
    payload: ?[]const u8 = null
    keep_alive: bool = true
    ...
  ```

- **`Declarations:`** — the `pub` names inside it, functions marked `()`.

Either section is omitted when empty, and neither is printed for ordinary
leaf functions/values.

### `find` — fuzzy discovery

Search by substring, case-insensitive. Every result is a **dotted path you
can paste straight into `show`** plus its location:

```sh
zdoc find readFileAlloc
```

```
Io.Dir.readFileAlloc  (/opt/homebrew/.../std/Io/Dir.zig:1326)
Io.Dir.readFileAllocOptions  (/opt/homebrew/.../std/Io/Dir.zig:1346)
```

Capped at 60 matches. `find` walks the namespace graph reachable from `std`,
so the path it prints is the canonical one — note that a symbol's dotted path
does **not** mirror its file location (`crypto/md5.zig` is reached as
`crypto.Md5`, and `crypto/pcurves/secp256k1.zig` as `crypto.ecc.Secp256k1`).
Never assemble a dotted path from a file path yourself; let `find` give it
to you.

By default only declaration *names* are matched, so a conceptual query can
come up empty (`find http` does not surface `http.Client`, whose name is
just `Client`). Two ways forward:

- `zdoc find --docs <text>` also searches doc comments, which catches
  symbols whose name doesn't contain the word (`find --docs monotonic`
  turns up `math.lerp`). Slower and noisier — use when a name search fails.
- `zdoc show <module>` when you know the area but not the name.

## How resolution works (and its limits)

- With a single segment naming a module file (`zdoc show http`), the module's
  `//!` header docs and full contents are printed.
- The first path segment is looked up as a `pub` member of `std.zig`'s root
  first — the canonical `std.X` spelling — and only then as a module file
  (`<seg>.zig`, `<seg>/<seg>.zig`). A dotted path is not a file path:
  `Deque` lives in `deque.zig` and `crypto.Md5` in `crypto/md5.zig`.
- Each subsequent segment is looked up as a member of the current
  namespace. A member can be a plain nested `struct`/`enum`/`union`, an
  `@import` of another file, or — for generic containers like
  `pub fn ArrayList(comptime T: type) type { return array_list.Aligned(T, null); }`
  — the tool follows the function's `return` expression through identifier
  aliases, `@import(...).Field` access, and function calls (up to 8 hops)
  to find the struct it ultimately produces.
- This is pure syntax parsing (`std.zig.Ast`), not comptime evaluation, so
  it can't resolve dynamic type factories that branch on comptime
  conditions in non-trivial ways. If `show` fails with "has no further
  members reachable from static analysis", fall back to `zdoc find` or a
  direct read of the file it did get to (the error message names it).
- `find` only reports what is reachable from the `std` root, which is the
  same thing `show` can address. Purely internal files that nothing
  re-exports are therefore not listed.
- A name that doesn't exist is a real "not found", not a bug — e.g.
  `ArrayHashMap` was removed in Zig 0.16 in favor of `array_hash_map.Auto`
  / `.String` / `.Custom`.

## Overriding the std lib path

By default the std dir is resolved via `zig env` (whatever `zig` is first
on `PATH`). Override with `--std <path>` or the `ZDOC_STD_DIR` environment
variable if you need to point at a different Zig install.
