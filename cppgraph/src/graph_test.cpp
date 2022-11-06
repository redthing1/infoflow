#include "ift.h"

#include <iostream>

// typedef RiscvIFTAnalysisGraph = IFTAnalysisGraph<uint64_t, byte, GenericRegSet>;

GenericIFTCompactGraph ift_cppgraph_test_1(const GenericIFTCompactGraph input_graph) {
  GenericIFTCompactGraph graph = input_graph;

  std::cout << "size of graph node: " << sizeof(GenericIFTGraphNode) << std::endl;
  std::cout << "size of graph edge: " << sizeof(GenericIFTGraphEdge) << std::endl;

  std::cout << "hello from C++ :: ift_cppgraph_test_1" << std::endl;
  // print some info about the graph
  std::cout << "graph summary: " << std::endl;
  std::cout << "  nodes: " << graph.num_nodes << std::endl;
  std::cout << "  edges: " << graph.num_edges << std::endl;

  // // inspect the first node
  // std::cout << "first node: " << graph.nodes[0].info_view.node.to_string() << std::endl;
  
  // list the nodes
  std::cout << "nodes: " << std::endl;
  // for (uint64_t i = 0; i < graph.num_nodes; i++) {
  for (uint64_t i = 0; i < 1; i++) {
    // std::cout << "  " << graph.nodes[i].info_view.to_string() << std::endl;
    // std::cout << " #" << i << ": " << graph.nodes[i]->to_string() << std::endl;
    std::cout << " #" << i << ": " << graph.nodes[i]->to_string() << " (" << graph.nodes[i] << ")" << std::endl;
    // std::cout << "  commit_id: " << graph.nodes[i]->info_view.commit_id << std::endl;
    // hex dump the node
    std::cout << "  hex: ";
    for (uint64_t j = 0; j < sizeof(GenericIFTGraphNode); j++) {
      // std::cout << std::hex << (int)((uint8_t*)graph.nodes[i])[j] << " ";
      printf("%02x ", (int)((uint8_t*)graph.nodes[i])[j]);
    }
    std::cout << std::endl;
  }

  // // list the edges
  // std::cout << "edges: " << std::endl;
  // for (uint64_t i = 0; i < graph.num_edges; i++) {
  //   // std::cout << " #" << i << ": " << graph.edges[i].to_string() << std::endl;

  //   std::cout << graph.edges[i].src->to_string() << " (" << graph.edges[i].src << ") -> ";
  //   std::cout << graph.edges[i].dst->to_string() << " (" << graph.edges[i].dst << ")" << std::endl;
  // }

  return graph;
}

int cpp_add(int a, int b) {
  return a + b;
}