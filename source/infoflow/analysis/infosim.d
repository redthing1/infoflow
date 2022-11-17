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

        struct MachineState {
            TMemWord[TRegWord] mem;
            TRegWord[TRegSet] reg;
            TRegWord[TRegWord] csr;
        }

        MachineState emu_state;

        this(CommitTrace commit_trace) {
            super(commit_trace, false);
        }

        void initialize_and_run_trace() {
            // 1. initialize emu_mem and emu_reg from initial state
            mixin(LOG_INFO!(`format("initializing machine state from initial state")`));

            copy_machine_state(snap_init);

            // now go through the trace and simulate
            mixin(LOG_INFO!(`format("simulating trace")`));
            simulate_trace();

            // now we have the simulated machine state
            // we can compare it to the true recorded final state
            mixin(LOG_INFO!(`format("comparing simulated machine state to final state")`));
            compare_machine_state(snap_final);
        }

        void copy_machine_state(Snapshot snap) {
            // copy memory from initial state
            auto mem_page_addrs = snap.tracked_mem.pages.byKey.array;
            foreach (page_addr; mem_page_addrs.sort()) {
                auto raw_mem_page = snap.tracked_mem.pages[page_addr].mem;

                foreach (i, mem_word; raw_mem_page) {
                    emu_state.mem[page_addr + i] = mem_word;
                }
            }

            // copy registers from initial state
            foreach (reg_id; REG_IDS) {
                emu_state.reg[reg_id] = snap_init.reg[reg_id];
            }

            // copy csr from initial state
            foreach (csr_id; snap_init.csr.byKey) {
                emu_state.csr[csr_id] = snap_init.csr[csr_id];
            }
        }

        void compare_machine_state(Snapshot snap) {
            // compare memory
            auto mem_page_addrs = snap.tracked_mem.pages.byKey.array;
            foreach (page_addr; mem_page_addrs.sort()) {
                auto raw_mem_page = snap.tracked_mem.pages[page_addr].mem;

                foreach (i, mem_word; raw_mem_page) {
                    if (emu_state.mem[page_addr + i] != mem_word) {
                        mixin(LOG_ERROR!(
                                `format("  memory mismatch at address $%08x: expected $%08x, got $%08x", page_addr + i, mem_word, emu_state.mem[page_addr + i])`));
                    }
                }
            }

            // compare registers
            foreach (reg_id; REG_IDS) {
                if (emu_state.reg[reg_id] != snap.reg[reg_id]) {
                    mixin(LOG_ERROR!(
                            `format("  register mismatch for register %s: expected $%08x, got $%08x", reg_id, snap.reg[reg_id], emu_state.reg[reg_id])`));
                }
            }
        }

        void simulate_trace() {
            for (auto i = 0; i < trace.commits.length; i++) {
                auto commit = &trace.commits[i];
                mixin(LOG_TRACE!(`format("  simulating commit #%d: %s", i, *commit)`));

                // go through effects and apply them
                foreach (j, effect; commit.effects) {
                    // apply the effect
                    apply_effect(effect);
                }
            }
        }

        pragma(inline, true) void apply_effect(InfoNode effect) {
            // apply the effect to the machine state
            bool handled = false;
            if (effect.type & InfoType.Memory) {
                auto mem_addr = effect.data;
                auto mem_val = cast(TMemWord) effect.value;
                emu_state.mem[mem_addr] = mem_val;
                handled = true;
            }
            if (effect.type & InfoType.Register) {
                auto reg_id = cast(TRegSet) effect.data;
                auto reg_val = effect.value;
                emu_state.reg[reg_id] = reg_val;
                handled = true;
            }
            if (effect.type & InfoType.CSR) {
                auto csr_id = effect.data;
                auto csr_val = effect.value;
                emu_state.csr[csr_id] = csr_val;
                handled = true;
            }

            // if not handled, then we have a problem
            if (!handled) {
                mixin(LOG_ERROR!(`format("effect not handled: %s", effect)`));

                assert(0, "effect not handled");
            }
        }

        override void analyze() {
            MonoTime tmr_start = MonoTime.currTime;

            initialize_and_run_trace();

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
