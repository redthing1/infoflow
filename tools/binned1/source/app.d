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

struct TranslationResult {
	string source;
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

	// extract the things i want
	auto queries = [
		FinderVisitor.Query("struct_declaration", "struct InfoView"),
		FinderVisitor.Query("struct_declaration", "struct InfoNode"),
	];

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

	TranslationResult[FinderVisitor.Query] output_translations;

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
		}

		// now use the first result of each
		foreach (query; queries) {
			if (query !in finder.results) {
				continue;
			}
			auto first_result = finder.results[query][0];
			writefln("creating translation for result: [%s], %s ...", first_result.node.kind, parsed_module
					.source[first_result.node.start_byte .. first_result.node.end_byte][0 .. min(20, first_result.node
							.end_byte - first_result.node.start_byte)]);
			
			// now create a translation result
			auto translation_result = translate_node(parsed_module, first_result);
			writefln("translation result: %s", translation_result);

			output_translations[query] = translation_result;
		}

	}
}

TranslationResult translate_node(ParsedModule pm, FinderVisitor.Result result) {
	// just print the node
	writefln(" > translator input: [%s], %s ...", result.node.kind, pm.source[result.node.start_byte .. result.node.end_byte][0 .. min(20, result.node.end_byte - result.node.start_byte)]);

	return TranslationResult();
}
