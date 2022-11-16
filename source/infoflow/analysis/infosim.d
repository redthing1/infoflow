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

        TMemWord[TRegWord] emu_mem;
        TRegWord[TRegSet] emu_reg;

        this(CommitTrace commit_trace) {
            super(commit_trace, false);
        }

        void simulate_trace() {
            // 1. initialize emu_mem and emu_reg from initial state
            auto initial_state = snap_init;

            mixin(LOG_INFO!(`format("initializing emu_mem and emu_reg from initial state")`));

            // copy memory from initial state
            auto mem_page_addrs = initial_state.tracked_mem.pages.byKey.array;
            foreach (page_addr; mem_page_addrs.sort()) {
                auto raw_mem_page = initial_state.tracked_mem.pages[page_addr].mem;

                foreach (i, mem_word; raw_mem_page) {
                    emu_mem[page_addr + i] = mem_word;
                }
            }

            // copy registers from initial state
            foreach (reg_id; REG_IDS) {
                emu_reg[reg_id] = snap_init.reg[reg_id];
            }
        }

        override void analyze() {
            MonoTime tmr_start = MonoTime.currTime;

            simulate_trace();

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
