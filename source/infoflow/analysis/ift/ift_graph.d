module infoflow.analysis.ift.ift_graph;

import std.container.dlist;
import std.typecons;
import std.traits;
import std.array : appender, array;
import std.range;
import std.algorithm;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic : atomicOp;

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

        /// cache by commit id
        alias NodeCacheSet = IFTGraphNode[InfoNode];
        NodeCacheSet[ulong] _nodes_by_commit_cache;

        pragma(inline, true) {
            private IFTGraphNode _find_cached(ulong commit_id, InfoNode node) {
                if (commit_id in _nodes_by_commit_cache) {
                    if (node in _nodes_by_commit_cache[commit_id]) {
                        // cache hit
                        return _nodes_by_commit_cache[commit_id][node];
                    }
                }

                // cache miss
                return null;
            }

            private void _store_cached(ulong commit_id, InfoNode node, IFTGraphNode vert) {
                // _nodes_by_commit_cache[node.info_view.commit_id][node.info_view.node] = node;
                _nodes_by_commit_cache[commit_id][node] = vert;
            }
        }

        void add_node(IFTGraphNode node) {
            nodes ~= node;
            // cache it
            // _nodes_by_commit_cache[node.info_view.commit_id][node.info_view.node] = node;
            _store_cached(node.info_view.commit_id, node.info_view.node, node);
        }

        IFTGraphNode find_in_cache(ulong commit_id, InfoNode node) {
            return _find_cached(commit_id, node);
        }

        IFTGraphNode find_node(ulong commit_id, InfoNode node) {
            // see if we can find it in the cache
            IFTGraphNode cached = _find_cached(commit_id, node);
            if (cached !is null)
                return cached;

            // find with linear search
            for (long i = 0; i < nodes.length; i++) {
                if (nodes[i].info_view.commit_id == commit_id && nodes[i].info_view.node == node) {
                    // cache it
                    _store_cached(commit_id, node, nodes[i]);
                    return nodes[i];
                }
            }

            // not found
            return null;
        }

        IFTGraphNode get_node_ix(ulong index) {
            return nodes[index];
        }

        void add_edge(IFTGraphEdge edge) {
            edges ~= edge;
        }

        IFTGraphEdge get_edge_ix(ulong index) {
            return edges[index];
        }

        auto filter_edges_from(IFTGraphNode node) {
            return filter!(edge => edge.src == node)(edges);
        }

        auto filter_edges_to(IFTGraphNode node) {
            return filter!(edge => edge.dst == node)(edges);
        }

        IFTGraphEdge[] get_edges_from(IFTGraphNode node) {
            return filter_edges_from(node).array;
        }

        IFTGraphEdge[] get_edges_to(IFTGraphNode node) {
            return filter_edges_to(node).array;
        }

        @property size_t num_verts() {
            return nodes.length;
        }

        @property size_t num_edges() {
            return edges.length;
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
