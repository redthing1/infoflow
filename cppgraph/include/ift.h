#pragma once

#include <stdint.h>

// #define TRegWord uint64_t

enum InfoType {
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
  };

  struct InfoView {
    InfoNode node;
    long commit_id;
  };
};

IFT_TEMPLATE class IFTAnalysisGraph {
public:
  struct IFTGraphNode {
    typename InfoLog<TRegWord, TMemWord, TRegSet>::InfoView info_view;
    IFTGraphNodeFlags flags = IFTGraphNodeFlags::IFTGraphNodeFlags_None;
  };

  struct IFTGraphEdge {
    IFTGraphNode src;
    IFTGraphNode dst;
  };

  struct CompactGraph {
    uint64_t num_nodes;
    IFTGraphNode *nodes;
    uint64_t num_edges;
    IFTGraphEdge *edges;
  };
};

enum GenericRegSet {
  GENERIC_UNKNOWN,
};

// alias it to a shorter name
// using GenericIFTCompactGraph =
//     IFTAnalysisGraph<uint64_t, int8_t, GenericRegSet>::IFTCompactGraph;
using GenericIFTCompactGraph =
    IFTAnalysisGraph<unsigned long, signed char, GenericRegSet>::CompactGraph;