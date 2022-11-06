#pragma once

#include <stdint.h>
#include <string>
#include <sstream>
#include <ios>
#include <iomanip>

// #define TRegWord uint64_t

enum InfoType : uint32_t {
  InfoType_Unknown = 0x0,
  InfoType_None = 0x1,
  InfoType_Register = 1 << 2,  // an abstract register
  InfoType_Memory = 1 << 3,    // an abstract memory cell
  InfoType_Immediate = 1 << 4, // an immediate value
  InfoType_Combined = InfoType_Register | InfoType_Memory | InfoType_Immediate,
  InfoType_Device = 1 << 6,                          // a device value
  InfoType_CSR = (1 << 7),                           // a csr
  InfoType_MMIO = InfoType_Memory | InfoType_Device, // a mmio value
  InfoType_DeterminateValue =
      1 << 8, // a value that is always the same within a given trace
  InfoType_DeterminateRegister = InfoType_Register | InfoType_DeterminateValue,
  InfoType_DeterminateMemory = InfoType_Memory | InfoType_DeterminateValue,
  InfoType_DeterminateCSR = InfoType_CSR | InfoType_DeterminateValue,
  InfoType_Indeterminate = 1 << 9,
  InfoType_IndeterminateRegister = InfoType_Register | InfoType_Indeterminate,
  InfoType_IndeterminateMemory = InfoType_Memory | InfoType_Indeterminate,
  InfoType_Reserved2,
  InfoType_Reserved3,
  InfoType_Reserved4,
};

// struct InfoNode {
//   InfoType type;
//   TRegWord data;
//   TRegWord value;
// };

// struct InfoView {
//   InfoNode node;
//   long commit_id;
// };

enum IFTGraphNodeFlags {
  IFTGraphNodeFlags_None = 0x0,
  IFTGraphNodeFlags_Final = 1 << 0,
  IFTGraphNodeFlags_Nondeterministic = 1 << 1,
  IFTGraphNodeFlags_Inner = 1 << 2,
  IFTGraphNodeFlags_Propagated = 1 << 3,
  IFTGraphNodeFlags_Reserved3 = 1 << 4,
  IFTGraphNodeFlags_Reserved4 = 1 << 5,
  IFTGraphNodeFlags_Reserved5 = 1 << 6,
  IFTGraphNodeFlags_Reserved6 = 1 << 7,
  IFTGraphNodeFlags_Reserved7 = 1 << 8,
};

// struct IFTGraphNode {
//   InfoView info_view;
//   IFTGraphNodeFlags flags = IFTGraphNodeFlags::IFTGraphNodeFlags_None;
// };

// struct IFTGraphEdge {
//   IFTGraphNode src;
//   IFTGraphNode dst;
// };

// struct IFTCompactGraph {
//   uint64_t num_nodes;
//   IFTGraphNode *nodes;
//   uint64_t num_edges;
//   IFTGraphEdge *edges;
// };

#define IFT_TEMPLATE                                                           \
  template <typename TRegWord, typename TMemWord, typename TRegSet>

IFT_TEMPLATE class InfoLog {
public:
  struct InfoNode {
    InfoType type;
    TRegWord data;
    TRegWord value;

    public:
      std::string to_string() const {
        std::stringstream ss;
        ss << "InfoNode(";
        ss << "type=" << type << ", ";
        ss << "data=" << "0x" << std::hex << std::setfill('0') << std::setw(16) << data << ", ";
        ss << "value=" << "0x" << std::hex << std::setfill('0') << std::setw(16) << value;
        ss << ")";
        return ss.str();
      }
  };

  struct InfoView {
    InfoNode node;
    long commit_id;

    public:
      std::string to_string() const {
        std::stringstream ss;
        ss << "InfoView(";
        ss << "node=" << node.to_string() << ", ";
        ss << "commit_id=" << commit_id;
        ss << ")";
        return ss.str();
      }
  };
};

IFT_TEMPLATE class IFTAnalysisGraph {
public:
  struct IFTGraphNode {
    typename InfoLog<TRegWord, TMemWord, TRegSet>::InfoView info_view;
    IFTGraphNodeFlags flags = IFTGraphNodeFlags::IFTGraphNodeFlags_None;

    public:
      std::string to_string() const {
        std::stringstream ss;
        ss << "IFTGraphNode(";
        ss << "info_view=" << info_view.to_string() << ", ";
        ss << "flags=" << flags;
        ss << ")";
        return ss.str();
      }
  };

  struct IFTGraphEdge {
    IFTGraphNode* src;
    IFTGraphNode* dst;

    public:
      std::string to_string() const {
        std::stringstream ss;
        ss << "IFTGraphEdge(";
        ss << "src=" << src->to_string() << ", ";
        ss << "dst=" << dst->to_string();
        ss << ")";
        return ss.str();
      }
  };

  struct CompactGraph {
    uint64_t num_nodes;
    IFTGraphNode **nodes;
    uint64_t num_edges;
    IFTGraphEdge *edges;
  };
};

enum GenericRegSet {
  GENERIC_UNKNOWN,
};

// alias it to a shorter name
typedef IFTAnalysisGraph<uint64_t, int8_t, GenericRegSet>::CompactGraph GenericIFTCompactGraph;
typedef IFTAnalysisGraph<uint64_t, int8_t, GenericRegSet>::IFTGraphNode GenericIFTGraphNode;
typedef IFTAnalysisGraph<uint64_t, int8_t, GenericRegSet>::IFTGraphEdge GenericIFTGraphEdge;