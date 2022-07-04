module infoflow.test.test_common;

import infoflow.models;

alias TINY_WORD = uint;
alias TINY_BYTE = ubyte;

enum TinyRegisters : TINY_WORD {
    R0 = 0,
    R1 = 1,
    R2 = 2,
    R3 = 3,

    PC,
}

alias TinyInfoLog = InfoLog!(TINY_WORD, TINY_BYTE, TinyRegisters);

mixin(TinyInfoLog.GenAliases!("TinyInfoLog"));
