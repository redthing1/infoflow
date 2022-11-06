module infoflow.analysis.ift.ift_optimizer;

import std.container.dlist;
import std.typecons;
import std.traits;
import std.array : appender, array;
import std.range;
import std.algorithm;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic : atomicOp;
import std.exception : enforce;

import infoflow.models;
import infoflow.analysis.ift.ift_trace;
import infoflow.analysis.ift.ift_graph;

template IFTAnalysisOptimizer(TRegWord, TMemWord, TRegSet) {
    alias IFTAnalyzer = IFTAnalysis!(TRegWord, TMemWord, TRegSet).IFTAnalyzer;
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));
    alias IFTGraphNode = IFTAnalysisGraph!(TRegWord, TMemWord, TRegSet).IFTGraphNode;

    final class IFTGraphOptimizer {
        IFTAnalyzer ift;

        bool enable_prune_deterministic_subtrees = true;

        ulong log_analysis_time;
        ulong log_pruned_nodes;
        ulong log_prune_nodes_walked;

        this(IFTAnalyzer ift) {
            this.ift = ift;

            // ensure that graph and graph analysis are enabled
            enforce(ift.enable_ift_graph, "ift analyzer does not have graph enabled");
            enforce(ift.enable_ift_graph_analysis, "ift analyzer does not have graph analysis enabled");
        }

        void optimize() {
            MonoTime tmr_start = MonoTime.currTime;

            // build_caches();

            // if (enable_prune_deterministic_subtrees) {
            //     prune_deterministic_subtrees();
            // }

            MonoTime tmr_end = MonoTime.currTime;
            auto elapsed = tmr_end - tmr_start;

            log_analysis_time = elapsed.total!"usecs";
        }

        void dump_summary() {
            writefln("  analysis time:          %7ss", (
                    cast(double) log_analysis_time / 1_000_000));
            writefln("  pruned nodes:           %8s", log_pruned_nodes);
            writefln("  prune nodes walked:     %8s", log_prune_nodes_walked);
        }

        void build_caches() {

        }

        void prune_deterministic_subtrees() {
            // any subtrees that are fully deterministic can just be pruned to just a single node (the root)
            // an easy way to do this is to DFS from our final verts, and when we step back to something deterministic
            // we can prune the subtree and continue

            mixin(LOG_INFO!(`format("pruning deterministic subtrees")`));
            mixin(LOG_INFO!(`format(" identifying deterministic subtrees")`));

            auto deterministic_subtree_tops = appender!(IFTGraphNode[]);

            {
                auto unvisited = DList!IFTGraphNode();
                bool[IFTGraphNode] visited;

                foreach (final_vert; ift.final_graph_verts) {
                    unvisited.insertFront(final_vert);

                    mixin(LOG_TRACE!(` format(" starting prune from final vert %s", final_vert)`));

                    while (!unvisited.empty) {
                        auto curr = unvisited.front;
                        unvisited.removeFront();
                        visited[curr] = true;

                        mixin(LOG_DEBUG!(` format("  visiting %s", curr)`));
                        log_prune_nodes_walked++;

                        if ((curr.flags & IFTGraphNode.Flags.Nondeterministic) > 0) {
                            // add the subtree root to the list of deterministic subtrees
                            deterministic_subtree_tops ~= curr;

                            // go no further in this subtree
                            continue;
                        }

                        // queue neighbors (nodes that point to this one
                        auto targets = ift.ift_graph.get_edges_to(curr);
                        foreach (k, target_edge; targets) {
                            auto target_node = target_edge.src;
                            if (!visited.get(target_node, false)) {
                                mixin(LOG_DEBUG!(`format("   queuing node: %s", target_node)`));
                                unvisited.insertFront(target_node);
                            }
                        }
                    }
                }
            }

            mixin(LOG_INFO!(`format(" pruning identified subtrees")`));

            // prune all the deterministic subtrees
            {
                auto unvisited = DList!IFTGraphNode();
                bool[IFTGraphNode] visited;
                bool[IFTGraphNode] keep_nodes;

                foreach (i, det_node; deterministic_subtree_tops) {
                    keep_nodes[det_node] = true;
                    unvisited.insertFront(det_node);
                }

                // do traversal and delete everything that isn't in the keep_nodes list
                while (!unvisited.empty) {
                    auto curr = unvisited.front;
                    unvisited.removeFront();
                    visited[curr] = true;

                    mixin(LOG_DEBUG!(`format("    visiting %s to delete from graph", curr)`));

                    log_pruned_nodes++;
                    log_prune_nodes_walked++;

                    if (curr in keep_nodes) {
                        // curr node is the root node of the subtree, so just remove all edges touching it
                        ift.ift_graph.delete_edges_touching(curr);
                        mixin(LOG_DEBUG!(`format("     removed edges touching root node")`));
                    } else {
                        // delete this node
                        mixin(LOG_DEBUG!(`format("     deleting node from graph: %s", curr)`));

                        // delete this node from the graph
                        auto remove_result = ift.ift_graph.remove_node(curr);
                        if (remove_result) {
                            mixin(LOG_DEBUG!(`format("     removed node %s", curr)`));
                        }
                        // enforce(remove_result, "failed to remove node from graph");
                    }

                    // queue neighbors (nodes that point to this one
                    auto targets = ift.ift_graph.get_edges_to(curr);
                    foreach (k, target_edge; targets) {
                        auto target_node = target_edge.src;
                        if (!visited.get(target_node, false)) {
                            mixin(LOG_DEBUG!(
                                    `format("     queuing node for prune: %s", target_node)`));
                            unvisited.insertFront(target_node);
                        }
                    }
                }
            }
        }
    }
}
