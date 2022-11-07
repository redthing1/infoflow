module infoflow.analysis.ift.ift_dump;

import std.container.dlist;
import std.typecons;
import std.array : appender, array;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic : atomicOp;
import std.exception : enforce;

import infoflow.models;
import infoflow.analysis.ift.ift_trace;
import infoflow.analysis.ift.ift_graph;

template IFTAnalysisDump(TRegWord, TMemWord, TRegSet) {
    alias IFTAnalyzer = IFTAnalysis!(TRegWord, TMemWord, TRegSet).IFTAnalyzer;
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));
    alias IFTGraphNode = IFTAnalysisGraph!(TRegWord, TMemWord, TRegSet).IFTGraphNode;

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
                    writefln("   csr#%x <- $%08x", csr_id, csr_value);
                }
            }

            auto total_clobber_nodes =
                clobbered_reg_ids.length + clobbered_mem_addrs.length + clobbered_csr_ids.length;
            writefln("  clobbered reg nodes: %s", clobbered_reg_ids.length);
            writefln("  clobbered mem nodes: %s", clobbered_mem_addrs.length);
            // writefln("  clobbered csr nodes: %s", clobbered_csr_ids.length);
            writefln("  total clobbered nodes: %s", total_clobber_nodes);
        }

        void dump_commits() {
            // writeln("\ncommit log");
            mixin(LOG_INFO!(`"\ncommit log"`));
            foreach (i, commit; ift.trace.commits) {
                // writefln("%6d %s", i, commit);
                mixin(LOG_INFO!(`format("%6d %s", i, commit)`));
            }
        }

        void dump_analysis() {
            import std.array : appender;

            writefln("\nanalysis:");

            // dump backtraces
            // writefln(" backtraces:");
            mixin(LOG_TRACE!(`"backtraces:"`));

            bool[long] minimal_commit_set;

            void log_commit_for_source(InfoLeaf source) {
                minimal_commit_set[source.commit_id] = true;

                if (INFOFLOW_VERBOSITY >= InfoflowVerbosity.trace) {
                    auto sb = appender!(string);

                    sb ~= "   " ~ source.toString();
                    if (source.commit_id >= 0) {
                        auto commit = ift.trace.commits[source.commit_id];
                        sb ~= " -> " ~ commit.toString();
                    } else {
                        sb ~= " -> <init>";
                    }
                    
                    mixin(LOG_TRACE!(`sb.data`));
                }
            }

            // registers
            foreach (reg_id; ift.clobbered_regs_sources.byKey) {
                // writefln("  reg %s:", reg_id);
                mixin(LOG_TRACE!(`format("  reg %s:", reg_id)`));
                if (reg_id !in ift.clobbered_regs_sources) {
                    // ???
                    mixin(LOG_ERROR!(`format("  reg %s not in clobbered_regs_sources", reg_id)`));
                    enforce(0, "reg not in clobbered_regs_sources");
                }
                foreach (source_ix; ift.clobbered_regs_sources[reg_id]) {
                    log_commit_for_source(ift.global_info_leafs_buffer[source_ix]);
                }
            }

            // memory
            foreach (mem_addr; ift.clobbered_mem_sources.byKey) {
                // writefln("  mem[%04x]:", mem_addr);
                mixin(LOG_TRACE!(`format("  mem[%04x]:", mem_addr)`));
                if (mem_addr !in ift.clobbered_mem_sources) {
                    // ???
                    mixin(LOG_ERROR!(
                            `format("  mem[%04x] not in clobbered_mem_sources", mem_addr)`));
                    enforce(0, "mem not in clobbered_mem_sources");
                }
                foreach (source_ix; ift.clobbered_mem_sources[mem_addr]) {
                    log_commit_for_source(ift.global_info_leafs_buffer[source_ix]);
                }
            }

            // csr
            foreach (csr_id; ift.clobbered_csr_sources.byKey) {
                // writefln("  csr#%x:", csr_id);
                mixin(LOG_TRACE!(`format("  csr#%x:", csr_id)`));
                if (csr_id !in ift.clobbered_csr_sources) {
                    // ???
                    mixin(LOG_ERROR!(`format("  csr#%x not in clobbered_csr_sources", csr_id)`));
                    enforce(0, "csr not in clobbered_csr_sources");
                }
                foreach (source_ix; ift.clobbered_csr_sources[csr_id]) {
                    log_commit_for_source(ift.global_info_leafs_buffer[source_ix]);
                }
            }

            writefln(" theoritical minimization:");
            auto num_minimal_commits = minimal_commit_set.length;
            writefln("  minimal commits: %s", num_minimal_commits);
            writefln("  total commits: %s", ift.trace.commits.length);
            writefln("  theoretical minimum untouched commits: %.2f%%",
                (100.0 * num_minimal_commits) / ift.trace.commits.length);
        }

        void dump_graph() {
            // also dump ift graph
            // writefln(" ift graph:");
            mixin(LOG_INFO!(`" ift graph:"`));

            mixin(LOG_TRACE!(`"  nodes"`));
            foreach (node; ift.ift_graph.nodes) {
                mixin(LOG_TRACE!(`format("   %s", node)`));
            }
            mixin(LOG_TRACE!(`"  edges"`));
            foreach (edge; ift.ift_graph.edges) {
                // mixin(LOG_TRACE!(`format("   %s", edge)`));
                mixin(LOG_TRACE!(`format("   %s (%08x) -> %s (%08x)", *edge.src, edge.src, *edge.dst, edge.dst)`));
                // mixin(LOG_TRACE!(`format("    (%08x) -> (%08x)", edge.src, edge.dst)`));
            }

            // mixin(LOG_INFO!(`"  stats"`));
            // mixin(LOG_INFO!(`"   verts: %s", ift.ift_graph.num_verts`));
            // mixin(LOG_INFO!(`"   edges: %s", ift.ift_graph.num_edges`));
            writefln("  stats:");
            writefln("   verts: %s", ift.ift_graph.num_verts);
            writefln("   edges: %s", ift.ift_graph.num_edges);

            // // dump all ift subtrees
            // writefln(" dependency subtrees:");
            // foreach (subtree; ift.ift_subtrees) {
            //     import std.array: split;
            //     import std.string: strip;

            //     writefln("  subtree for: %s", subtree.node);
            //     auto subtree_dump = subtree.dump();
            //     foreach (line; subtree_dump.split("\n")) {
            //         if (line.strip().length == 0) break;
            //         writefln("  %s", line);
            //     }
            // }

            // if graph analysis enabled, dump detailed stats            
        }

        void export_graph_to(string output) {
            import dgraphviz;

            // auto g = new Directed;
            // A a;
            // with (g) {
            //     node(a, ["shape": "box", "color": "#ff0000"]);
            //     edge(a, true);
            //     edge(a, 1, ["style": "dashed", "label": "a-to-1"]);
            //     edge(true, "foo");
            // }
            // g.save("simple.dot");

            auto g = new Directed();
            writefln(" exporting ift graph as graphviz");

            with (g) {
                foreach (ift_vert; ift.ift_graph.nodes) {
                    // node(node, ["shape": "box", "color": "#ff0000"]);
                    enum default_color = "#000000";
                    enum final_color = "#ef9148";
                    enum deterministic_color = "#1ABA8B";

                    auto node_color = deterministic_color;
                    if ((ift_vert.flags & IFTGraphNode.Flags.Nondeterministic) > 0) {
                        node_color = final_color;
                    }

                    // set color according to flags
                    node(ift_vert, ["shape": "box", "label": ift_vert.toString(), "color": node_color]);
                }
                foreach (ift_edge; ift.ift_graph.edges) {
                    // edge(edge.src, edge.dst, ["style": "dashed", "label": edge.label]);
                    edge(*ift_edge.src, *ift_edge.dst);
                }
            }

            g.save(output);
            writefln("  wrote graphviz data to %s", output);
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
                writefln("  walked graph nodes:     %8d", ift.log_graph_nodes_walked);
                writefln("  graph cache hits:       %8d", ift.log_graph_nodes_cache_hits);
                writefln("  graph cache misses:     %8d", ift.log_graph_nodes_cache_misses);
                writefln("  node walk duplicates:   %8d", ift.log_global_node_walk_duplicates);
                writefln("  cache build time:       %7ss", (
                    cast(double) ift.log_cache_build_time / 1_000_000));
                writefln("  propagation walked:     %8d", ift.log_propagation_nodes_walked);
                writefln("  propagation time:       %7sms", (
                    cast(double) ift.log_propagation_time / 1_000));
            }
            writefln("  analysis time:          %7ss", (
                    cast(double) ift.log_analysis_time / 1_000_000));
        }
    }
}
