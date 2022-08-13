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

    final class IFTGraphNode {
        long commit_id; // the ID of the commit corresponding to this node
        InfoNode node; // the corresponding information node

        this(long commit_id, InfoNode node) {
            this.commit_id = commit_id;
            this.node = node;
        }

        IFTGraphNode[] edges;

        override string toString() const {
            import std.string : format;
            import std.conv : to;
            import std.array : appender, array;

            auto sb = appender!string;
            
            auto node_str = to!string(node);
            sb ~= format("#%s %s", commit_id, node_str);

            return sb.array;
        }
    }
}