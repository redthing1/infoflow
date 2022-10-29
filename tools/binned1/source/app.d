import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm.comparison;
import std.typecons;
import std.format;
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

	import core.memory;
	GC.disable(); // disgusting hack

	// extract the things i want
	auto queries = [
		// FinderVisitor.Query("enum_declaration", "enum InfoType"),
		FinderVisitor.Query("struct_declaration", "struct InfoNode"),
		FinderVisitor.Query("struct_declaration", "struct InfoView"),
		FinderVisitor.Query("struct_declaration", "struct IFTGraphNode"),
		FinderVisitor.Query("struct_declaration", "struct IFTGraphEdge"),
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
					.source[first_result.node.start_byte .. first_result.node.end_byte][0 .. min(20, first_result
							.node
							.end_byte - first_result.node.start_byte)]);

			// now create a translation result
			auto translation_result = translate_node(parsed_module, first_result);
			writefln("translation result: %s", translation_result);

			output_translations[query] = translation_result;
		}

		// print the output
		foreach (query; queries) {
			if (query !in output_translations) {
				continue;
			}
			writefln("%s\n\n", output_translations[query].source);
		}
	}
}

TranslationResult translate_node(ParsedModule pm, FinderVisitor.Result result) {
	import d_tree_sitter;

	// just print the node
	writefln(" > translator input: [%s], %s ...", result.node.kind, pm
			.source[result.node.start_byte .. result.node.end_byte][0 .. min(20, result.node.end_byte - result
					.node.start_byte)]);

	auto outsrc = appender!string();
	auto root = result.node;
	// auto cur = root.walk();

	Nullable!Node kind_child_i(string kind, int ix) {
		auto seen = 0;
		for (auto i = 0; i < root.child_count; i++) {
			auto maybe_child = root.child(i);
			auto child = maybe_child.get;
			if (child.kind == kind) {
				if (seen == ix) {
					// return child;
					return Nullable!Node(child);
				}
				seen++;
			}
		}
		return Nullable!Node.init;
	}

	Node[] get_kind_childs_deep(string kind) {
		Node[] childs;
		auto cur = root.walk();
		
		auto reached_end = false;
		while (!reached_end) {
			// visit the current node
			if (cur.node.kind == kind) {
				childs ~= cur.node;
			}

			if (cur.goto_first_child()) {
				continue;
			}
			if (cur.goto_next_sibling()) {
				continue;
			}

			auto retracing = true;
			while (retracing) {
				if (!cur.goto_parent()) {
					retracing = false;
					reached_end = true;
				} else {
					if (cur.goto_next_sibling()) {
						retracing = false;
					}
				}
			}
		}

		return childs;
	}

	auto node_str(Node node) {
		return pm.source[node.start_byte .. node.end_byte];
	}

	// add the type declaration
	outsrc ~= node_str(kind_child_i("struct", 0).get);
	outsrc ~= " ";
	outsrc ~= node_str(kind_child_i("identifier", 0).get);
	outsrc ~= " {";

	// add the fields
	outsrc ~= "\n";
	auto field_decls = get_kind_childs_deep("var_declarations");
	foreach (field_decl; field_decls) {
		outsrc ~= format("  %s\n", node_str(field_decl));
	}

	// close the struct
	outsrc ~= "};";

	return TranslationResult(outsrc.data);
}
