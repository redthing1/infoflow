import std.stdio;
import std.file;
import std.path;
import std.array;
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

		import std.algorithm: min;

		// writefln("> [%s], %s", node.kind, slice);
		writefln("> [%s], %s ...", node.kind, slice[0 .. min(slice.length, 20)]);

		return true;
	}

	public override bool leave(Node node, uint depth) {
		return true;
	}
}

void main(string[] args) {
	// read source file
	auto in_file = args[1];
	string source1 = std.file.readText(in_file);
	auto in_file_filename = std.path.baseName(in_file);
	auto in_file_name_parts = in_file_filename.split(".");
	auto in_file_module_name = in_file_name_parts[0];
	auto in_file_ext = in_file_name_parts[1];

	auto parser = new TreeSitterParser(d_lang);
	auto parsed_module = parser.parse_module(in_file_module_name, source1);

	// now run the ast dumper visitor
	auto ast_dumper = new AstDumpVisitor(parsed_module);
	parsed_module.traverse(ast_dumper);
}
