module infoflow.models.commit;

import std.algorithm.mutation;
import std.algorithm.iteration : map, filter, fold;
import std.array: appender, array;
import std.range;

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
            alias InfoLeaf = %s.InfoLeaf;
            alias InfoLeafs = %s.InfoLeafs;
            alias MemoryMap = %s.MemoryMap;
            alias MemoryPageTable = %s.MemoryPageTable;
        `, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix);
    }

    /// memory map entry
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

    /// memory page table: create pages with make_page, get pages with page[page_base_address]
    struct MemoryPageTable {
        /// the size of pages in this table
        enum PAGE_SIZE = 4096;
        
        /// represents a single page
        struct Page {
            TRegWord address;
            TMemWord[] mem;
        }

        /// all the known pages in this page table
        Page[TRegWord] pages;

        /// given a lookup address, get the data of a page and its base address
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

        /// create a new empty page at the specified aligned base address
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

    /// represents a discrete snapshot of system state
    struct Snapshot {
        /// all registers and their values
        public TRegWord[REGISTER_COUNT] reg;
        /// memory map
        public MemoryMap[] memory_map;
        /// memory page table populated with all memory data
        public MemoryPageTable tracked_mem;
        /// all csr and their values
        public TRegWord[TRegWord] csr;

        /// get the value of a register
        public TRegWord get_reg(ulong id) {
            return reg[id];
        }

        /// get the value of a memory address
        public TMemWord get_mem(TRegWord addr) {
            // try to get the page for this address
            MemoryPageTable.Page page;
            TRegWord page_base_address;
            if (!tracked_mem.get_page(addr, page, page_base_address)) {
                import std.format;
                
                assert(0, format("failed to find page for address 0x%x (base address 0x%x)", addr, page_base_address));
            }

            // get the memory word
            return page.mem[addr - page.address];   
        }

        /// get the type of memory at this location from the memory map
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

        /// get the value of a csr
        public TRegWord get_csr(TRegWord addr) {
            return csr[addr];
        }
    }

    /// represents a type of information
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

    /// represents a unit of information, in the form of a (type, data, value) tuple
    struct InfoNode {
        /// information type: could be register, memory, etc.
        InfoType type;
        /// can be register id, memory address, or other, depending on type
        TRegWord data;
        /// can be immediate value, register value, memory value, or other, depending on type
        TRegWord value;

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

        ///  whether this is a final source (cannot be further traced to more sources)
        bool is_final() const {
            return type == InfoType.Immediate
                || type == InfoType.Device
                || type == InfoType.CSR
                || type == InfoType.MMIO
                || type == InfoType.DeterministicRegister;
        }

        ///  whether this is a deterministic source (will always have the same value)
        bool is_deterministic() const {
            return type == InfoType.Immediate;
        }
    }

    /// represents a discrete unit of change in system state, usually corresponds to execution of an instruction
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

        /// the type of effects this commit has
        InfoType type;
        /// program counter
        TRegWord pc;
        /// effects of this commit
        InfoNode[] effects;
        /// sources for this commit
        InfoNode[] sources;
        /// description or comment, usually contains disassembled instruction or other misc info
        string description;

        ref Commit with_type(InfoType type) {
            this.type = type;
            return this;
        }

        ref Commit with_pc(TRegWord pc) {
            this.pc = pc;
            return this;
        }

        ref Commit with_effects(InfoNode[] effects) {
            this.effects = effects;
            return this;
        }

        ref Commit with_sources(InfoNode[] sources) {
            this.sources = sources;
            return this;
        }

        ref Commit with_description(string description) {
            this.description = description;
            return this;
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

            // commit effects
            for (auto i = 0; i < effects.length; i++) {
                auto effect = effects[i];
                if (effect.type == InfoType.Register) {
                    auto reg_id = effect.data;
                    auto reg_value = effect.value;
                    auto reg_id_show = reg_id.to!TRegSet;
                    sb ~= format(" %04s <- $%08x", reg_id_show, reg_value);
                }
                if (effect.type == InfoType.Memory) {
                    auto addr = effect.data;
                    auto value = effect.value;
                    sb ~= format(" mem[$%08x] <- %02x", addr, value);
                }
                if (effect.type == InfoType.CSR) {
                    auto csr_id = effect.data;
                    auto csr_value = effect.value;
                    sb ~= format(" csr#%02x <- $%08x", csr_id, csr_value);
                }
            }

            // commit sources
            sb ~= format(" <source: ");
            for (auto i = 0; i < sources.length; i++) {
                auto source = sources[i];
                sb ~= format(" %s", source.toString());
            }
            sb ~= format(">");

            // commit description
            sb ~= format(" (%s)", description);

            return sb.array;
        }

        pragma(inline, true) {
            auto get_effect_ids_for(InfoType type) {
                return effects
                    .filter!(x => (x.type & type) > 0).map!(x => x.data);
            }

            auto get_effect_values_for(InfoType type) {
                return effects
                    .filter!(x => (x.type & type) > 0).map!(x => x.value);
            }

            auto get_source_ids_for(InfoType type) {
                return sources
                    .filter!(x => (x.type & type) > 0).map!(x => x.data);
            }

            auto get_source_values_for(InfoType type) {
                return sources
                    .filter!(x => (x.type & type) > 0).map!(x => x.value);
            }

            auto get_effect_reg_ids() {
                return get_effect_ids_for(InfoType.Register);
            }

            auto get_effect_reg_values() {
                return get_effect_values_for(InfoType.Register);
            }

            auto get_effect_mem_addrs() {
                return get_effect_ids_for(InfoType.Memory);
            }

            auto get_effect_mem_values() {
                return get_effect_values_for(InfoType.Memory);
            }
        }
    }

    /// represents a terminal leaf source of information
    struct InfoLeaf {
        /// the information contained at this leaf
        InfoNode node;
        /// the commit where this leaf originated
        long commit_id;

        string toString() const {
            import std.string : format;
            import std.conv : to;
            import std.array : appender, array;

            auto sb = appender!string;

            sb ~= format("InfoLeaf(node: %s, commit_id: %s)", node, commit_id);

            return sb.array;
        }

        bool is_final() const {
            return node.is_final();
        }

        bool is_deterministic() const {
            return node.is_deterministic();
        }
    }

    alias InfoLeafs = InfoLeaf[];

    struct CommitTrace {
        /// the snapshots contained in this trace
        public Snapshot[] snapshots;
        /// the commits contained in this trace
        public Commit[] commits;
    }
}
