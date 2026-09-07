const std = @import("std");
const Ast = std.zig.Ast;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var argv = args[1..];

    var std_dir_override: ?[]const u8 = init.environ_map.get("ZDOC_STD_DIR");
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "--std")) {
        if (argv.len < 2) std.process.fatal("--std requires a path argument", .{});
        std_dir_override = argv[1];
        argv = argv[2..];
    }

    if (argv.len == 0 or
        std.mem.eql(u8, argv[0], "help") or
        std.mem.eql(u8, argv[0], "--help") or
        std.mem.eql(u8, argv[0], "-h"))
    {
        try printUsage(io);
        return;
    }

    const cmd = argv[0];
    const rest = argv[1..];
    const std_dir_path = std_dir_override orelse try resolveStdDir(io, arena);

    if (std.mem.eql(u8, cmd, "show")) {
        if (rest.len < 1) std.process.fatal("usage: zdoc show <Path.To.Symbol>", .{});
        try cmdShow(io, arena, std_dir_path, rest[0]);
    } else if (std.mem.eql(u8, cmd, "find")) {
        var match_docs = false;
        var terms = rest;
        if (terms.len >= 1 and std.mem.eql(u8, terms[0], "--docs")) {
            match_docs = true;
            terms = terms[1..];
        }
        if (terms.len < 1) std.process.fatal("usage: zdoc find [--docs] <substring>", .{});
        try cmdFind(io, arena, std_dir_path, terms[0], match_docs);
    } else if (std.mem.eql(u8, cmd, "which")) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        try w.interface.print("{s}\n", .{std_dir_path});
        try w.interface.flush();
    } else {
        std.process.fatal("unknown command '{s}'; use 'show', 'find', or 'help'", .{cmd});
    }
}

fn printUsage(io: Io) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.print(
        \\zdoc - look up Zig std lib declarations without grepping source
        \\
        \\Usage:
        \\  zdoc show <Module>           Module docs + everything it exposes
        \\  zdoc show <Path.To.Symbol>   Signature, doc comment, fields and members
        \\  zdoc find [--docs] <text>    Search std lib; prints dotted paths for `show`
        \\  zdoc which                   Print the resolved std lib directory
        \\
        \\Options:
        \\  --std <path>                 Use this std dir instead of auto-detecting via `zig env`
        \\  --docs                       Make `find` search doc comments, not just names
        \\
        \\Examples:
        \\  zdoc show http                     # start here when you don't know the name
        \\  zdoc show http.Client.FetchOptions # every field, with types and defaults
        \\  zdoc show ArrayList.append
        \\  zdoc find readFileAlloc
        \\  zdoc find --docs "monotonic clock"
        \\
        \\Std lib directory is auto-detected via `zig env`. Override with --std <path>
        \\or the ZDOC_STD_DIR environment variable.
        \\
    , .{});
    try w.interface.flush();
}

fn resolveStdDir(io: Io, arena: Allocator) ![]const u8 {
    const result = std.process.run(arena, io, .{ .argv = &.{ "zig", "env" } }) catch |err|
        std.process.fatal(
            "failed to run `zig env` ({s}); is zig on PATH? Set ZDOC_STD_DIR or pass --std <path> instead",
            .{@errorName(err)},
        );

    const marker = ".std_dir = \"";
    const start = std.mem.indexOf(u8, result.stdout, marker) orelse
        std.process.fatal("could not parse `zig env` output to find std_dir", .{});
    const after = result.stdout[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, after, '"') orelse
        std.process.fatal("could not parse `zig env` output to find std_dir", .{});
    return after[0..end];
}

fn fileExists(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

fn isContainerDecl(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

fn importPathOf(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    const main_tok = tree.nodeMainToken(node);
    if (!std.mem.eql(u8, tree.tokenSlice(main_tok), "@import")) return null;

    var buf: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, node) orelse return null;
    if (params.len != 1) return null;

    const arg_src = tree.getNodeSource(params[0]);
    if (arg_src.len < 2 or arg_src[0] != '"') return null;
    const path = arg_src[1 .. arg_src.len - 1];
    // Module imports (`@import("builtin")`, `"root"`, `"std"`) name a module,
    // not a file next to this one, and cannot be followed on disk.
    if (!std.mem.endsWith(u8, path, ".zig")) return null;
    return path;
}

/// A namespace resolved to a concrete file + set of member declarations.
const Resolved = struct {
    tree: Ast,
    members: []const Ast.Node.Index,
    file_rel: []const u8,
};

fn joinRelative(arena: Allocator, cur_file_rel: []const u8, target: []const u8) ![]const u8 {
    const dir_part = std.fs.path.dirname(cur_file_rel);
    return if (dir_part) |d|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ d, target })
    else
        try arena.dupe(u8, target);
}

fn loadFile(io: Io, arena: Allocator, std_dir: Io.Dir, file_rel: []const u8) !Ast {
    const source = try std_dir.readFileAllocOptions(io, file_rel, arena, .limited(8 * 1024 * 1024), .of(u8), 0);
    return try Ast.parse(arena, source, .zig);
}

fn findReturnExpr(tree: Ast, block_node: Ast.Node.Index) ?Ast.Node.Index {
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&buf, block_node) orelse return null;
    for (stmts) |s| {
        if (tree.nodeTag(s) == .@"return") {
            if (tree.nodeData(s).opt_node.unwrap()) |expr| return expr;
        }
    }
    return null;
}

/// Resolves a declaration (fn or const) to the namespace it exposes: for a
/// plain `const X = struct {...}` that's the struct's members; for a generic
/// factory like `pub fn ArrayList(comptime T: type) type { return ...; }`
/// this follows the `return` expression (through identifier aliases, field
/// access on `@import`, and function calls) to find the struct it produces.
fn resolveContainerFromDecl(
    io: Io,
    arena: Allocator,
    std_dir: Io.Dir,
    tree: Ast,
    file_rel: []const u8,
    decl_node: Ast.Node.Index,
    depth: u32,
) anyerror!?Resolved {
    if (depth > 8) return null;

    var fn_buf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_buf, decl_node)) |_| {
        if (tree.nodeTag(decl_node) != .fn_decl) return null;
        const body = tree.nodeData(decl_node).node_and_node[1];
        const ret_expr = findReturnExpr(tree, body) orelse return null;
        return resolveExprToContainer(io, arena, std_dir, tree, file_rel, ret_expr, depth + 1);
    }

    if (tree.fullVarDecl(decl_node)) |vd| {
        const init_node = vd.ast.init_node.unwrap() orelse return null;
        return resolveExprToContainer(io, arena, std_dir, tree, file_rel, init_node, depth + 1);
    }

    return null;
}

fn resolveExprToContainer(
    io: Io,
    arena: Allocator,
    std_dir: Io.Dir,
    tree: Ast,
    file_rel: []const u8,
    expr: Ast.Node.Index,
    depth: u32,
) !?Resolved {
    if (depth > 8) return null;

    if (isContainerDecl(tree.nodeTag(expr))) {
        var buf2: [2]Ast.Node.Index = undefined;
        const cd = tree.fullContainerDecl(&buf2, expr).?;
        return .{
            .tree = tree,
            .members = try arena.dupe(Ast.Node.Index, cd.ast.members),
            .file_rel = file_rel,
        };
    }

    if (importPathOf(tree, expr)) |imp| {
        const target_file = try joinRelative(arena, file_rel, imp);
        const new_tree = loadFile(io, arena, std_dir, target_file) catch return null;
        return .{
            .tree = new_tree,
            .members = try arena.dupe(Ast.Node.Index, new_tree.rootDecls()),
            .file_rel = target_file,
        };
    }

    switch (tree.nodeTag(expr)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(expr));
            const roots = try arena.dupe(Ast.Node.Index, tree.rootDecls());
            const found = findMember(tree, roots, name) orelse return null;
            return resolveContainerFromDecl(io, arena, std_dir, tree, file_rel, found, depth + 1);
        },
        .field_access => {
            const pair = tree.nodeData(expr).node_and_token;
            const field_name = tree.tokenSlice(pair[1]);
            const target_file = (try resolveExprToFile(io, arena, std_dir, tree, file_rel, pair[0], depth + 1)) orelse return null;
            const new_tree = loadFile(io, arena, std_dir, target_file) catch return null;
            const new_roots = try arena.dupe(Ast.Node.Index, new_tree.rootDecls());
            const found = findMember(new_tree, new_roots, field_name) orelse return null;
            return resolveContainerFromDecl(io, arena, std_dir, new_tree, target_file, found, depth + 1);
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            var call_buf: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buf, expr) orelse return null;
            return resolveExprToContainer(io, arena, std_dir, tree, file_rel, call.ast.fn_expr, depth + 1);
        },
        else => return null,
    }
}

/// Like `resolveExprToContainer` but only chases the expression down to the
/// *file* it ultimately points into (used to resolve the left side of a
/// `namespace.Field` access), without looking up `Field` itself.
fn resolveExprToFile(
    io: Io,
    arena: Allocator,
    std_dir: Io.Dir,
    tree: Ast,
    file_rel: []const u8,
    expr: Ast.Node.Index,
    depth: u32,
) !?[]const u8 {
    if (depth > 8) return null;

    if (importPathOf(tree, expr)) |imp| return try joinRelative(arena, file_rel, imp);

    switch (tree.nodeTag(expr)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(expr));
            const roots = try arena.dupe(Ast.Node.Index, tree.rootDecls());
            const found = findMember(tree, roots, name) orelse return null;
            const vd = tree.fullVarDecl(found) orelse return null;
            const init_node = vd.ast.init_node.unwrap() orelse return null;
            return resolveExprToFile(io, arena, std_dir, tree, file_rel, init_node, depth + 1);
        },
        .field_access => {
            const lhs = tree.nodeData(expr).node_and_token[0];
            return resolveExprToFile(io, arena, std_dir, tree, file_rel, lhs, depth + 1);
        },
        else => return null,
    }
}

fn findMember(tree: Ast, members: []const Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    for (members) |m| {
        var fn_buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&fn_buf, m)) |proto| {
            const name_tok = proto.name_token orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(name_tok), name)) return m;
            continue;
        }
        if (tree.fullVarDecl(m)) |vd| {
            const name_tok = vd.ast.mut_token + 1;
            if (tree.tokenTag(name_tok) == .identifier and std.mem.eql(u8, tree.tokenSlice(name_tok), name)) {
                return m;
            }
        }
    }
    return null;
}

fn collectDocComment(arena: Allocator, tree: Ast, first_tok: Ast.TokenIndex) ![]const u8 {
    if (first_tok == 0) return "";
    var start = first_tok;
    while (start > 0 and tree.tokenTag(start - 1) == .doc_comment) : (start -= 1) {}
    if (start == first_tok) return "";

    var list: std.ArrayList(u8) = .empty;
    var i = start;
    while (i < first_tok) : (i += 1) {
        var text = tree.tokenSlice(i);
        if (std.mem.startsWith(u8, text, "///")) text = text[3..];
        if (text.len > 0 and text[0] == ' ') text = text[1..];
        try list.appendSlice(arena, text);
        try list.append(arena, '\n');
    }
    return list.items;
}

/// Renders one struct field / enum tag / union variant as a single line,
/// including its type and default value when present. For an options struct
/// or an enum these fields *are* the API, so they matter more than the decls.
fn printField(out: *std.Io.Writer, tree: Ast, field_in: Ast.full.ContainerField) !void {
    // A bare enum tag (`GET,`) parses as "tuple-like" with the tag name
    // doubling as its type expression; this drops the bogus type so it
    // prints as `GET` rather than `GET: GET`.
    var field = field_in;
    field.convertToNonTupleLike(&tree);

    const name = tree.tokenSlice(field.ast.main_token);
    const type_node = field.ast.type_expr.unwrap();
    const value_node = field.ast.value_expr.unwrap();

    if (type_node) |tn| {
        if (value_node) |vn| {
            try out.print("  {s}: {s} = {s}\n", .{ name, tree.getNodeSource(tn), tree.getNodeSource(vn) });
        } else {
            try out.print("  {s}: {s}\n", .{ name, tree.getNodeSource(tn) });
        }
        return;
    }

    // No type expression: a plain enum tag, optionally with an explicit value.
    if (value_node) |vn| {
        try out.print("  {s} = {s}\n", .{ name, tree.getNodeSource(vn) });
    } else {
        try out.print("  {s}\n", .{name});
    }
}

/// Lists what a namespace exposes so an agent that lands on it knows what to
/// `show` next: first the fields/enum tags/union variants (with types and
/// defaults), then the `pub` declarations, with functions marked `()`.
fn printMembers(out: *std.Io.Writer, tree: Ast, members: []const Ast.Node.Index, std_dir_path: []const u8, file_rel: []const u8) !void {
    const max_shown = 200;

    var field_count: usize = 0;
    for (members) |m| {
        const field = tree.fullContainerField(m) orelse continue;
        if (field_count == 0) try out.print("\nFields ({s}/{s}):\n", .{ std_dir_path, file_rel });
        if (field_count >= max_shown) {
            try out.print("  ... (truncated at {d})\n", .{max_shown});
            break;
        }
        try printField(out, tree, field);
        field_count += 1;
    }

    var decl_count: usize = 0;
    for (members) |m| {
        var fn_buf: [1]Ast.Node.Index = undefined;
        var name: []const u8 = undefined;
        var is_fn = false;

        if (tree.fullFnProto(&fn_buf, m)) |proto| {
            if (proto.visib_token == null) continue;
            const name_tok = proto.name_token orelse continue;
            name = tree.tokenSlice(name_tok);
            is_fn = true;
        } else if (tree.fullVarDecl(m)) |vd| {
            if (vd.visib_token == null) continue;
            const name_tok = vd.ast.mut_token + 1;
            if (tree.tokenTag(name_tok) != .identifier) continue;
            name = tree.tokenSlice(name_tok);
        } else continue;

        if (decl_count == 0) try out.print("\nDeclarations ({s}/{s}):\n", .{ std_dir_path, file_rel });
        if (decl_count >= max_shown) {
            try out.print("  ... (truncated at {d})\n", .{max_shown});
            break;
        }
        if (is_fn) try out.print("  {s}()\n", .{name}) else try out.print("  {s}\n", .{name});
        decl_count += 1;
    }
}

fn printSymbol(
    io: Io,
    std_dir: Io.Dir,
    std_dir_path: []const u8,
    tree: Ast,
    node: Ast.Node.Index,
    file_rel: []const u8,
    dotted: []const u8,
    arena: Allocator,
) !void {
    const first_tok = tree.firstToken(node);
    const loc = tree.tokenLocation(0, first_tok);

    var stdout_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &w.interface;

    try out.print("{s}  ({s}/{s}:{d})\n\n", .{ dotted, std_dir_path, file_rel, loc.line + 1 });

    const doc = try collectDocComment(arena, tree, first_tok);
    if (doc.len > 0) try out.print("{s}\n", .{doc});

    var fn_buf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_buf, node)) |proto| {
        try out.print("{s}\n", .{tree.getNodeSource(proto.ast.proto_node)});
    } else if (tree.fullVarDecl(node)) |_| {
        const full_src = tree.getNodeSource(node);
        if (std.mem.indexOfScalar(u8, full_src, '{')) |brace_idx| {
            const head = std.mem.trimEnd(u8, full_src[0..brace_idx], " \t\n");
            try out.print("{s} {{ ... }}\n", .{head});
        } else {
            try out.print("{s}\n", .{full_src});
        }
    } else {
        try out.print("{s}\n", .{tree.getNodeSource(node)});
    }

    // Best-effort: if this decl (directly, or as a generic factory function)
    // resolves to a namespace, list its members so the agent knows what to
    // `show` next. Silently does nothing for ordinary leaf functions/values.
    if (try resolveContainerFromDecl(io, arena, std_dir, tree, file_rel, node, 0)) |resolved| {
        // Hopping into another file means this decl re-exports a module
        // (`pub const http = @import("http.zig")`), so surface that module's
        // own `//!` docs too.
        if (!std.mem.eql(u8, resolved.file_rel, file_rel)) {
            try printModuleDocs(out, resolved.tree);
        }
        try printMembers(out, resolved.tree, resolved.members, std_dir_path, resolved.file_rel);
    }

    try out.flush();
}

/// Prints a file's `//!` header docs, which describe the module as a whole
/// and often say which API to reach for.
fn printModuleDocs(out: *std.Io.Writer, tree: Ast) !void {
    var tok: Ast.TokenIndex = 0;
    var wrote = false;
    while (tree.tokenTag(tok) == .container_doc_comment) : (tok += 1) {
        if (!wrote) {
            try out.print("\n", .{});
            wrote = true;
        }
        var text = tree.tokenSlice(tok);
        if (std.mem.startsWith(u8, text, "//!")) text = text[3..];
        if (text.len > 0 and text[0] == ' ') text = text[1..];
        try out.print("{s}\n", .{text});
    }
}

/// Prints the contents of a whole module file (`zdoc show http`): its
/// top-of-file `//!` doc comment, then everything it exposes.
fn printModule(
    io: Io,
    arena: Allocator,
    std_dir: Io.Dir,
    std_dir_path: []const u8,
    file_rel: []const u8,
    dotted: []const u8,
) !void {
    const tree = try loadFile(io, arena, std_dir, file_rel);

    var stdout_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &w.interface;

    try out.print("{s}  (module: {s}/{s})\n", .{ dotted, std_dir_path, file_rel });
    try printModuleDocs(out, tree);

    const members = try arena.dupe(Ast.Node.Index, tree.rootDecls());
    try printMembers(out, tree, members, std_dir_path, file_rel);
    try out.flush();
}

fn cmdShow(io: Io, arena: Allocator, std_dir_path: []const u8, dotted: []const u8) !void {
    var seg_it = std.mem.splitScalar(u8, dotted, '.');
    var segs: std.ArrayList([]const u8) = .empty;
    while (seg_it.next()) |s| {
        if (s.len == 0) continue;
        try segs.append(arena, s);
    }
    if (segs.items.len == 0) std.process.fatal("empty symbol path", .{});

    var path_segs = segs.items;
    if (std.mem.eql(u8, path_segs[0], "std") and path_segs.len > 1) {
        path_segs = path_segs[1..];
    }

    const std_dir = Io.Dir.openDirAbsolute(io, std_dir_path, .{}) catch |err|
        std.process.fatal("cannot open zig std dir '{s}': {s}", .{ std_dir_path, @errorName(err) });
    defer std_dir.close(io);

    const first = path_segs[0];
    var cur_file_rel: []const u8 = undefined;
    var remaining: []const []const u8 = undefined;

    const direct = try std.fmt.allocPrint(arena, "{s}.zig", .{first});
    const nested = try std.fmt.allocPrint(arena, "{s}/{s}.zig", .{ first, first });

    // A `pub` member of std.zig's root is tried first, because that is the
    // canonical `std.X` spelling and it may disagree with the file layout:
    // `Deque` lives in `deque.zig`, and on a case-insensitive filesystem a
    // file probe for "Deque.zig" would wrongly match it and then fail to
    // find the members nested inside.
    const std_root_has_first = blk: {
        const t = loadFile(io, arena, std_dir, "std.zig") catch break :blk false;
        const roots = try arena.dupe(Ast.Node.Index, t.rootDecls());
        break :blk findMember(t, roots, first) != null;
    };

    if (std_root_has_first) {
        cur_file_rel = "std.zig";
        remaining = path_segs;
    } else if (fileExists(io, std_dir, direct)) {
        cur_file_rel = direct;
        remaining = path_segs[1..];
    } else if (fileExists(io, std_dir, nested)) {
        cur_file_rel = nested;
        remaining = path_segs[1..];
    } else {
        std.process.fatal(
            "no top-level std module '{s}' (looked for {s} and {s}); try `zdoc find {s}`",
            .{ first, direct, nested, first },
        );
    }

    if (remaining.len == 0) {
        // The path names a whole module file (`zdoc show http`). List what it
        // exposes rather than making the agent guess a member name.
        return printModule(io, arena, std_dir, std_dir_path, cur_file_rel, dotted);
    }

    var tree = try loadFile(io, arena, std_dir, cur_file_rel);
    var members: []const Ast.Node.Index = try arena.dupe(Ast.Node.Index, tree.rootDecls());

    var target: ?Ast.Node.Index = null;

    var idx: usize = 0;
    while (idx < remaining.len) : (idx += 1) {
        const seg = remaining[idx];
        const is_last = idx == remaining.len - 1;
        const found = findMember(tree, members, seg) orelse
            std.process.fatal("'{s}' not found in {s} (resolving '{s}')", .{ seg, cur_file_rel, dotted });

        if (is_last) {
            target = found;
            break;
        }

        const resolved = (try resolveContainerFromDecl(io, arena, std_dir, tree, cur_file_rel, found, 0)) orelse
            std.process.fatal("'{s}' has no further members reachable from static analysis (in '{s}')", .{ seg, dotted });

        tree = resolved.tree;
        members = resolved.members;
        cur_file_rel = resolved.file_rel;
    }

    try printSymbol(io, std_dir, std_dir_path, tree, target.?, cur_file_rel, dotted, arena);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}


fn joinDotted(arena: Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return arena.dupe(u8, name);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, name });
}

const FindCtx = struct {
    out: *std.Io.Writer,
    arena: Allocator,
    io: Io,
    std_dir: Io.Dir,
    std_dir_path: []const u8,
    query: []const u8,
    match_docs: bool,
    /// Containers already walked, so shared namespaces and alias cycles are
    /// visited once. Keyed by file plus the container's first member node.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    matches: usize = 0,
    max_matches: usize = 60,

    fn full(ctx: *const FindCtx) bool {
        return ctx.matches >= ctx.max_matches;
    }
};

/// Walks the namespace graph reachable from `std`, rather than the file tree,
/// so every emitted path is one `show` can actually follow. A file's location
/// does not imply its dotted path: `crypto/md5.zig` is reached as `crypto.Md5`,
/// and files under `crypto/pcurves/` only through aliases in `crypto.zig`.
fn findInNamespace(
    ctx: *FindCtx,
    tree: Ast,
    file_rel: []const u8,
    members: []const Ast.Node.Index,
    prefix: []const u8,
    depth: u32,
) anyerror!void {
    if (depth > 8) return;

    for (members) |m| {
        if (ctx.full()) return;

        var fn_buf: [1]Ast.Node.Index = undefined;
        var name: []const u8 = undefined;

        if (tree.fullFnProto(&fn_buf, m)) |proto| {
            if (proto.visib_token == null) continue;
            const name_tok = proto.name_token orelse continue;
            name = tree.tokenSlice(name_tok);
        } else if (tree.fullVarDecl(m)) |vd| {
            if (vd.visib_token == null) continue;
            const name_tok = vd.ast.mut_token + 1;
            if (tree.tokenTag(name_tok) != .identifier) continue;
            name = tree.tokenSlice(name_tok);
        } else continue;

        const dotted = try joinDotted(ctx.arena, prefix, name);

        var matched = containsIgnoreCase(name, ctx.query);
        if (!matched and ctx.match_docs) {
            const doc = try collectDocComment(ctx.arena, tree, tree.firstToken(m));
            matched = doc.len > 0 and containsIgnoreCase(doc, ctx.query);
        }

        if (matched) {
            const loc = tree.tokenLocation(0, tree.firstToken(m));
            try ctx.out.print("{s}  ({s}/{s}:{d})\n", .{ dotted, ctx.std_dir_path, file_rel, loc.line + 1 });
            ctx.matches += 1;
            if (ctx.full()) return;
        }

        // Descend if this decl names a namespace: a nested container, an
        // `@import`, an alias chain, or a generic factory's returned struct.
        const resolved = (try resolveContainerFromDecl(ctx.io, ctx.arena, ctx.std_dir, tree, file_rel, m, 0)) orelse continue;
        if (resolved.members.len == 0) continue;

        const key = try std.fmt.allocPrint(ctx.arena, "{s}#{d}", .{
            resolved.file_rel,
            @intFromEnum(resolved.members[0]),
        });
        if ((try ctx.seen.getOrPut(ctx.arena, key)).found_existing) continue;

        try findInNamespace(ctx, resolved.tree, resolved.file_rel, resolved.members, dotted, depth + 1);
    }
}

fn cmdFind(io: Io, arena: Allocator, std_dir_path: []const u8, query: []const u8, match_docs: bool) !void {
    const std_dir = Io.Dir.openDirAbsolute(io, std_dir_path, .{ .iterate = true }) catch |err|
        std.process.fatal("cannot open zig std dir '{s}': {s}", .{ std_dir_path, @errorName(err) });
    defer std_dir.close(io);

    var stdout_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &w.interface;

    var ctx: FindCtx = .{
        .out = out,
        .arena = arena,
        .io = io,
        .std_dir = std_dir,
        .std_dir_path = std_dir_path,
        .query = query,
        .match_docs = match_docs,
    };

    const tree = try loadFile(io, arena, std_dir, "std.zig");
    const roots = try arena.dupe(Ast.Node.Index, tree.rootDecls());
    try findInNamespace(&ctx, tree, "std.zig", roots, "", 0);

    if (ctx.matches == 0) {
        try out.print("no matches for '{s}'\n", .{query});
        if (!match_docs) try out.print("try `zdoc find --docs {s}` to search doc comments too\n", .{query});
    } else if (ctx.full()) {
        try out.print("... truncated at {d} matches; refine your query\n", .{ctx.max_matches});
    }
    try out.flush();
}
