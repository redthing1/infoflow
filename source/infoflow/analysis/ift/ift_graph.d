module infoflow.analysis.ift.ift_graph;

import std.container.dlist;
import std.typecons;
import std.traits;
import std.array : appender, array;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic: atomicOp;

import infoflow.models;

template IFTAnalysisGraph(TRegWord, TMemWord, TRegSet) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    enum IFTGraphNodeMemSize = __traits(classInstanceSize, IFTGraphNode);

    final class IFTGraph {
        /// graph vertices/nodes
        IFTGraphNode[] nodes;

        /// graph edges
        IFTGraphEdge[] edges;

        void add_node(IFTGraphNode node) {
            nodes ~= node;
        }

        void add_edge(IFTGraphEdge edge) {
            edges ~= edge;
        }
    }

    struct IFTGraphEdge {
        /// source node
        IFTGraphNode src;
        /// destination node
        IFTGraphNode dst;
        // /// edge direction
        // bool is_forward = true;

        string toString() const {
            return format("%s -> %s", src, dst);
            // return format("%s %s %s", src, is_forward ? "->" : "<-", dst);
        }
    }

    final class IFTGraphNode {
        /// the information as it existed in a point in time
        InfoView info_view;

        this(InfoView info_view) {
            this.info_view = info_view;
        }

        override string toString() const {
            import std.string : format;
            import std.conv : to;
            import std.array : appender, array;

            auto sb = appender!string;
            
            auto node_str = to!string(info_view.node);
            sb ~= format("#%s %s", info_view.commit_id, node_str);

            return sb.array;
        }
    }
}