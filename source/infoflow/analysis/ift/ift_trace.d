module infoflow.analysis.ift.ift_trace;

import std.container.dlist;
import std.typecons;
import std.array : appender, array;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic : atomicOp;
import std.exception : enforce;

import infoflow.util;
import infoflow.analysis.ift.ift_graph;

template IFTAnalysis(TRegWord, TMemWord, TRegSet) {
    import std.traits;

    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    alias TBaseAnalysis = BaseAnalysis!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    alias TIFTAnalysisGraph = IFTAnalysisGraph!(TRegWord, TMemWord, TRegSet);
    alias IFTGraph = TIFTAnalysisGraph.IFTGraph;
    alias IFTGraphNode = TIFTAnalysisGraph.IFTGraphNode;
    alias IFTGraphEdge = TIFTAnalysisGraph.IFTGraphEdge;

    static assert([EnumMembers!TRegSet].map!(x => x.to!string)
            .canFind!(x => x == "PC"),
            "enum TRegSet must contain a program counter register PC");
    enum PC_REGISTER = to!TRegSet("PC");

    /** analyzer for dynamic information flow tracking **/
    final class IFTAnalyzer : TBaseAnalysis.BaseAnalyzer {
        Commit clobber;
        IFTDataType included_data = IFTDataType.Standard;

        bool enable_ift_graph = false;
        IFTGraph ift_graph = new IFTGraph();
        bool enable_ift_graph_analysis = false;

        bool aggressive_revisit_skipping = false;
        shared bool[InfoNodeWalk] global_node_walk_visited;
        shared InfoLeaf[] global_info_leafs_buffer;

        alias InfoLeafIndices = size_t[];
        InfoLeafIndices[TRegSet] clobbered_regs_sources;
        InfoLeafIndices[TRegWord] clobbered_mem_sources;
        InfoLeafIndices[TRegWord] clobbered_csr_sources;
        IFTGraphNode[] final_graph_verts;

        version (analysis_log) {
            shared long log_visited_info_nodes;
            shared long log_commits_walked;
            shared long log_found_sources;
            shared long log_graph_nodes_walked;
            shared long log_graph_nodes_cache_hits;
            shared long log_graph_nodes_cache_misses;
            shared long log_global_node_walk_duplicates;
            shared long log_propagation_nodes_walked;
            ulong log_propagation_time;
            ulong log_cache_build_time;
        }
        ulong log_analysis_time;

        enum IFTDataType {
            None = (0 << 0),
            Registers = (1 << 0),
            Memory = (1 << 1),
            CSR = (1 << 3),
            Standard = (Registers | Memory),
            Special = (CSR),
            All = (Standard | Special),
        }

        struct Config {
            this(TRegSet[] ignored_regs, TRegWord[] ignored_csr) {
                foreach (i, id; ignored_regs)
                    this.ignored_regs[id] = true;
                foreach (i, id; ignored_csr)
                    this.ignored_csr[id] = true;
            }

            bool[TRegSet] ignored_regs;
            bool[TRegWord] ignored_csr;
        }

        Config config;

        this(CommitTrace commit_trace, Config config, bool parallelized = false) {
            this.config = config;
            super(commit_trace, parallelized);
        }

        @property long last_commit_ix() const {
            return (cast(long) trace.commits.length) - 1;
        }

        /**
        * analyze the commit trace
        * @return the analysis result
        */
        override void analyze() {
            MonoTime tmr_start = MonoTime.currTime;

            version (analysis_log) {
                log_visited_info_nodes = 0;
                log_commits_walked = 0;
                log_found_sources = 0;
                log_graph_nodes_walked = 0;
                log_graph_nodes_cache_hits = 0;
                log_graph_nodes_cache_misses = 0;
                log_global_node_walk_duplicates = 0;
                log_propagation_nodes_walked = 0;
            }

            // calculate diffs and clobber
            calculate_clobber();
            calculate_commit_indexes();
            analyze_flows();

            if (enable_ift_graph) {
                if (enable_ift_graph_analysis) {
                    rebuild_graph_caches();
                    propagate_node_flags();
                }
            }

            MonoTime tmr_end = MonoTime.currTime;
            auto elapsed = tmr_end - tmr_start;

            log_analysis_time = elapsed.total!"usecs";
        }

        Commit calculate_clobber() {
            // calculate the total clobber commit between the initial and final state
            // 1. reset clobber
            clobber = Commit();

            if (included_data & IFTDataType.Registers) {
                // 1. find regs that changed
                for (auto i = 0; i < TInfoLog.REGISTER_COUNT; i++) {
                    TRegSet reg_id = i.to!TRegSet;
                    if (snap_init.reg[reg_id] != snap_final.reg[reg_id] &&
                        !config.ignored_regs.get(reg_id, false)) {
                        // this TRegSet changed between the initial and final state
                        // store commit that clobbers this TRegSet
                        clobber.effects ~= InfoNode(InfoType.Register, reg_id, snap_final
                                .reg[reg_id]);
                    }
                }
            }

            if (included_data & IFTDataType.Memory) {
                foreach (mem_page_addr; snap_init.tracked_mem.pages.byKey) {
                    for (auto i = 0; i < MemoryPageTable.PAGE_SIZE; i++) {
                        auto mem_addr = mem_page_addr + i;
                        if (snap_init.get_mem(mem_addr) != snap_final.get_mem(mem_addr)) {
                            // this memory changed between the initial and final state
                            // store commit that clobbers this memory
                            clobber.effects ~= InfoNode(InfoType.Memory, mem_addr, snap_final.get_mem(
                                    mem_addr));
                        }
                    }
                }
            }

            if (included_data & IFTDataType.CSR) {
                foreach (csr_id; snap_init.csr.byKey) {
                    if (snap_init.get_csr(csr_id) != snap_final.get_csr(csr_id) &&
                        !config.ignored_csr.get(csr_id, false)) {
                        // this CSR changed between the initial and final state
                        // store commit that clobbers this CSR
                        clobber.effects ~= InfoNode(InfoType.CSR, csr_id, snap_final.get_csr(
                                csr_id));
                    }
                }
            }

            // 3. do a reverse pass through all commits, looking for special cases
            //    things like devices and mmio, external sources of data

            long commits_walked_acc = 0;
            for (auto i = last_commit_ix; i >= 0; i--) {
                auto commit = trace.commits[i];
                commits_walked_acc++;

                // look at sources of this commit
                for (auto j = 0; j < commit.sources.length; j++) {
                    auto source = commit.sources[j];

                    if (source.type == InfoType.Device) {
                        // one of this instruction's sources is a device
                        // this means that the output nodes are clobbered

                        // there are no commands in this ISA to directly clobber memory
                        // so we'll only check registers

                        // find the registers that are clobbered by this commit
                        for (auto k = 0; k < commit.effects.length; k++) {
                            auto effect = commit.effects[k];
                            if (effect.type & InfoType.Register) {
                                auto reg_id = effect.data;
                                auto reg_val = effect.value;
                                if (clobber.effects.canFind!(x => x.data == reg_id)) {
                                    // this TRegSet is already clobbered
                                    // so we don't need to do anything
                                    continue;
                                }

                                // this TRegSet is not clobbered yet
                                // so we need to add it to the clobber list
                                clobber.effects ~= InfoNode(InfoType.Register, reg_id, reg_val);
                            }
                        }
                    }
                }
            }

            version (analysis_log)
                atomicOp!"+="(this.log_commits_walked, commits_walked_acc);

            return clobber;
        }

        struct CommitCacheInfoKey {
            InfoType type;
            TRegWord data;
        }

        struct CommitEffectIndexItem {
            CommitCacheInfoKey[] effect_keys;
        }

        CommitEffectIndexItem[ulong] commit_effect_index_cache;
        struct CommitEffectTouchersItem {
            ulong[] commit_ids;
        }

        CommitEffectTouchersItem[CommitCacheInfoKey] commit_effect_touchers_cache;

        void calculate_commit_indexes() {
            // create indexes for the commit trace so it's easy to find who last touched a given register or memory
            foreach (i, commit; trace.commits) {
                CommitCacheInfoKey[] commit_effect_keys;
                // for each effect
                foreach (j, effect; commit.effects) {
                    auto info_key = CommitCacheInfoKey(effect.type, effect.data);

                    // add the effect to the index
                    commit_effect_keys ~= info_key;

                    // try adding to touchers cache
                    if (info_key !in commit_effect_touchers_cache) {
                        commit_effect_touchers_cache[info_key] = CommitEffectTouchersItem();
                    }
                    commit_effect_touchers_cache[info_key].commit_ids ~= i;
                }

                // save the index
                commit_effect_index_cache[i] = CommitEffectIndexItem(commit_effect_keys);

                // writefln("saved effect keys for commit #%d: %s", i, commit_effect_keys);
            }

            // writefln("info key toucher cache: %s", commit_effect_touchers_cache);

            // rehash maps
            commit_effect_index_cache.rehash();
            commit_effect_touchers_cache.rehash();
        }

        // long find_last_commit_at_pc(TRegWord pc_val, long from_commit) {
        //     for (auto i = from_commit; i >= 0; i--) {
        //         auto commit = &trace.commits[i];
        //         version (analysis_log)
        //             atomicOp!"+="(this.log_commits_walked, 1);
        //         if (commit.pc == pc_val) {
        //             return i;
        //         }
        //     }

        //     return -1; // none found
        // }

        long find_commit_last_touching(InfoNode node, long from_commit) {
            pragma(inline, true) long find_last_touch_with_caches(CommitCacheInfoKey info_key) {
                // use the toucher cache to quickly find the last commit that touched this item
                // we can simply binary search for the largest commit id that is below from_commit

                if (info_key !in commit_effect_touchers_cache)
                    return -1; // no known touchers for this item

                auto cached_commit_ids = commit_effect_touchers_cache[info_key].commit_ids;
                long cached_commit_ids_length = cached_commit_ids.length;
                enforce(cached_commit_ids_length > 0, "touchers cache should have at least one commit id");

                // basic binary search for a suitable commit id
                long cached_commit_ids_high = cached_commit_ids_length - 1;
                long cached_commit_ids_low = 0;
                while (cached_commit_ids_low <= cached_commit_ids_high) {
                    long cached_commit_ids_mid = (cached_commit_ids_low + cached_commit_ids_high) / 2;
                    // writefln("bounds this step: %s %s %s", cached_commit_ids_low, cached_commit_ids_mid, cached_commit_ids_high);
                    if (cached_commit_ids[cached_commit_ids_mid] <= from_commit) {
                        cached_commit_ids_low = cached_commit_ids_mid + 1;
                    } else {
                        cached_commit_ids_high = cached_commit_ids_mid - 1;
                    }
                }

                if (cached_commit_ids_high < 0)
                    return -1; // none found

                // check if we found a suitable commit id
                // writefln("bsearch results below %s in %s: %s %s", from_commit, cached_commit_ids, cached_commit_ids_low, cached_commit_ids_high);
                if (cached_commit_ids[cached_commit_ids_high] <= from_commit) {
                    // writefln("found commit id via bsearch: %d", cached_commit_ids[cached_commit_ids_high]);
                    return cached_commit_ids[cached_commit_ids_high];
                }

                // failure
                return -1;
            }

            if (node.type & InfoType.Register) {
                auto info_key = CommitCacheInfoKey(InfoType.Register, node.data);
                auto cached_commit_id = find_last_touch_with_caches(info_key);
                if (cached_commit_id >= 0) {
                    return cached_commit_id;
                }

                // if we're still here, then we haven't found a commit that touches this TRegSet
                // it's possible the TRegSet wasn't touched because it was already in place before the initial snapshot
                // to check this, we'll verify if the expected TRegSet value can be found in the initial snapshot
                if (snap_init.reg[node.data] == node.value) {
                    // the expected value exists in the initial snapshot
                    // so there's no commit from it because it was before initial
                    return -1;
                }

                // if we're here, we've failed
                mixin(LOG_ERROR!(
                        `format("ERROR: no touching or matching initial found: %s", node)`));
            } else if (node.type & InfoType.Memory) {
                auto info_key = CommitCacheInfoKey(InfoType.Memory, node.data);
                auto cached_commit_id = find_last_touch_with_caches(info_key);
                if (cached_commit_id >= 0) {
                    return cached_commit_id;
                }

                // if we're still here, that means we haven't found a commit that touches this memory position
                // it's possible the memory wasn't touched because it was already in place before the initial snapshot
                // to check this, we'll verify if the expected memory value can be found in the initial snapshot
                if (snap_init.get_mem(node.data) == node.value) {
                    // the expected memory value is the same as the initial memory value
                    // this means the memory was already in place
                    return -1;
                }

                // if we're here, we've failed
                mixin(LOG_ERROR!(
                        `format("ERROR: no touching or matching initial found: %s", node)`));
            } else if (node.type & InfoType.CSR) {
                auto info_key = CommitCacheInfoKey(InfoType.CSR, node.data);
                auto cached_commit_id = find_last_touch_with_caches(info_key);
                if (cached_commit_id >= 0) {
                    return cached_commit_id;
                }

                if (snap_init.get_csr(node.data) == node.value) {
                    return -1;
                }
                // if we're here, we've failed
                mixin(LOG_ERROR!(
                        `format("ERROR: no touching or matching initial found: %s", node)`));
            } else {
                enforce(0, format("we don't know how to find a last commit touching a node of type %s", node
                        .type));
                assert(0);
            }
            enforce(0, format("could not find touching commit for node: %s, commit <= #%d", node, from_commit));
            assert(0);
        }

        struct InfoNodeWalk {
            InfoNode node;
            // long commit_ix;
            long owner_commit_ix; // which commit this infonode is in
            long walk_commit_ix; // which commit to walk this back from

            Nullable!IFTGraphNode parent;

            // size_t toHash() const @safe nothrow {
            //     size_t hash;

            //     hash += typeid(node).getHash(&node);
            //     hash += typeid(owner_commit_ix).getHash(&owner_commit_ix);
            //     hash += typeid(walk_commit_ix).getHash(&walk_commit_ix);
            //     hash += typeid(parent).getHash(&parent);

            //     return hash;
            // }
        }

        struct InformationFlowBacktrace {
            size_t[] terminal_leaves;
            Nullable!IFTGraphNode maybe_graph_vert;
        }

        InformationFlowBacktrace backtrace_information_flow(InfoNode last_node) {
            mixin(LOG_INFO!(`format("backtracing information flow for node: %s", last_node)`));

            // 1. get the commit corresponding to this node
            auto last_node_last_touch_ix =
                find_commit_last_touching(last_node, last_commit_ix);
            // writefln("found last touching commit (#%s) for node: %s: %s",
            //     last_node_last_touch_ix, last_node, trace.commits[last_node_last_touch_ix]);

            auto unvisited = DList!InfoNodeWalk();
            bool[InfoNodeWalk] visited;

            version (analysis_log) {
                long found_sources_acc = 0;
                long visited_info_nodes_acc = 0;
                long graph_nodes_walked_acc = 0;
                long graph_nodes_cache_hits_acc = 0;
                long graph_nodes_cache_misses_acc = 0;
                long node_walk_duplicates_acc = 0;
            }

            // auto terminal_leaves = appender!(InfoLeaf[]);
            auto terminal_leaves_ids = appender!(size_t[]);

            IFTGraphNode create_graph_vert(IFTGraphNode parent_vert, InfoNode curr_node, ulong commit_ix) {
                // create a graph vert for this commit
                version (analysis_log)
                    graph_nodes_walked_acc++;

                // use a cache so that we don't create duplicate vertices
                IFTGraphNode curr_graph_vert;

                // auto parent_vert = curr.parent.get;
                // auto curr_node = curr.node;

                auto cached_graph_vert = ift_graph.find_in_cache(commit_ix, curr_node);
                if (cached_graph_vert) {
                    // if (likely(cached_graph_vert !is null)) {
                    curr_graph_vert = cached_graph_vert;

                    mixin(LOG_DEBUG!(
                            `format("   reused graph node: %s", curr_graph_vert)`));

                    version (analysis_log)
                        graph_nodes_cache_hits_acc++;
                } else {
                    curr_graph_vert = new IFTGraphNode(InfoView(curr_node, commit_ix));
                    ift_graph.add_node(curr_graph_vert);

                    mixin(LOG_DEBUG!(
                            `format("   added graph node: %s", curr_graph_vert)`));

                    version (analysis_log)
                        graph_nodes_cache_misses_acc++;
                }

                // update node flags
                auto vert_flags = IFTGraphNode.Flags.Propagated;
                if (curr_node.is_final())
                    vert_flags |= IFTGraphNode.Flags.Final;
                if (curr_node.is_deterministic())
                    vert_flags |= IFTGraphNode.Flags.Deterministic;
                curr_graph_vert.flags = vert_flags;

                // connect ourselves to our parent (parent comes in the future, so edge us -> parent)
                mixin(LOG_DEBUG!(
                        `format("   adding graph edge: %s -> %s", curr_graph_vert, parent_vert)`));

                auto graph_edge = IFTGraphEdge(curr_graph_vert, parent_vert);
                if (!ift_graph.edge_exists(graph_edge, true)) {
                    ift_graph.add_edge(graph_edge);
                }

                return curr_graph_vert;
            }

            pragma(inline, true) void add_info_leaf(InfoNodeWalk walk, InfoLeaf leaf) {
                // terminal_leaves ~= leaf;

                auto leaf_ix = global_info_leafs_buffer.length;
                synchronized {
                    global_info_leafs_buffer ~= leaf;
                }

                terminal_leaves_ids ~= leaf_ix;

                version (analysis_log)
                    found_sources_acc++;

                // add a leaf node to the graph
                if (enable_ift_graph) {
                    enforce(!walk.parent.isNull, "walk.parent is null");
                    auto graph_vert = create_graph_vert(walk.parent.get, leaf.node, leaf.commit_id);
                }
            }

            Nullable!IFTGraphNode maybe_last_node_vert;
            if (enable_ift_graph) {
                // add our "last node" to the graph

                IFTGraphNode last_node_vert;

                auto cached_graph_vert = ift_graph.find_in_cache(last_node_last_touch_ix, last_node);
                if (cached_graph_vert) {
                    last_node_vert = cached_graph_vert;
                } else {
                    last_node_vert = new IFTGraphNode(InfoView(last_node, last_node_last_touch_ix));
                    ift_graph.add_node(last_node_vert);
                }

                maybe_last_node_vert = last_node_vert;
            }

            // 3. queue our initial node
            // this is the last node, and we'll queue it initially with itself as is parent
            unvisited.insertFront(
                InfoNodeWalk(last_node, last_node_last_touch_ix, last_node_last_touch_ix, maybe_last_node_vert));

            // 4. iterative dfs
            while (!unvisited.empty) {
                // get current from first unvisited node
                auto curr = unvisited.front;

                // mark as visited
                unvisited.removeFront();
                visited[curr] = true;

                mixin(LOG_DEBUG!(
                        `format("  visiting: node: %s (#%s), walk: %s", curr.node, curr.owner_commit_ix, curr.walk_commit_ix)`));

                if (curr in global_node_walk_visited) {
                    version (analysis_log)
                        node_walk_duplicates_acc++;

                    if (aggressive_revisit_skipping) {
                        // the fast-track path: we've already visited this node, which implies we've already fully walked its hierarchy
                        // so we can pull its hierarchy from the cache, if it's available

                        // NOTE: when aggressively skipping revisits, that means another backtrace visited this node, and thus all its children
                        // if we simply skip it, we won't include all the children in the terminals of this backtrace
                        // but if we are just building the graph, then this is no problem

                        // TODO: get the cached terminal leaves from the cache ???

                        mixin(LOG_DEBUG!(
                                `format("   skipping revisit, already visited globally")`));

                        // for now, just skip this iteration
                        continue;
                    }
                } else {
                    // synchronized { global_node_walk_visited[curr] = true; }
                    global_node_walk_visited[curr] = true;
                }

                version (analysis_log)
                    visited_info_nodes_acc++;

                if (curr.node.type == InfoType.Immediate
                    || curr.node.type == InfoType.Device
                    || curr.node.type == InfoType.CSR) {
                    // we found raw source data, no dependencies
                    // this is a leaf source, so we want to record it
                    // all data comes from some sort of leaf source
                    auto leaf = InfoLeaf(curr.node, curr.owner_commit_ix);
                    add_info_leaf(curr, leaf);
                    mixin(LOG_DEBUG!(`format("   leaf (source): %s", leaf)`));

                    continue;
                }

                // check if this is MMIO memory
                if (curr.node.type == InfoType.Memory) {
                    // this is a memory node
                    // let's check the memory map type of this address
                    auto mem_addr = curr.node.data;
                    auto mem_type = snap_init.get_mem_type(mem_addr);
                    if (mem_type == MemoryMap.Type.Device) {
                        // this memory is mmio/device mapped memory
                        // we should treat it just like a device (leaf) source
                        // we should record this as a leaf source
                        // let's update the type to mmio
                        curr.node.type = InfoType.MMIO;
                        auto leaf = InfoLeaf(curr.node, curr.owner_commit_ix);
                        add_info_leaf(curr, leaf);
                        mixin(LOG_DEBUG!(`format("   leaf (mmio): %s", leaf)`));

                        continue;
                    }
                }

                // check if this is PC register
                if (curr.node.type == InfoType.Register && curr.node.data == PC_REGISTER) {
                    // this is a PC register
                    // we should treat it just like an immediate (leaf) source
                    // we should record this as a leaf source

                    // treat PC as a deterministic register
                    curr.node.type = InfoType.DeterminateRegister;

                    auto leaf = InfoLeaf(curr.node, curr.owner_commit_ix);
                    add_info_leaf(curr, leaf);
                    mixin(LOG_DEBUG!(`format("   leaf (pc): %s", leaf)`));

                    continue;
                }

                // get last touching commit for this node
                auto touching_commit_ix = find_commit_last_touching(curr.node, curr.walk_commit_ix);

                if (touching_commit_ix < 0) {
                    // this means some information was found to have been traced to the initial snapshot
                    // this counts as a leaf node

                    // add the deterministic flag
                    curr.node.type |= InfoType.DeterminateValue;

                    auto leaf = InfoLeaf(curr.node, -1); // the current node came from the initial snapshot
                    add_info_leaf(curr, leaf);
                    mixin(LOG_DEBUG!(`format("   leaf (pre-initial): %s", leaf)`));

                    continue;
                }

                // we successfully found a touching commit

                auto touching_commit = trace.commits[touching_commit_ix];
                mixin(LOG_DEBUG!(`format("   found last touching commit (#%s) for node: %s: %s",
                        touching_commit_ix, curr, touching_commit)`));

                // create an inner node in the graph for this commit
                Nullable!IFTGraphNode maybe_curr_graph_vert;
                if (enable_ift_graph) {
                    auto parent = curr.parent.get();
                    auto vert_commit_id = touching_commit_ix;

                    // ensure parent is not the same as the current node: if it is make sure we don't create a cycle
                    if (parent.info_view.node != curr.node && parent.info_view.commit_id != vert_commit_id) {
                        maybe_curr_graph_vert = create_graph_vert(parent, curr.node, vert_commit_id);
                    } else {
                        mixin(LOG_DEBUG!(
                                `format("    parent is same as current node, skipping adding vert")`));
                        maybe_curr_graph_vert = parent;
                    }

                    // update node flags
                    maybe_curr_graph_vert.get.flags = IFTGraphNode.Flags.Inner;
                }

                // get all dependencies of this commit
                auto deps = touching_commit.sources.reverse;
                for (auto i = 0; i < deps.length; i++) {
                    auto dep = deps[i];
                    mixin(LOG_DEBUG!(
                            `format("    found dependency: %s (#%s)", dep, touching_commit_ix)`));

                    // where did this dependency's information come from?
                    // to find out we have to look for previous commits that created this dependency
                    // we have to search in commits before this one, because the dependency already had its value
                    // so we should walk through commits touching that dependency
                    // so we add it to our visit queue
                    auto walk_commit_ix = touching_commit_ix - 1;
                    auto dep_walk = InfoNodeWalk(dep, touching_commit_ix, walk_commit_ix, maybe_curr_graph_vert);

                    // if we have not visited this dependency yet, add it to the unvisited list
                    if (!visited.get(dep_walk, false)) {
                        unvisited.insertFront(dep_walk);
                        // mixin(LOG_DEBUG!(`format("     queued walk: %s", dep_walk)`));
                    }
                }
            }

            version (analysis_log) {
                atomicOp!"+="(this.log_found_sources, found_sources_acc);
                atomicOp!"+="(this.log_visited_info_nodes, visited_info_nodes_acc);
                atomicOp!"+="(this.log_graph_nodes_walked, graph_nodes_walked_acc);
                atomicOp!"+="(this.log_graph_nodes_cache_hits, graph_nodes_cache_hits_acc);
                atomicOp!"+="(this.log_graph_nodes_cache_misses, graph_nodes_cache_misses_acc);
                atomicOp!"+="(this.log_global_node_walk_duplicates, node_walk_duplicates_acc);
            }

            // if (enable_ift_graph && enable_ift_subtree) {
            //     auto dep_subtree = find_graph_node_dependency_subtree(maybe_last_node_vert.get);

            //     // store subtree
            //     ift_subtrees ~= dep_subtree;
            // }

            // return terminal_leaves.data;
            // return terminal_leaves_ids.data;

            return InformationFlowBacktrace(terminal_leaves_ids.data, maybe_last_node_vert);
        }

        void analyze_flows() {
            import std.parallelism;

            // 1. backtrace all clobbered registers
            // queue work
            InfoNode[] reg_last_nodes;
            auto clobbered_reg_ids = clobber.get_effect_reg_ids().array;
            auto clobbered_reg_values = clobber.get_effect_reg_values().array;
            for (auto clobbered_i = 0; clobbered_i < clobbered_reg_ids.length; clobbered_i++) {
                auto reg_id = clobbered_reg_ids[clobbered_i].to!TRegSet;
                auto reg_val = clobbered_reg_values[clobbered_i];

                // create an info node for this point
                auto reg_last_node = InfoNode(InfoType.Register, reg_id, reg_val);
                reg_last_nodes ~= reg_last_node;
            }

            // 2. backtrace all clobbered memory
            // queue work
            InfoNode[] mem_last_nodes;
            auto clobbered_mem_addrs = clobber.get_effect_mem_addrs().array;
            auto clobbered_mem_values = clobber.get_effect_mem_values().array;
            for (auto clobbered_i = 0; clobbered_i < clobbered_mem_addrs.length; clobbered_i++) {
                auto mem_addr = clobbered_mem_addrs[clobbered_i];
                auto mem_val = clobbered_mem_values[clobbered_i];

                // create an info node for this point
                auto mem_last_node = InfoNode(InfoType.Memory, mem_addr, mem_val);
                mem_last_nodes ~= mem_last_node;
            }

            // 3. backtrace all clobbered csrs
            // queue work
            InfoNode[] csr_last_nodes;
            auto clobbered_csr_ids = clobber.get_effect_csr_ids().array;
            auto clobbered_csr_values = clobber.get_effect_csr_values().array;
            for (auto clobbered_i = 0; clobbered_i < clobbered_csr_ids.length; clobbered_i++) {
                auto csr_id = clobbered_csr_ids[clobbered_i];
                auto csr_val = clobbered_csr_values[clobbered_i];

                // create an info node for this point
                auto csr_last_node = InfoNode(InfoType.CSR, csr_id, csr_val);
                csr_last_nodes ~= csr_last_node;
            }

            pragma(inline, true) void log_found_sources(InfoLeaf[] sources) {
                if (analysis_parallelized) {
                    // assert(0, "log_found_sources should not be called when parallel enabled");
                    return;
                }

                mixin(LOG_INFO!(
                        `format(" sources found: %s", sources.length)`));
            }

            pragma(inline, true) void do_reg_trace(InfoNode last_node) {
                // auto reg_sources = backtrace_information_flow(last_node);
                // log_found_sources(reg_sources);
                // clobbered_regs_sources[cast(TRegSet) last_node.data] = reg_sources;
                auto reg_backtrace = backtrace_information_flow(last_node);
                clobbered_regs_sources[cast(TRegSet) last_node.data] = reg_backtrace
                    .terminal_leaves;

                if (enable_ift_graph) {
                    final_graph_verts ~= reg_backtrace.maybe_graph_vert.get;
                }
            }

            pragma(inline, true) void do_mem_trace(InfoNode last_node) {
                // auto mem_sources = backtrace_information_flow(last_node);
                // log_found_sources(mem_sources);
                // clobbered_mem_sources[last_node.data] = mem_sources;
                auto mem_backtrace = backtrace_information_flow(last_node);
                clobbered_mem_sources[last_node.data] = mem_backtrace.terminal_leaves;

                if (enable_ift_graph) {
                    final_graph_verts ~= mem_backtrace.maybe_graph_vert.get;
                }
            }

            pragma(inline, true) void do_csr_trace(InfoNode last_node) {
                // auto csr_sources = backtrace_information_flow(last_node);
                // log_found_sources(csr_sources);
                // clobbered_csr_sources[last_node.data] = csr_sources;
                auto csr_backtrace = backtrace_information_flow(last_node);
                clobbered_csr_sources[last_node.data] = csr_backtrace.terminal_leaves;

                if (enable_ift_graph) {
                    final_graph_verts ~= csr_backtrace.maybe_graph_vert.get;
                }
            }

            // select serial/parallel task
            // do work

            auto gen_analyze_work_loops()() {
                auto sb = appender!string;

                enum TRACE_ITEMS = ["reg", "mem", "csr"];
                foreach (item; TRACE_ITEMS) {
                    auto work_loop = format(`
                        foreach (last_node; %s_last_nodes) {
                            do_%s_trace(last_node);
                        }
                    `, item, item);
                    sb ~= format(`
                        if (analysis_parallelized) {
                            auto %s_last_nodes_work = parallel(%s_last_nodes);
                            %s
                        } else {
                            auto %s_last_nodes_work = %s_last_nodes;
                            %s
                        }
                    `, item, item, work_loop, item, item, work_loop);
                }

                return sb.data;
            }

            mixin(gen_analyze_work_loops!());
        }

        IFTGraphNode[] find_graph_node_dependency_subtree(IFTGraphNode node_root) {
            // the node root is the final endpoint of the subtree
            // we want to search upward and find all the inner and leaf nodes

            // we can do an iterative depth-first search
            struct SubtreeSearchWalk {
                IFTGraphNode node;
                size_t depth;
                // IFTGraphSubtree parent;
            }

            auto unvisited = DList!SubtreeSearchWalk();
            bool[SubtreeSearchWalk] visited;

            // IFTGraphNode[] subtree_nodes;
            auto subtree_nodes = appender!(IFTGraphNode[]);

            // auto root_subtree = new IFTGraphSubtree(node_root);

            // add initial node to the unvisited list
            unvisited.insertFront(SubtreeSearchWalk(node_root, 0));

            mixin(LOG_DEBUG!(`format(" building dependency subtree for node: %s", node_root)`));

            while (!unvisited.empty) {
                // get current from first unvisited node
                auto curr = unvisited.front;

                // mark as visited
                unvisited.removeFront();
                visited[curr] = true;

                subtree_nodes ~= curr.node;

                mixin(LOG_DEBUG!(`format("  visiting node: %s", curr)`));

                // get all dependencies: which are nodes that point to this one
                auto deps = ift_graph.get_edges_to(curr.node);
                for (auto i = 0; i < deps.length; i++) {
                    auto dep = deps[i];

                    mixin(LOG_DEBUG!(`format("   found dependency: %s", dep)`));

                    // check if the dependency is a loop
                    enforce(dep.src != curr.node,
                        format("found loop in dependency subtree between %s and %s", curr.node, dep
                            .src));

                    // auto dep_walk = SubtreeSearchWalk(dep.src, curr.depth + 1, subtree_node);
                    auto dep_walk = SubtreeSearchWalk(dep.src, curr.depth + 1);
                    // NOTE: a node can be queued multiple times at different depths

                    // if we have not visited this dependency yet, add it to the unvisited list
                    if (!visited.get(dep_walk, false)) {
                        unvisited.insertFront(dep_walk);
                        mixin(LOG_DEBUG!(`format("     queued walk: %s", dep_walk)`));
                    }
                }
            }

            // return root_subtree;
            return subtree_nodes.data;
        }

        void propagate_node_flags() {
            // propagate the flow of node flags
            mixin(LOG_INFO!(`"propagating node flags"`));

            auto tmr_start = MonoTime.currTime;

            // make a list of leaf nodes that already are propagated
            // IFTGraphNode[] propagated_leaf_nodes;
            auto propagated_leaf_nodes = appender!(IFTGraphNode[]);
            mixin(LOG_INFO!(`" building list of propagated leaf nodes"`));
            foreach (i, vert; ift_graph.nodes) {
                if ((vert.flags & IFTGraphNode.Flags.Propagated) > 0) {
                    propagated_leaf_nodes ~= vert;
                }
            }

            // for each leaf node, propagate the flags to nodes they point to
            import std.algorithm.searching : countUntil;

            mixin(LOG_INFO!(
                    `format(" propagating %d leaf nodes", propagated_leaf_nodes.data.length)`));

            auto unvisited = DList!IFTGraphNode();
            bool[IFTGraphNode] visited;

            foreach (i, leaf; propagated_leaf_nodes.data) {
                mixin(LOG_TRACE!(`format(" propagating flags for node: %s", leaf)`));
                // auto subtree_verts = find_graph_node_dependency_subtree(leaf);
                // mixin(LOG_INFO!(`format("  found subtree of %d nodes", subtree_verts.length)`));
                // // find the leaf in the subtree
                // auto leaf_in_subtree = subtree_verts.countUntil(leaf);
                // enforce(subtree_verts[leaf_in_subtree] == leaf, "leaf not found in subtree");

                // if (leaf !in visited)
                //     unvisited.insertFront(leaf);
                unvisited.insertFront(leaf);

                // now propagate upward

                long propagation_nodes_walked_acc = 0;

                while (!unvisited.empty) {
                    auto curr = unvisited.front;
                    unvisited.removeFront();
                    visited[curr] = true;

                    propagation_nodes_walked_acc += 1;

                    mixin(LOG_DEBUG!(`format("  visiting node: %s", curr)`));

                    // if the node is not yet propagated, we can assume that we are the first to touch it
                    if ((curr.flags & IFTGraphNode.Flags.Propagated) == 0) {
                        mixin(LOG_DEBUG!(`format("   copying leaf flags for node: %s", curr)`));
                        curr.flags |= IFTGraphNode.Flags.Propagated;
                        // if the leaf is final, we can also set the final flag
                        if ((leaf.flags & IFTGraphNode.Flags.Final) > 0) {
                            curr.flags |= IFTGraphNode.Flags.Final;
                        }
                        // if the leaf is deterministic, we can also set the deterministic flag
                        if ((leaf.flags & IFTGraphNode.Flags.Deterministic) > 0) {
                            curr.flags |= IFTGraphNode.Flags.Deterministic;
                        }
                    } else {
                        // this node has been previously visited
                        // so we just need to check if there are any contradictions, and update or error accordingly

                        mixin(LOG_DEBUG!(`format("   node already propagated, checking flags")`));

                        // if this node is final, but the leaf is not, we have a contradiction
                        if ((curr.flags & IFTGraphNode.Flags.Final) > 0 &&
                            (leaf.flags & IFTGraphNode.Flags.Final) == 0) {
                            enforce(false, format("contradiction in node flags: %s (%s) is final, but %s (%s) is not",
                                    curr, curr.info_view.node.type, leaf, leaf.info_view.node.type));
                        }

                        // if this node is deterministic, but the leaf is not, we should update the node to be not deterministic
                        if ((curr.flags & IFTGraphNode.Flags.Deterministic) > 0 &&
                            (leaf.flags & IFTGraphNode.Flags.Deterministic) == 0) {
                            curr.flags &= ~IFTGraphNode.Flags.Deterministic;
                        }
                    }

                    // queue all nodes pointed to by the current node
                    auto targets = ift_graph.get_edges_from(curr);
                    foreach (k, target; targets) {
                        auto pointed_target = target.dst;
                        if (!visited.get(pointed_target, false)) {
                            mixin(LOG_DEBUG!(`format("    queuing node: %s", pointed_target)`));
                            unvisited.insertFront(pointed_target);
                        }
                    }
                }

                version (analysis_log)
                    atomicOp!"+="(this.log_propagation_nodes_walked, propagation_nodes_walked_acc);
            }

            auto elapsed = MonoTime.currTime - tmr_start;
            version (analysis_log)
                log_propagation_time = elapsed.total!"usecs";
        }

        void rebuild_graph_caches() {
            auto tmr_start = MonoTime.currTime;

            // rebuild caches for the graph
            mixin(LOG_INFO!(`format(
                "rebuilding graph caches (%d nodes, %d edges)", ift_graph.nodes.length, ift_graph.edges.length)`));
            ift_graph.rebuild_neighbors_cache();
            mixin(LOG_INFO!(`" done building graph caches"`));

            auto elapsed = MonoTime.currTime - tmr_start;
            version (analysis_log)
                log_cache_build_time = elapsed.total!"usecs";
        }

        void analyze_subtrees() {
            mixin(LOG_INFO!(`"analyzing subtrees"`));

            auto num_final_graph_verts = final_graph_verts.length;
            foreach (i, final_vert; final_graph_verts) {
                // analyze the subtree from this vert
                // mixin(LOG_INFO!(`" analyzing subtrees for vert: %s", final_vert`));
                mixin(LOG_TRACE!(
                        `" analyzing subtrees for vert (%d/%d): %s", i, num_final_graph_verts, final_vert`));

                // auto dep_subtree = find_graph_node_dependency_subtree(final_vert);

                // // store subtree
                // ift_subtrees ~= dep_subtree;
            }
        }
    }
}
