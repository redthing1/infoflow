module infoflow.models.commit;

import std.algorithm.mutation;

template InfoLog(TRegWord, TMemWord, TRegSet) {
    import std.traits;

    enum REGISTER_COUNT = [EnumMembers!TRegSet].length;
    static assert(REGISTER_COUNT > 0, "register count must be greater than 0");

    template GenAliases(string prefix) {
        import std.format;

        enum GenAliases = format(`
            alias Snapshot = %s.Snapshot;
            alias Commit = %s.Commit;
            alias CommitTrace = %s.CommitTrace;
            alias InfoType = %s.InfoType;
            alias InfoNode = %s.InfoNode;
            alias InfoSource = %s.InfoSource;
            alias InfoSources = %s.InfoSources;
            alias ImmediatePos = %s.ImmediatePos;
            alias MemoryMap = %s.MemoryMap;
            alias MemoryPageTable = %s.MemoryPageTable;
        `, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix);
    }

    struct MemoryMap {
        enum Type {
            Unknown,
            Memory,
            Device,
        }

        Type type;
        TRegWord base_address;
        string section_name;
    }

    struct MemoryPageTable {
        enum PAGE_SIZE = 4096;
        struct Page {
            TRegWord address;
            TMemWord[] mem;
        }

        Page[TRegWord] pages;

        public bool get_page(TRegWord address, out Page page, out TRegWord page_base_address) {
            // get base address
            auto base_address = address & ~(PAGE_SIZE - 1);
            page_base_address = base_address;
            if (base_address in pages) {
                page = pages[base_address];
                return true;
            }
            page = Page.init;
            return false;
        }

        public Page make_page(TRegWord address) {
            import std.format;

            auto base_address = address & ~(PAGE_SIZE - 1);
            // assert(base_address == address, "page base address must be aligned");
            assert(base_address == address, format("page base address must be aligned: %08x", address));
            assert(base_address !in pages, "page at address already exists");

            // make new page
            Page page;
            page.address = base_address;
            page.mem.length = PAGE_SIZE;
            pages[base_address] = page;

            return page;
        }
    }

    struct Snapshot {
        public TRegWord[REGISTER_COUNT] reg;
        public MemoryMap[] memory_map;
        public MemoryPageTable tracked_mem;

        // access functions
        public TRegWord get_reg(ulong id) {
            return reg[id];
        }

        public TMemWord get_mem(TRegWord addr) {
            // try to get the page for this address
            MemoryPageTable.Page page;
            TRegWord page_base_address;
            if (!tracked_mem.get_page(addr, page, page_base_address)) {
                import std.format;
                // failed to find the page
                // import std.stdio;
                // writefln("the current pages:");
                // foreach (page; tracked_mem.pages) {
                //     writefln("- $%08x", page.address);
                // }
                assert(0, format("failed to find page for address 0x%x (base address 0x%x)", addr, page_base_address));
            }

            // get the memory word
            return page.mem[addr - page.address];   
        }

        public MemoryMap.Type get_mem_type(TRegWord addr) {
            // gp through memory map in reverse
            for (auto i = (cast(long) memory_map.length) - 1; i >= 0; i--) {
                auto map = memory_map[i];
                if (map.base_address <= addr) {
                    // one of the entries has base address below our address
                    return map.type;
                }
            }
            // ??
            import std.format : format;

            assert(0, format("no memory map entry found for address: %s", addr));
            // return MemoryMap.Type.Unknown;
        }
    }

    enum InfoType {
        Unknown = 0x0,
        None = 0x1,
        Register = 1 << 2,
        Memory = 1 << 3,
        Immediate = 1 << 4,
        Combined = Register | Memory | Immediate,
        Device = 1 << 6,
        CSR = Register | (1 << 7),
        MMIO = Memory | Device,
        DeterministicRegister = Register | (1 << 8),
        Reserved2,
        Reserved3,
        Reserved4,
    }

    enum ImmediatePos : TRegWord {
        NONE = (0 << 0),
        A = (1 << 0),
        B = (1 << 1),
        C = (1 << 2),
        D = (1 << 3),
        E = (1 << 4),
        F = (1 << 5),
        G = (1 << 6),
        H = (1 << 7),

        BC = B | C,

        ABC = A | B | C,
    }

    struct InfoNode {
        InfoType type; // information type: register or memory?
        TRegWord data; // can be register id or memory address
        TRegWord value; // can be register value or memory value

        string toString() const {
            import std.string : format;
            import std.conv : to;
            import std.array : appender, array;

            auto sb = appender!string;

            switch (type) {
            case InfoType.Register:
                sb ~= format("%s=$%04x", data.to!TRegSet, value);
                break;
            case InfoType.Memory:
                sb ~= format("mem[$%08x]=%02x", data, value);
                break;
            case InfoType.Immediate:
                sb ~= format("i=$%04x", value);
                break;
            case InfoType.Device:
                sb ~= format("dev#%02x(%02x)", data, value);
                break;
            case InfoType.CSR:
                sb ~= format("csr#%02x(%02x)", data, value);
                break;
            case InfoType.MMIO:
                sb ~= format("mmio[$%04x]=%02x", data, value);
                break;
            case InfoType.DeterministicRegister:
                sb ~= format("%s=$%04x", data.to!TRegSet, value);
                break;
            default:
                assert(0, format("unhandled info node to string for type %s", type));
            }

            return sb.array;
        }

        bool is_final() const {
            return type == InfoType.Immediate
                || type == InfoType.Device
                || type == InfoType.CSR
                || type == InfoType.MMIO
                || type == InfoType.DeterministicRegister;
        }

        /** returns whether this is a deterministic source */
        bool is_deterministic() const {
            return type == InfoType.Immediate;
        }
    }

    struct Commit {
        private enum string[InfoType] _type_abbreviations = [
                InfoType.Unknown: "unk",
                InfoType.None: "non",
                InfoType.Combined: "cmb",
                InfoType.Register: "reg",
                InfoType.Memory: "mem",
                InfoType.Immediate: "imm",
                InfoType.Device: "dev",
                InfoType.CSR: "csr",
            ];

        alias Source = InfoNode;

        InfoType type;
        /// dest reg ids
        TRegWord[] reg_ids;
        /// dest reg values
        TRegWord[] reg_values;
        /// dest mem addresses
        TRegWord[] mem_addrs;
        /// dest mem values
        TMemWord[] mem_values;
        /// program counter
        TRegWord pc;
        /// sources
        Source[] sources;
        /// description or comment, usually contains disassembled instruction
        string description;

        ref Commit with_type(InfoType type) {
            this.type = type;
            return this;
        }

        ref Commit with_dest_regs(TRegWord[] reg_ids, TRegWord[] reg_values) {
            this.reg_ids = reg_ids;
            this.reg_values = reg_values;
            return this;
        }

        ref Commit with_dest_mem(TRegWord[] mem_addrs, TMemWord[] mem_values) {
            this.mem_addrs = mem_addrs;
            this.mem_values = mem_values;
            return this;
        }

        ref Commit with_pc(TRegWord pc) {
            this.pc = pc;
            return this;
        }

        ref Commit with_sources(Source[] sources) {
            this.sources = sources;
            return this;
        }

        ref Commit with_description(string description) {
            this.description = description;
            return this;
        }

        InfoNode[] as_nodes() {
            InfoNode[] nodes;

            // check info type
            switch (type) {
            case InfoType.Combined:
                assert(0, "combined commit is not supported to create info nodes");
            case InfoType.Register:
                // add a node for each register
                for (auto i = 0; i < reg_ids.length; i++) {
                    auto node = InfoNode(InfoType.Register, reg_ids[i], reg_values[i]);
                    nodes ~= node;
                }
                break;
            case InfoType.Memory:
                // add a node for each memory address
                for (auto i = 0; i < mem_addrs.length; i++) {
                    auto node = InfoNode(InfoType.Memory, mem_addrs[i], mem_values[i]);
                    nodes ~= node;
                }
                break;
            default:
                assert(0, "invalid commit info type for creating info nodes");
            }

            return nodes;
        }

        string toString() const {
            import std.string : format;
            import std.conv : to;
            import std.array : appender, array;

            string type_str = _type_abbreviations[type];

            auto sb = appender!string;

            // commit type
            sb ~= format("%s", type_str);
            // pc position
            sb ~= format(" @0x$%08x", pc);

            // commit data
            // auto reg_id_show = reg_id.to!TRegSet;
            // sb ~= format(" %04s <- $%04x", reg_id_show, reg_value);
            for (auto i = 0; i < reg_ids.length; i++) {
                auto reg_id = reg_ids[i];
                auto reg_value = reg_values[i];
                auto reg_id_show = reg_id.to!TRegSet;
                sb ~= format(" %04s <- $%08x", reg_id_show, reg_value);
            }
            for (auto i = 0; i < mem_addrs.length; i++) {
                auto addr = mem_addrs[i];
                auto value = mem_values[i];
                sb ~= format(" mem[$%08x] <- %02x", addr, value);
            }

            // commit sources
            sb ~= format(" <source: ");
            for (auto i = 0; i < sources.length; i++) {
                auto source = sources[i];
                // string source_type_str = _type_abbreviations[source.type];
                // switch (source.type) {
                // case InfoType.Register : sb ~= format(" %s=$%04x", source.data.to!TRegSet, source.value);
                //     break;
                // case InfoType.Memory : sb ~= format(" mem[$%08x]=%02x", source.data, source.value);
                //     break;
                // case InfoType.Immediate : sb ~= format(" i=$%04x", source.value);
                //     break;
                // case InfoType.Device : sb ~= format(" dev#%02x(%02x)", source.data, source.value);
                // default : assert(0);
                // }
                sb ~= format(" %s", source.toString());
            }
            sb ~= format(">");

            // commit description
            sb ~= format(" (%s)", description);

            return sb.array;
        }
    }

    struct InfoSource {
        InfoNode node;
        long commit_id;

        string toString() const {
            import std.string : format;
            import std.conv : to;
            import std.array : appender, array;

            auto sb = appender!string;

            sb ~= format("InfoSource(node: %s, commit_id: %s)", node, commit_id);

            return sb.array;
        }

        bool is_final() const {
            return node.is_final();
        }

        bool is_deterministic() const {
            return node.is_deterministic();
        }
    }

    alias InfoSources = InfoSource[];

    struct CommitTrace {
        public Snapshot[] snapshots;
        public Commit[] commits;

        // @property long length() {
        //     return commits.length;
        // }
    }
}
