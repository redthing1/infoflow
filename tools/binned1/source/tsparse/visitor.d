module tsparse.visitor;
import d_tree_sitter;

import tsparse.parser;

abstract class ParseTreeVisitor {
    ParsedModule pm;

    this(ParsedModule pm) {
        this.pm = pm;
    }

    public abstract bool visit(Node node, uint depth);
    public abstract bool leave(Node node, uint depth);
}
