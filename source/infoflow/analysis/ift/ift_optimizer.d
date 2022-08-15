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

        this(IFTAnalyzer ift) {
            this.ift = ift;

            // ensure that graph and graph analysis are enabled
            enforce(ift.enable_ift_graph, "ift analyzer does not have graph enabled");
            enforce(ift.enable_ift_graph_analysis, "ift analyzer does not have graph analysis enabled");
        }

        void optimize() {
            build_caches();

            if (enable_prune_deterministic_subtrees) {
                prune_deterministic_subtrees();
            }
        }

        void build_caches() {
            
        }

        void prune_deterministic_subtrees() {
            // any subtrees that are fully deterministic can just be pruned to just a single node (the root)
            // an easy way to do this is to DFS from our final verts, and when we step back to something deterministic
            // we can prune the subtree and continue

            mixin(LOG_INFO!(`format("pruning deterministic subtrees")`));

            foreach (final_vert; ift.final_graph_verts) {
                auto unvisited = DList!IFTGraphNode();
                bool[IFTGraphNode] visited;

                unvisited.insertFront(final_vert);

                mixin(LOG_TRACE!(` format(" starting prune from final vert %s", final_vert)`));

                while (!unvisited.empty) {
                    auto curr = unvisited.front;
                    unvisited.removeFront();
                    visited[curr] = true;

                    mixin(LOG_DEBUG!(` format("  visiting %s", curr)`));

                    if ((curr.flags & IFTGraphNode.Flags.Deterministic) > 0) {
                        // prune the subtree
                        prune_deterministic_subtree(curr);

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

        void prune_deterministic_subtree(IFTGraphNode det_node) {
            // prune the subtree
            mixin(LOG_DEBUG!(`format("   pruning determnistic subtree: %s", det_node)`));

            // keep this node, but remove everbody who points to it (recursively)
            auto unvisited = DList!IFTGraphNode();
            bool[IFTGraphNode] visited;

            unvisited.insertFront(det_node);

            while (!unvisited.empty) {
                auto curr = unvisited.front;
                unvisited.removeFront();
                visited[curr] = true;

                mixin(LOG_DEBUG!(`format("    visiting %s", curr)`));
                
                // queue neighbors (nodes that point to this one
                auto targets = ift.ift_graph.get_edges_to(curr);
                foreach (k, target_edge; targets) {
                    auto target_node = target_edge.src;
                    if (!visited.get(target_node, false)) {
                        mixin(LOG_DEBUG!(`format("     queuing node for prune: %s", target_node)`));
                        unvisited.insertFront(target_node);
                    }
                }

                // delete this node from the graph
                ift.ift_graph.remove_node(curr);
            }
        }
    }
}
