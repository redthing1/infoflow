#include "ift.h"

#include <iostream>

IFTCompactGraph ift_cppgraph_test_1(const IFTCompactGraph input_graph) {
  IFTCompactGraph graph = input_graph;

  // print some info about the graph
  std::cout << "graph summary: " << std::endl;
  std::cout << "  nodes: " << graph.num_nodes << std::endl;
  std::cout << "  edges: " << graph.num_edges << std::endl;

  return graph;
}
