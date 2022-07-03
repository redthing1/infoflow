module infoflow.analysis.common;

public {
    import std.stdio;
    import std.format;
    import std.conv;
    import std.algorithm;
    import std.range;
    import core.time : MonoTime, Duration;

    import infoflow.models.commit;
    import infoflow.util;
}

template BaseAnalysis(TRegWord, TMemWord, TRegSet) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    class BaseAnalyzer {
        CommitTrace trace;
        Snapshot snap_init;
        Snapshot snap_final;
        bool analysis_parallelized;

        this(CommitTrace commit_trace, bool parallelized = false) {
            trace = commit_trace;

            // sanity check the trace
            assert(trace.commits.length > 0, "trace must have at least one commit");
            assert(trace.snapshots.length == 2,
                "trace must have exactly two snapshots, initial and final");
            assert(trace.snapshots[0].memory_map == trace.snapshots[1].memory_map,
                "snapshots must have same memory map");

            snap_init = trace.snapshots[0];
            snap_final = trace.snapshots[1];

            analysis_parallelized = parallelized;
        }

        void analyze() {
            assert(0, "analyze() not implemented");
        }

        void dump_analysis() {
            assert(0, "dump_analysis() not implemented");
        }

        void dump_summary() {
            assert(0, "dump_summary() not implemented");
        }
    }
}
