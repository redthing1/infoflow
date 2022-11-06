module infoflow.util;

public import std.string;
import std.stdio;
import std.array;
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
if (INFOFLOW_VERBOSITY >= InfoflowVerbosity.trace) { writefln(` ~ Content ~ `); }
    `;
}

template LOG_DEBUG(string Content) {
    enum LOG_DEBUG = `
if (INFOFLOW_VERBOSITY >= InfoflowVerbosity.debug_) { writefln(` ~ Content ~ `); }
    `;
}

template LOG_INFO(string Content) {
    enum LOG_INFO = `
if (INFOFLOW_VERBOSITY >= InfoflowVerbosity.info) { writefln(` ~ Content ~ `); }
    `;
}

template LOG_ERROR(string Content) {
    enum LOG_ERROR = `
writefln(` ~ Content ~ `);
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
