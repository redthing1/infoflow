module infoflow.analysis.infosim;

import std.algorithm : map, filter;
import std.range : array;
import std.algorithm.comparison : min, max;
import std.algorithm.sorting : sort;
import std.traits : EnumMembers;

import infoflow.analysis.common;

template InfoSimAnalysis(TRegWord, TMemWord, TRegSet) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    alias TBaseAnalysis = BaseAnalysis!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    private enum REG_IDS = [EnumMembers!TRegSet];

    final class InfoSimAnalyzer : TBaseAnalysis.BaseAnalyzer {
        ulong log_analysis_time;

        this(CommitTrace commit_trace) {
            super(commit_trace, false);
        }

        override void analyze() {
            MonoTime tmr_start = MonoTime.currTime;

            // TODO: analyze

            MonoTime tmr_end = MonoTime.currTime;
            auto elapsed = tmr_end - tmr_start;

            log_analysis_time = elapsed.total!"usecs";
        }

        void dump_analysis() {
            // dump the full analysis
        }

        void dump_summary() {
        }
    }
}
