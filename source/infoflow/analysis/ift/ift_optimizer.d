module infoflow.analysis.ift.ift_optimizer;

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
import infoflow.analysis.ift.ift_trace;
import infoflow.analysis.ift.ift_graph;

template IFTAnalysisOptimizer(TRegWord, TMemWord, TRegSet) {
    alias IFTAnalyzer = IFTAnalysis!(TRegWord, TMemWord, TRegSet).IFTAnalyzer;
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));
    alias IFTGraphNode = IFTAnalysisGraph!(TRegWord, TMemWord, TRegSet).IFTGraphNode;

    final class IFTGraphOptimizer {
        IFTAnalyzer ift;
        alias ift_graph = ift.ift_graph;

        this(IFTAnalyzer ift) {
            this.ift = ift;

            // ensure that graph and graph analysis are enabled
            enforce(ift.enable_ift_graph, "ift analyzer does not have graph enabled");
            enforce(ift.enable_ift_graph_analysis, "ift analyzer does not have graph analysis enabled");
        }
    }
}
