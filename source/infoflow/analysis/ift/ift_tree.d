module infoflow.analysis.ift.ift_tree;

import std.container.dlist;
import std.typecons;
import std.traits;
import std.array : appender, array;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic: atomicOp;

import infoflow.models;

template IFTAnalysisTree(TRegWord, TMemWord, TRegSet) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    enum IFTTreeNodeMemSize = __traits(classInstanceSize, IFTTreeNode);

    final class IFTTreeNode {
        long commit_id; // the ID of the commit corresponding to this node
        InfoNode node; // the corresponding information node

        this(long commit_id, InfoNode node) {
            this.commit_id = commit_id;
            this.node = node;
        }

        IFTTreeNode parent;
        IFTTreeNode[] children;
        bool hierarchy_all_final;
        bool hierarchy_all_deterministic;
        bool hierarchy_some_final;
        bool hierarchy_some_deterministic;

        override string toString() const {
            import std.string : format;
            import std.conv : to;
            import std.array : appender, array;

            auto sb = appender!string;

            // auto tag_str = "?";
            // if (hierarchy_all_final) {
            //     tag_str = "F";
            // }

            // if (hierarchy_all_deterministic) {
            //     tag_str = "D";
            // }
            auto final_tag = "X";
            auto det_tag = "X";
            if (hierarchy_all_final) {
                final_tag = "F!";
            } else if (hierarchy_some_final) {
                final_tag = "F?";
            }
            if (hierarchy_all_deterministic) {
                det_tag = "D!";
            } else if (hierarchy_some_deterministic) {
                det_tag = "D?";
            }
            auto tag_str = format("%s,%s", final_tag, det_tag);

            auto node_str = to!string(node);
            sb ~= format("#%s %s [%s]", commit_id, node_str, tag_str);

            return sb.array;
        }
    }
}