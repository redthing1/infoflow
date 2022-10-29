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
import std.exception : enforce;

import infoflow.models;

// extern (C++) int cpp_add(int a, int b);

// unittest {
//     assert(cpp_add(1, 2) == 3);
// }

// extern graph code
enum GenericRegSet {
    GENERIC_UNKNOWN,
}
alias GenericIFTCompactGraph = IFTAnalysisGraph!(ulong, byte, GenericRegSet).IFTGraph.CompactGraph;
extern (C++) GenericIFTCompactGraph ift_cppgraph_test_1(const GenericIFTCompactGraph input_graph);

// unittest {
//     auto in_test = GenericIFTCompactGraph.init;
//     auto out_test = ift_cppgraph_test_1(in_test);
//     assert(in_test == out_test, "input graph should be equal to output graph");
// }

template IFTAnalysisGraph(TRegWord, TMemWord, TRegSet) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    // enum IFTGraphNodeMemSize = __traits(classInstanceSize, IFTGraphNode);

    final class IFTGraph {
        /// graph vertices/nodes
        IFTGraphNode[] nodes;

        /// graph edges
        IFTGraphEdge[] edges;

        /// graph caches
        /// cache by commit id
        alias NodeCacheSet = IFTGraphNode[InfoNode];
        NodeCacheSet[ulong] _nodes_by_commit_cache;
        alias GraphEdges = IFTGraphEdge[];
        private bool[IFTGraphEdge] _edge_cache;
        /// neighbors that have edges going from this node
        private GraphEdges[IFTGraphNode] _node_neighbors_from_cache;
        /// neighbors that have edges coming to this node
        private GraphEdges[IFTGraphNode] _node_neighbors_to_cache;

        pragma(inline, true) {
            private Nullable!IFTGraphNode _find_cached(ulong commit_id, InfoNode node) {
                if (commit_id in _nodes_by_commit_cache) {
                    if (node in _nodes_by_commit_cache[commit_id]) {
                        // cache hit
                        // return _nodes_by_commit_cache[commit_id][node];
                        return some(_nodes_by_commit_cache[commit_id][node]);
                    }
                }

                // cache miss
                return no!IFTGraphNode;
            }

            private void _store_vert_cache(ulong commit_id, InfoNode node, IFTGraphNode vert) {
                // _nodes_by_commit_cache[node.info_view.commit_id][node.info_view.node] = node;
                _nodes_by_commit_cache[commit_id][node] = vert;
            }

            private void _clear_vert_cache(ulong commit_id) {
                _nodes_by_commit_cache[commit_id] = null;
            }

            private void _remove_vert_cache(ulong commit_id, InfoNode node) {
                _nodes_by_commit_cache[commit_id].remove(node);
            }
        }

        void add_node(IFTGraphNode node) {
            // ensure no duplicate exists
            enforce(!_find_cached(node.info_view.commit_id, node.info_view.node)
                    .has,
                    format("attempt to add duplicate node: %s", node));

            nodes ~= node;
            // cache it
            // _nodes_by_commit_cache[node.info_view.commit_id][node.info_view.node] = node;
            _store_vert_cache(node.info_view.commit_id, node.info_view.node, node);
        }

        Nullable!IFTGraphNode find_in_cache(ulong commit_id, InfoNode node) {
            return _find_cached(commit_id, node);
        }

        Nullable!IFTGraphNode find_node(ulong commit_id, InfoNode node) {
            // see if we can find it in the cache
            auto cached = _find_cached(commit_id, node);
            // if (cached !is null)
            //     return cached;
            if (cached.has)
                return cached;

            // find with linear search
            for (long i = 0; i < nodes.length; i++) {
                if (nodes[i].info_view.commit_id == commit_id && nodes[i].info_view.node == node) {
                    // cache it
                    _store_vert_cache(commit_id, node, nodes[i]);
                    // return nodes[i];
                    return some(nodes[i]);
                }
            }

            // not found
            return no!IFTGraphNode;
        }

        IFTGraphNode get_node_ix(ulong index) {
            return nodes[index];
        }

        pragma(inline, true) {
            private void _store_edge_cache(IFTGraphEdge edge) {
                _edge_cache[edge] = true;
            }

            private void _remove_edge_cache(IFTGraphEdge edge) {
                _edge_cache.remove(edge);
            }

            private bool _find_edge_cache(IFTGraphEdge edge) {
                return _edge_cache.get(edge, false);
            }

            private void _store_neighbors_to_cache(IFTGraphNode node, IFTGraphEdge edge) {
                if (node !in _node_neighbors_to_cache)
                    _node_neighbors_to_cache[node] = [];
                _node_neighbors_to_cache[node] ~= edge;
            }

            private void _store_neighbors_from_cache(IFTGraphNode node, IFTGraphEdge edge) {
                if (node !in _node_neighbors_from_cache)
                    _node_neighbors_from_cache[node] = [];
                _node_neighbors_from_cache[node] ~= edge;
            }

            private void _store_neighbors_to_cache(IFTGraphNode node, IFTGraphEdge[] edges) {
                _node_neighbors_to_cache[node] = edges;
            }

            private void _store_neighbors_from_cache(IFTGraphNode node, IFTGraphEdge[] edges) {
                _node_neighbors_from_cache[node] = edges;
            }

            private bool _remove_neighbors_to_cache(IFTGraphNode node, IFTGraphEdge edge) {
                auto list = _node_neighbors_to_cache[node];
                auto list_ix = list.countUntil(edge);
                if (list_ix < 0 || list_ix >= list.length)
                    return false;
                _node_neighbors_to_cache[node] = list.remove(list_ix);
                return true;
            }

            private bool _remove_neighbors_from_cache(IFTGraphNode node, IFTGraphEdge edge) {
                auto list = _node_neighbors_from_cache[node];
                auto list_ix = list.countUntil(edge);
                if (list_ix < 0 || list_ix >= list.length)
                    return false;
                _node_neighbors_from_cache[node] = list.remove(list_ix);
                return true;
            }

            private bool _find_neighbors_to_cache(IFTGraphNode node, out GraphEdges res) {
                if (node in _node_neighbors_to_cache) {
                    res = _node_neighbors_to_cache[node];
                    return true;
                }
                return false;
            }

            private bool _find_neighbors_from_cache(IFTGraphNode node, out GraphEdges res) {
                if (node in _node_neighbors_from_cache) {
                    res = _node_neighbors_from_cache[node];
                    return true;
                }
                return false;
            }

            private void _clear_neighbors_to_cache(IFTGraphNode node) {
                _node_neighbors_to_cache[node] = [];
            }

            private void _clear_neighbors_from_cache(IFTGraphNode node) {
                _node_neighbors_from_cache[node] = [];
            }

            private void _rehash_neighbors_cache() {
                _node_neighbors_from_cache.rehash();
                _node_neighbors_to_cache.rehash();
            }
        }

        void add_edge(IFTGraphEdge edge) {
            // // ensure no duplicate exists
            // enforce(!_find_edge_cache(edge), format("attempt to add duplicate edge: %s", edge));

            edges ~= edge;

            // cache it
            _store_edge_cache(edge);

            // store in src's "to" list
            _store_neighbors_to_cache(edge.src, edge);
            // store in dst's "from" list
            _store_neighbors_from_cache(edge.dst, edge);
        }

        bool edge_exists(IFTGraphEdge edge, bool cache_only = false) {
            if (_find_edge_cache(edge))
                return true;

            if (cache_only)
                return false;

            // linear search
            for (long i = 0; i < edges.length; i++) {
                if (edges[i] == edge) {
                    // cache it
                    _store_edge_cache(edge);
                    return true;
                }
            }

            // not found
            return false;
        }

        IFTGraphEdge get_edge_ix(ulong index) {
            return edges[index];
        }

        private auto filter_edges_from(IFTGraphNode node) {
            return filter!(edge => edge.src == node)(edges);
        }

        private auto filter_edges_to(IFTGraphNode node) {
            return filter!(edge => edge.dst == node)(edges);
        }

        /// get edges going from this node
        IFTGraphEdge[] get_edges_from(IFTGraphNode node) {
            GraphEdges cache_res;
            if (_find_neighbors_from_cache(node, cache_res))
                return cache_res;
            // linear search
            return filter_edges_from(node).array;
        }

        /// get edges coming to this node
        IFTGraphEdge[] get_edges_to(IFTGraphNode node) {
            GraphEdges cache_res;
            if (_find_neighbors_to_cache(node, cache_res))
                return cache_res;
            // linear search
            return filter_edges_to(node).array;
        }

        bool remove_node(IFTGraphNode node) {
            // delete the node from the list of nodes
            auto node_ix = nodes.countUntil(node);
            if (node_ix == -1)
                return false;
            // enforce(this.nodes[node_ix] == node, "node mismatch");
            this.nodes = this.nodes.remove(node_ix);

            // delete the node from the cache
            _remove_vert_cache(node.info_view.commit_id, node.info_view.node);

            delete_edges_touching(node);

            return true;
        }

        void delete_edges_touching(IFTGraphNode node) {
            // // delete all edges to and from the node
            // auto edges_from = get_edges_from(node);
            // auto edges_to = get_edges_to(node);
            // foreach (i, edge; edges_from) {
            //     remove_edge(edge);
            // }
            // foreach (i, edge; edges_to) {
            //     remove_edge(edge);
            // }

            // stupid method: scan all edges and delete anything referencing this node
            foreach (edge; this.edges.filter!(edge => edge.src == node || edge.dst == node)) {
                remove_edge(edge);
            }
        }

        bool remove_edge(IFTGraphEdge edge) {
            // delete the edge from the list of edges
            auto edge_ix = edges.countUntil(edge);
            if (edge_ix == -1)
                return false;
            this.edges = this.edges.remove(edge_ix);

            // delete the edge from the caches
            _remove_edge_cache(edge);

            // delete the edge from the neighbor lists
            // delete from src's "to" list
            _remove_neighbors_to_cache(edge.src, edge);
            // delete from dst's "from" list
            _remove_neighbors_from_cache(edge.dst, edge);

            return true;
        }

        private void rebuild_neighbors_cache() {
            import std.parallelism : parallel;

            // for each node, build a list of neighbors, pointing to and from
            foreach (i, node; parallel(nodes)) {
                // clear the caches
                _clear_neighbors_to_cache(node);
                _clear_neighbors_from_cache(node);

                // get all edges to and from this node
                auto edges_to = filter_edges_to(node).array;
                auto edges_from = filter_edges_from(node).array;

                synchronized (this) {
                    // store in the cache
                    _store_neighbors_to_cache(node, edges_to);
                    _store_neighbors_from_cache(node, edges_from);
                }
            }

            _rehash_neighbors_cache();
        }

        void invalidate_caches() {
            _nodes_by_commit_cache.clear();
            _edge_cache.clear();
            _node_neighbors_to_cache.clear();
            _node_neighbors_from_cache.clear();
        }

        void rebuild_caches() {
            rebuild_neighbors_cache();
        }

        @property size_t num_verts() {
            return nodes.length;
        }

        @property size_t num_edges() {
            return edges.length;
        }

        extern (C++) struct CompactGraph {
            ulong num_nodes;
            IFTGraphNode* nodes;
            ulong num_edges;
            IFTGraphEdge* edges;
        }

        CompactGraph export_compact() {
            return CompactGraph(
                num_verts,
                nodes.ptr,
                num_edges,
                edges.ptr
            );
        }

        void import_compact(CompactGraph graph) {
            this.nodes = graph.nodes[0 .. graph.num_nodes];
            this.edges = graph.edges[0 .. graph.num_edges];

            invalidate_caches();
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

    struct IFTGraphNode {
        /// the information as it existed in a point in time
        InfoView info_view;
        Flags flags = Flags.None;

        this(InfoView info_view) {
            this.info_view = info_view;
        }

        enum Flags {
            None = 0x0,
            Final = 1 << 0,
            Nondeterministic = 1 << 1,
            Inner = 1 << 2,
            Propagated = 1 << 3,
            Reserved3 = 1 << 4,
            Reserved4 = 1 << 5,
            Reserved5 = 1 << 6,
            Reserved6 = 1 << 7,
            Reserved7 = 1 << 8,
        }

        string toString() const {
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
