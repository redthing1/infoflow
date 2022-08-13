module infoflow.analysis.ift.ift_dump;

import std.container.dlist;
import std.typecons;
import std.array : appender, array;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic: atomicOp;
import std.exception : enforce;

import infoflow.models;
import infoflow.analysis.ift.ift_trace;
import infoflow.analysis.ift.ift_tree;

template IFTAnalysisDump(TRegWord, TMemWord, TRegSet) {
    alias IFTAnalyzer = IFTAnalysis!(TRegWord, TMemWord, TRegSet).IFTAnalyzer;
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));
    alias IFTTreeNode = IFTAnalysisTree!(TRegWord, TMemWord, TRegSet).IFTTreeNode;

    final class IFTDumper {
        IFTAnalyzer ift;

        this(IFTAnalyzer ift) {
            this.ift = ift;
        }

        void dump_clobber() {
            // 1. dump clobber commit
            writefln(" clobber (%s commits):", ift.trace.commits.length);

            auto clobbered_reg_ids = ift.clobber.get_effect_reg_ids().array;
            auto clobbered_reg_values = ift.clobber.get_effect_reg_values().array;
            auto clobbered_mem_addrs = ift.clobber.get_effect_mem_addrs().array;
            auto clobbered_mem_values = ift.clobber.get_effect_mem_values().array;
            auto clobbered_csr_ids = ift.clobber.get_effect_csr_ids().array;
            auto clobbered_csr_values = ift.clobber.get_effect_csr_values().array;

            if (ift.included_data & IFTAnalyzer.IFTDataType.Memory) {
                // memory
                writefln("  memory:");
                for (auto i = 0; i < clobbered_mem_addrs.length; i++) {
                    auto mem_addr = clobbered_mem_addrs[i];
                    auto mem_value = clobbered_mem_values[i];
                    writefln("   mem[$%08x] <- $%02x", mem_addr, mem_value);
                }
            }

            if (ift.included_data & IFTAnalyzer.IFTDataType.Registers) {
                // registers
                writefln("  regs:");
                for (auto i = 0; i < clobbered_reg_ids.length; i++) {
                    auto reg_id = clobbered_reg_ids[i].to!TRegSet;
                    auto reg_value = clobbered_reg_values[i];
                    writefln("   reg %s <- $%08x", reg_id, reg_value);
                }
            }

            if (ift.included_data & IFTAnalyzer.IFTDataType.CSR) {
                // csr
                writefln("  csr:");
                for (auto i = 0; i < clobbered_csr_ids.length; i++) {
                    auto csr_id = clobbered_csr_ids[i];
                    auto csr_value = clobbered_csr_values[i];
                    writefln("   csr $%08x <- $%08x", csr_id, csr_value);
                }
            }

            auto total_clobber_nodes =
                clobbered_reg_ids.length + clobbered_mem_addrs.length + clobbered_csr_ids.length;
            writefln("  total clobbered nodes: %s", total_clobber_nodes);
        }

        void dump_commits() {
            foreach (i, commit; ift.trace.commits) {
                writefln("%6d %s", i, commit);
            }
        }

        void dump_analysis() {
            import std.array : appender;

            // dump backtraces
            writefln(" backtraces:");

            void log_commit_for_source(InfoLeaf source) {
                writef("   %s", source);
                if (source.commit_id >= 0) {
                    auto commit = ift.trace.commits[source.commit_id];
                    writef(" -> %s", commit);
                } else {
                    writef(" -> <init>");
                }
                writeln();
            }

            // registers
            foreach (reg_id; ift.clobbered_regs_sources.byKey) {
                writefln("  reg %s:", reg_id);
                if (reg_id !in ift.clobbered_regs_sources) {
                    // ???
                    mixin(LOG_ERROR!(`format("  reg %s not in clobbered_regs_sources", reg_id)`));
                    enforce(0, "reg not in clobbered_regs_sources");
                }
                foreach (source; ift.clobbered_regs_sources[reg_id]) {
                    log_commit_for_source(source);
                }
            }

            // memory
            foreach (mem_addr; ift.clobbered_mem_sources.byKey) {
                writefln("  mem[%04x]:", mem_addr);
                if (mem_addr !in ift.clobbered_mem_sources) {
                    // ???
                    mixin(LOG_ERROR!(
                            `format("  mem[%04x] not in clobbered_mem_sources", mem_addr)`));
                    enforce(0, "mem not in clobbered_mem_sources");
                }
                foreach (source; ift.clobbered_mem_sources[mem_addr]) {
                    log_commit_for_source(source);
                }
            }

            // csr
            foreach (csr_id; ift.clobbered_csr_sources.byKey) {
                writefln("  csr $%08x:", csr_id);
                if (csr_id !in ift.clobbered_csr_sources) {
                    // ???
                    mixin(LOG_ERROR!(`format("  csr $%08x not in clobbered_csr_sources", csr_id)`));
                    enforce(0, "csr not in clobbered_csr_sources");
                }
                foreach (source; ift.clobbered_csr_sources[csr_id]) {
                    log_commit_for_source(source);
                }
            }

            if (ift.enable_ift_tree) {
                // also dump ift tree
                writefln(" ift tree:");
                // go through all ift tree roots
                foreach (tree_root; ift.ift_trees) {
                    // do a depth-first traversal

                    struct TreeNodeWalk {
                        IFTTreeNode tree;
                        int depth;
                    }

                    auto stack = DList!TreeNodeWalk();
                    stack.insertFront(TreeNodeWalk(tree_root, 0));

                    while (!stack.empty) {
                        auto curr_walk = stack.front;
                        stack.removeFront();

                        // visit and print
                        // indent
                        for (auto i = 0; i < curr_walk.depth; i++) {
                            writef("  ");
                        }
                        // print node
                        writefln("%s", curr_walk.tree);

                        // push children
                        foreach (child; curr_walk.tree.children) {
                            stack.insertFront(TreeNodeWalk(child, curr_walk.depth + 1));
                        }
                    }
                }
            }
        }

        void dump_summary() {
            auto clobbered_reg_ids = ift.clobber.get_effect_reg_ids().array;
            auto clobbered_mem_addrs = ift.clobber.get_effect_mem_addrs().array;
            auto clobered_csr_ids = ift.clobber.get_effect_csr_ids().array;

            // summary
            writefln(" summary:");
            writefln("  num commits:            %8d", ift.trace.commits.length);
            if (ift.included_data & IFTAnalyzer.IFTDataType.Registers) {
                writefln("  registers traced:       %8d", clobbered_reg_ids.length);
            }
            if (ift.included_data & IFTAnalyzer.IFTDataType.Memory) {
                writefln("  memory traced:          %8d", clobbered_mem_addrs.length);
            }
            if (ift.included_data & IFTAnalyzer.IFTDataType.CSR) {
                writefln("  csr traced:             %8d", clobered_csr_ids.length);
            }
            version (analysis_log) {
                writefln("  found sources:          %8d", ift.log_found_sources);
                writefln("  walked info:            %8d", ift.log_visited_info_nodes);
                writefln("  walked commits:         %8d", ift.log_commits_walked);
            }
            writefln("  analysis time:          %7ss", (cast(double) ift.log_analysis_time / 1_000_000));
        }
    }
}
