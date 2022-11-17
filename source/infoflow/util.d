module infoflow.util;

public import std.string;
import std.stdio;
import std.array: appender;
import std.conv;
import std.uni;
import std.range;
import std.algorithm;

enum InfoflowVerbosity {
    debug_ = 3,
    trace = 2,
    info = 1,
    error = 0,
}

InfoflowVerbosity INFOFLOW_VERBOSITY = InfoflowVerbosity.error;

template LOG_TRACE(string Content) {
    enum LOG_TRACE = `
if (INFOFLOW_VERBOSITY >= InfoflowVerbosity.trace) { writefln(`
        ~ Content ~ `); }
    `;
}

template LOG_DEBUG(string Content) {
    enum LOG_DEBUG = `
if (INFOFLOW_VERBOSITY >= InfoflowVerbosity.debug_) { writefln(`
        ~ Content ~ `); }
    `;
}

template LOG_INFO(string Content) {
    enum LOG_INFO = `
if (INFOFLOW_VERBOSITY >= InfoflowVerbosity.info) { writefln(`
        ~ Content ~ `); }
    `;
}

template LOG_ERROR(string Content) {
    enum LOG_ERROR = `
writefln(`
        ~ Content ~ `);
    `;
}

pragma(inline, true) bool likely(bool value) {
    version (LDC) {
        import ldc.intrinsics;

        return llvm_expect!bool(value, true);
    } else {
        return value;
    }
}

pragma(inline, true) bool unlikely(bool value) {
    version (LDC) {
        import ldc.intrinsics;

        return llvm_expect!bool(value, false);
    } else {
        return value;
    }
}

string pretty_dump_memory(ubyte[] memory, ulong base_addr, int pre_spacing = 0) {
    import std.range: repeat;

    // pretty dump memory
    auto memdump_sb = appender!(string);
    enum dump_w = 48;
    enum dump_grp = 4;

    for (auto k = 0; k < memory.length; k += dump_w) {
        // memdump_sb ~= "    ";
        memdump_sb ~= ' '.repeat(pre_spacing);
        memdump_sb ~= format("$%08x: ", k + base_addr);
        for (auto l = 0; l < dump_w; l++) {
            if (k + l >= memory.length) {
                break;
            }
            for (auto m = 0; m < 4; m++) {
                if (k + l + m >= memory.length) {
                    break;
                }
                memdump_sb ~= format("%02x", memory[k + l + m]);
            }
            l += dump_grp;
            memdump_sb ~= " ";
        }
        memdump_sb ~= "\n";
    }
    memdump_sb ~= "\n";

    return memdump_sb.data;
}
