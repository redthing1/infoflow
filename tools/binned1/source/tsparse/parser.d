module tsparse.parser;
import d_tree_sitter;

import tsparse.visitor;

struct ParsedModule {
    string name;
    string source;
    Tree tree;

    public void traverse(ParseTreeVisitor visitor) {
        // based on https://github.com/aminya/d-tree-sitter/blob/713e434d6976f85d7f5431059fe4e3109c2fe6cf/src/d_tree_sitter/node.d#L548
        auto cursor = tree.walk();

        bool recurse = true;
        auto depth = 0;

        visitor.visit(cursor.node, depth);

        while (true) {
            if (recurse && cursor.goto_first_child()) {
                depth++;
                // do stuff (enter thi snode)
                recurse = visitor.visit(cursor.node, depth);
            } else {
                // do stuff (leave this node)
                // auto node = cursor.node;
                visitor.leave(cursor.node, depth);

                if (cursor.goto_next_sibling()) {
                    // do stuff (enter this node)
                    recurse = visitor.visit(cursor.node, depth);
                } else if (cursor.goto_parent()) {
                    depth--;
                    recurse = false;
                } else {
                    break;
                }
            }
        }
    }
}

class TreeSitterParser {
    Language lang;
    Parser parser;

    this(Language lang) {
        this.lang = lang;
        this.parser = Parser(lang);
    }

    this(Language function() lang_func) {
        this(lang_func());
    }

    ParsedModule parse_module(string module_name, string source) {
        auto tree = parser.parse_to_tree(source);
        return ParsedModule(module_name, source, tree);
    }
}
