module infoflow.analysis.ift.ift_trace;

import std.container.dlist;
import std.typecons;
import std.array : appender, array;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic: atomicOp;

import infoflow.util;
import infoflow.analysis.ift.ift_tree;

template IFTAnalysis(TRegWord, TMemWord, TRegSet) {
    import std.traits;

    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    alias TBaseAnalysis = BaseAnalysis!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    alias TIFTAnalysisTree = IFTAnalysisTree!(TRegWord, TMemWord, TRegSet);
    alias IFTTreeNode = TIFTAnalysisTree.IFTTreeNode;

    static assert([EnumMembers!TRegSet].map!(x => x.to!string)
            .canFind!(x => x == "PC"),
            "enum TRegSet must contain a program counter register PC");
    enum PC_REGISTER = to!TRegSet("PC");

    /** analyzer for dynamic information flow tracking **/
    class IFTAnalyzer : TBaseAnalysis.BaseAnalyzer {
        Commit clobber;
        InfoLeafs[TRegSet] clobbered_regs_sources;
        InfoLeafs[TRegWord] clobbered_mem_sources;
        InfoLeafs[TRegWord] clobbered_csr_sources;
        IFTDataType included_data = IFTDataType.Standard;
        IFTTreeNode[] ift_trees;
        bool enable_ift_tree = false;

        version (analysis_log) {
            shared long log_visited_info_nodes;
            shared long log_commits_walked;
            shared long log_found_sources;
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

        this(CommitTrace commit_trace, bool parallelized = false) {
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
            }

            // calculate diffs and clobber
            calculate_clobber();
            analyze_flows();

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
                    if (snap_init.reg[reg_id] != snap_final.reg[reg_id]) {
                        // this TRegSet changed between the initial and final state
                        // store commit that clobbers this TRegSet
                        clobber.effects ~= InfoNode(InfoType.Register, reg_id, snap_final.reg[reg_id]);
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
                            clobber.effects ~= InfoNode(InfoType.Memory, mem_addr, snap_final.get_mem(mem_addr));
                        }
                    }
                }
            }

            if (included_data & IFTDataType.CSR) {
                foreach (csr_id; snap_init.csr.byKey) {
                    if (snap_init.get_csr(csr_id) != snap_final.get_csr(csr_id)) {
                        // this CSR changed between the initial and final state
                        // store commit that clobbers this CSR
                        clobber.effects ~= InfoNode(InfoType.CSR, csr_id, snap_final.get_csr(csr_id));
                    }
                }
            }

            // 3. do a reverse pass through all commits, looking for special cases
            //    things like devices and mmio, external sources of data

            for (auto i = last_commit_ix; i >= 0; i--) {
                auto commit = trace.commits[i];
                version (analysis_log)
                    atomicOp!"+="(this.log_commits_walked, 1);

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

            return clobber;
        }

        long find_last_commit_at_pc(TRegWord pc_val, long from_commit) {
            for (auto i = from_commit; i >= 0; i--) {
                auto commit = &trace.commits[i];
                version (analysis_log)
                    atomicOp!"+="(this.log_commits_walked, 1);
                if (commit.pc == pc_val) {
                    return i;
                }
            }

            return -1; // none found
        }

        long find_commit_last_touching(InfoNode node, long from_commit) {
            if (node.type & InfoType.Register) {
                // go back through commits until we find one whose results modify this TRegSet
                for (auto i = from_commit; i >= 0; i--) {
                    auto commit = &trace.commits[i];
                    version (analysis_log)
                        atomicOp!"+="(this.log_commits_walked, 1);
                    for (auto j = 0; j < commit.effects.length; j++) {
                        auto effect = commit.effects[j];
                        if (effect.type & InfoType.Register && effect.data == node.data) {
                            // the TRegSet id in the commit results is the same as the reg id in the info node we are searching
                            return i;
                        }
                    }
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
                // go back through commits until we find one whose results modify this memory
                for (auto i = from_commit; i >= 0; i--) {
                    auto commit = &trace.commits[i];
                    version (analysis_log)
                        atomicOp!"+="(this.log_commits_walked, 1);
                    for (auto j = 0; j < commit.effects.length; j++) {
                        auto effect = commit.effects[j];
                        if (effect.type & InfoType.Memory && effect.data == node.data) {
                            // the memory address in the commit results is the same as the mem addr in the info node we are searching
                            return i;
                        }
                    }
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
                // go back through commits until we find one whose results modify this CSR
                for (auto i = from_commit; i >= 0; i--) {
                    auto commit = &trace.commits[i];
                    version (analysis_log)
                        atomicOp!"+="(this.log_commits_walked, 1);
                    
                    for (auto j = 0; j < commit.effects.length; j++) {
                        auto effect = commit.effects[j];
                        if (effect.type & InfoType.CSR && effect.data == node.data) {
                            return i;
                        }
                    }
                }
                if (snap_init.get_csr(node.data) == node.value) {
                    return -1;
                }
                // if we're here, we've failed
                mixin(LOG_ERROR!(
                        `format("ERROR: no touching or matching initial found: %s", node)`));
            } else {
                assert(0, format("we don't know how to find a last commit touching a node of type %s", node
                        .type));
            }
            assert(0, format("could not find touching commit for node: %s, commit <= #%d", node, from_commit));
        }

        InfoLeaf[] backtrace_information_flow(InfoNode last_node) {
            mixin(LOG_INFO!(`format("backtracking information flow for node: %s", last_node)`));

            // 1. get the commit corresponding to this node
            auto last_node_last_touch_ix =
                find_commit_last_touching(last_node, last_commit_ix);
            // writefln("found last touching commit (#%s) for node: %s: %s",
            //     last_node_last_touch_ix, last_node, trace.commits[last_node_last_touch_ix]);

            // 2. data structures for dfs

            struct InfoNodeWalk {
                InfoNode node;
                // long commit_ix;
                long owner_commit_ix; // which commit this infonode is in
                long walk_commit_ix; // which commit to walk this back from

                Nullable!IFTTreeNode parent;
            }

            auto unvisited = DList!InfoNodeWalk();
            bool[InfoNodeWalk] visited;

            auto terminal_leaves = appender!(InfoLeaf[]);

            pragma(inline, true) void add_info_leaf(InfoLeaf leaf) {
                terminal_leaves ~= leaf;
                version (analysis_log)
                    atomicOp!"+="(this.log_found_sources, 1);
            }

            Nullable!IFTTreeNode maybe_tree_root;
            if (enable_ift_tree) {
                // set up the tree
                maybe_tree_root = new IFTTreeNode(last_node_last_touch_ix, last_node);
                ift_trees ~= maybe_tree_root.get;
            }

            // 3. queue our initial node
            unvisited.insertFront(
                InfoNodeWalk(last_node, last_node_last_touch_ix, last_node_last_touch_ix, maybe_tree_root));

            // 4. iterative dfs
            while (!unvisited.empty) {
                // get current from first unvisited node
                auto curr = unvisited.front;

                // mark as visited
                unvisited.removeFront();
                visited[curr] = true;

                mixin(LOG_TRACE!(
                        `format("  visiting: node: %s (#%s), walk: %s", curr.node, curr.owner_commit_ix, curr.walk_commit_ix)`));
                version (analysis_log)
                    atomicOp!"+="(this.log_visited_info_nodes, 1);

                Nullable!IFTTreeNode maybe_curr_tree_node;
                void update_curr_node_tree_flags() {
                    if (!enable_ift_tree)
                        return;
                    maybe_curr_tree_node.get.hierarchy_all_final = curr.node.is_final();
                    maybe_curr_tree_node.get.hierarchy_all_deterministic = curr.node.is_deterministic();
                    maybe_curr_tree_node.get.hierarchy_some_final = curr.node.is_final();
                    maybe_curr_tree_node.get.hierarchy_some_deterministic = curr.node.is_deterministic();
                }

                if (enable_ift_tree) {
                    // create a tree node for this commit
                    auto curr_tree_node = new IFTTreeNode(curr.owner_commit_ix, curr.node);
                    // update our parent, and add ourselves to the parent's children
                    curr_tree_node.parent = curr.parent.get;
                    curr_tree_node.parent.children ~= curr_tree_node;

                    maybe_curr_tree_node = curr_tree_node;

                    // update our final/deterministic flags
                    update_curr_node_tree_flags();
                }

                if (curr.node.type == InfoType.Immediate
                    || curr.node.type == InfoType.Device
                    || curr.node.type == InfoType.CSR) {
                    // we found raw source data, no dependencies
                    // this is a leaf source, so we want to record it
                    // all data comes from some sort of leaf source
                    auto leaf = InfoLeaf(curr.node, curr.owner_commit_ix);
                    add_info_leaf(leaf);
                    mixin(LOG_TRACE!(`format("   leaf (source): %s", leaf)`));

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
                        add_info_leaf(leaf);
                        mixin(LOG_TRACE!(`format("   leaf (mmio): %s", leaf)`));

                        continue;
                    }
                }

                // check if this is PC register
                if (curr.node.type == InfoType.Register && curr.node.data == PC_REGISTER) {
                    // this is a PC register
                    // we should treat it just like an immediate (leaf) source
                    // we should record this as a leaf source

                    // treat PC as a deterministic register
                    curr.node.type = InfoType.DeterministicRegister;

                    update_curr_node_tree_flags();

                    auto leaf = InfoLeaf(curr.node, curr.owner_commit_ix);
                    add_info_leaf(leaf);
                    mixin(LOG_TRACE!(`format("   leaf (pc): %s", leaf)`));

                    continue;
                }

                // get last touching commit for this node
                auto touching_commit_ix = find_commit_last_touching(curr.node, curr.walk_commit_ix);

                if (touching_commit_ix < 0) {
                    // this means some information was found to have been traced to the initial snapshot
                    // this counts as a leaf node

                    auto leaf = InfoLeaf(curr.node, -1); // the current node came from the initial snapshot
                    add_info_leaf(leaf);
                    mixin(LOG_TRACE!(`format("   leaf (pre-initial): %s", leaf)`));

                    continue;
                }

                auto touching_commit = trace.commits[touching_commit_ix];
                mixin(LOG_TRACE!(`format("   found last touching commit (#%s) for node: %s: %s",
                        touching_commit_ix, curr, touching_commit)`));

                // get all dependencies of this commit
                auto deps = touching_commit.sources.reverse;
                for (auto i = 0; i < deps.length; i++) {
                    auto dep = deps[i];
                    mixin(LOG_TRACE!(
                            `format("    found dependency: %s (#%s)", dep, touching_commit_ix)`));

                    // where did this dependency's information come from?
                    // to find out we have to look for previous commits that created this dependency
                    // we have to search in commits before this one, because the dependency already had its value
                    // so we should walk through commits touching that dependency
                    // so we add it to our visit queue
                    auto walk_commit_ix = touching_commit_ix - 1;
                    auto dep_walk = InfoNodeWalk(dep, touching_commit_ix, walk_commit_ix, maybe_curr_tree_node);

                    // if we have not visited this dependency yet, add it to the unvisited list
                    if (!visited.get(dep_walk, false)) {
                        unvisited.insertFront(dep_walk);
                        // mixin(LOG_TRACE!(`format("     queued walk: %s", dep_walk)`));
                    }
                }
            }

            if (enable_ift_tree) {
                analyze_tree_children(maybe_tree_root.get);
            }

            return terminal_leaves.data;
        }

        void analyze_tree_children(IFTTreeNode tree_root) {
            // now do a post order traversal of the tree
            auto tree_po_s = DList!IFTTreeNode();
            auto tree_po_path = DList!IFTTreeNode();

            tree_po_s.insertFront(tree_root); // push root onto stack
            while (!tree_po_s.empty) {
                auto root = tree_po_s.front;

                if (!tree_po_path.empty && tree_po_path.front == root) {
                    // both are equal, so we can pop from both

                    if (root.children.length > 0) {
                        // this is an inner node, update hierarchy final/deterministic flags

                        auto all_children_final = true;
                        auto all_children_deterministic = true;

                        auto some_children_final = false;
                        auto some_children_deterministic = false;

                        for (auto i = 0; i < root.children.length; i++) {
                            if (!some_children_final && root.children[i].hierarchy_some_final) {
                                // we found a child that has some final
                                some_children_final = true;
                            }
                            if (!some_children_deterministic && root
                                .children[i].hierarchy_some_deterministic) {
                                // we found a child that has some deterministic
                                some_children_deterministic = true;
                            }

                            if (all_children_final && !root.children[i].hierarchy_all_final) {
                                // we found a child that does not have all final
                                all_children_final = false;
                            }
                            if (all_children_deterministic && !root
                                .children[i].hierarchy_all_deterministic) {
                                // we found a child that does not have all deterministic
                                all_children_deterministic = false;
                            }
                        }
                        root.hierarchy_some_final = some_children_final;
                        root.hierarchy_some_deterministic = some_children_deterministic;
                        root.hierarchy_all_final = all_children_final;
                        root.hierarchy_all_deterministic = all_children_deterministic;
                    }

                    tree_po_s.removeFront();
                    tree_po_path.removeFront();
                } else {
                    // push onto path
                    tree_po_path.insertFront(root);

                    // push children in reverse order
                    for (auto i = cast(long)(root.children.length) - 1; i >= 0;
                        i--) {
                        auto child = root.children[i];
                        tree_po_s.insertFront(child);
                    }
                }
            }
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
                        `format(" sources found: %s (~ %.3f KiB)", sources.length,
                    (sources.length * InfoNode.sizeof) / 1024.0)`));
                if (enable_ift_tree) {
                    auto last_tree = ift_trees[$ - 1];
                    mixin(LOG_INFO!(
                            `format(" last tree: %s, (~ %.3f KiB)", last_tree,
                        (sources.length * TIFTAnalysisTree.IFTTreeNodeMemSize) / 1024.0)`));

                }
            }

            pragma(inline, true) void do_reg_trace(InfoNode last_node) {
                auto reg_sources = backtrace_information_flow(last_node);
                log_found_sources(reg_sources);
                clobbered_regs_sources[cast(TRegSet) last_node.data] = reg_sources;
            }

            pragma(inline, true) void do_mem_trace(InfoNode last_node) {
                auto mem_sources = backtrace_information_flow(last_node);
                log_found_sources(mem_sources);
                clobbered_mem_sources[last_node.data] = mem_sources;
            }

            pragma(inline, true) void do_csr_trace(InfoNode last_node) {
                auto csr_sources = backtrace_information_flow(last_node);
                log_found_sources(csr_sources);
                clobbered_csr_sources[last_node.data] = csr_sources;
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
    }
}
