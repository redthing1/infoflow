module lang;

import d_tree_sitter;

extern (C) Language tree_sitter_d();
extern (C) Language tree_sitter_cpp();
extern (C) Language tree_sitter_c();

alias d_lang = tree_sitter_d;
alias cpp_lang = tree_sitter_cpp;
alias c_lang = tree_sitter_c;
