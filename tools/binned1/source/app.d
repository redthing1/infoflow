import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm.comparison;
import tsparse;

import lang;

class AstDumpVisitor : ParseTreeVisitor {
	import d_tree_sitter;

	this(ParsedModule pm) {
		super(pm);
	}

	public override bool visit(Node node, uint depth) {
		auto slice = pm.source[node.start_byte .. node.end_byte];

		for (int i = 0; i < depth; i++) {
			write("  ");
		}

		// writefln("> [%s], %s", node.kind, slice);
		writefln("> [%s], %s ...", node.kind, slice[0 .. min(slice.length, 20)]);

		return true;
	}

	public override bool leave(Node node, uint depth) {
		return true;
	}
}

class FinderVisitor : ParseTreeVisitor {
	import d_tree_sitter;

	struct Query {
		string kind;
		string search_text;
	}

	struct Result {
		Node node;
	}

	Query[] queries;
	Result[][Query] results;

	this(ParsedModule pm, Query[] queries) {
		super(pm);
		this.queries = queries;
	}

	public override bool visit(Node node, uint depth) {
		foreach (query; queries) {
			import std.algorithm.searching;

			if (node.kind == query.kind) {
				auto slice = pm.source[node.start_byte .. node.end_byte];
				if (slice.canFind(query.search_text)) {
					results[query] ~= Result(node);
				}
			}
		}

		return true;
	}

	public override bool leave(Node node, uint depth) {
		return true;
	}
}

void main(string[] args) {
	// // read source file
	// auto in_file = args[1];
	// string source1 = std.file.readText(in_file);
	// auto in_file_filename = std.path.baseName(in_file);
	// auto in_file_name_parts = in_file_filename.split(".");
	// auto in_file_module_name = in_file_name_parts[0];
	// auto in_file_ext = in_file_name_parts[1];

	if (args.length == 1) {
		writeln("Usage: tsparse <files...>");
		return;
	}

	import core.memory;

	GC.disable(); // disgusting hack

	// extract the things i want
	auto queries = [
		FinderVisitor.Query("struct_declaration", "struct InfoView"),
		FinderVisitor.Query("struct_declaration", "struct InfoNode"),
	];

	FinderVisitor.Result[FinderVisitor.Query] selected_results;

	ParsedModule[] modules;

	foreach (in_file; args[1 .. $]) {
		// read source file
		string source1 = std.file.readText(in_file);
		auto in_file_filename = std.path.baseName(in_file);
		auto in_file_name_parts = in_file_filename.split(".");
		auto in_file_module_name = in_file_name_parts[0];
		auto in_file_ext = in_file_name_parts[1];

		auto parser = new TreeSitterParser(d_lang);
		auto parsed_module = parser.parse_module(in_file_module_name, source1);

		// // now run the ast dumper visitor
		// auto ast_dumper = new AstDumpVisitor(parsed_module);
		// parsed_module.traverse(ast_dumper);

		modules ~= parsed_module;
	}

	foreach (parsed_module; modules) {
		auto finder = new FinderVisitor(parsed_module, queries);
		parsed_module.traverse(finder);
		writefln("finder results for %d queries", finder.queries.length);
		foreach (query; queries) {
			writefln(" query: %s", query);
			if (query !in finder.results) {
				writefln("  no results");
				continue;
			}
			foreach (result; finder.results[query]) {
				// writefln("  result: %s", result.node);
				writefln("  result: [%s], %s ...", result.node.kind, parsed_module
						.source[result.node.start_byte .. result.node.end_byte][0 .. min(20, result.node.end_byte - result
								.node.start_byte)]);
			}

			// add first result to dict
			selected_results[query] = finder.results[query][0];
		}
	}

	// now we have the results, we can do stuff with them
	// first log the results
	writefln("selected results for %d queries", selected_results.length);
	foreach (query; queries) {
		writefln(" query: %s", query);
		if (query !in selected_results) {
			writefln("  no results");
			continue;
		}
		auto result = selected_results[query];
		// writefln("  result: [%s], %s ...", result.node.kind, result.node);
		writefln("  result: [%s], %s ...", result.node, "TODO");
	}
}
