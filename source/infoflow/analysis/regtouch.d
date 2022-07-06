module analyzers.regtouch;

import std.algorithm : map, filter;
import std.range : array;
import std.algorithm.comparison : min, max;
import std.algorithm.sorting: sort;
import std.traits : EnumMembers;

import infoflow.analysis.common;

template RegTouchAnalysis(TRegWord, TMemWord, TRegSet) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    alias TBaseAnalysis = BaseAnalysis!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    private enum REG_IDS = [EnumMembers!TRegSet];

    class RegTouchAnalyzer : TBaseAnalysis.BaseAnalyzer {
        int window_size = 8192;
        int window_slide = 512;

        struct CommitRange {
            long start;
            long end;
        }

        struct RegUsage {
            long commit_last_read;
            long commit_last_write;

            CommitRange[] free_ranges;
        }
        alias RegUsages = RegUsage[TRegSet];

        struct WindowAnalysis {
            CommitRange commit_range;
            RegUsages reg_usages;
        }

        struct RangeStats {
            long n; // number
            float mean; // mean
            float min; // minimum
            float q1; // first quartile
            float median; // median
            float q3; // third quartile
            float max; // maximum

            string toString() const {
                return format("n=%d, mean=%.1f, min=%.1f, q1=%.1f, median=%.1f, q3=%.1f, max=%.1f",
                              n, mean, min, q1, median, q3, max);
            }
        }

        enum AccessType {
            Read = 1 << 0,
            Write = 1 << 1,
            ReadWrite = Read | Write,
        }

        /// one analysis per window
        WindowAnalysis[] window_analyses;
        
        /// the full analysis computed from the window analyses
        WindowAnalysis full_analysis;

        ulong log_analysis_time;

        this(CommitTrace commit_trace, bool parallelized = false) {
            super(commit_trace, parallelized);
        }

        long find_commit_reg_usage(long from_commit, TRegSet reg_id, AccessType access_type, bool search_forward) {
            auto delta = search_forward ? 1 : -1;

            // go through commits until we find one that touches the register
            for (auto i = from_commit; i >= 0 && i < trace.commits.length; i += delta) {
                auto commit = &trace.commits[i];

                if ((access_type & AccessType.Write) > 0) {
                    // when searching for a write, we are looking for the reg to be in the commit effects
                    for (auto j = 0; j < commit.effects.length; j++) {
                        auto effect = &commit.effects[j];
                        if (effect.type & InfoType.Register && effect.data == reg_id) {
                            // we found a write
                            return i;
                        }
                    }
                }
                if ((access_type & AccessType.Read) > 0) {
                    // when searching for a read, we are looking for the reg to be in the commit sources
                    for (auto j = 0; j < commit.sources.length; j++) {
                        auto source = &commit.sources[j];
                        if (source.type & InfoType.Register && source.data == reg_id) {
                            // we found a read
                            return i;
                        }
                    }
                }
            }

            return -1;
        }

        override void analyze() {
            MonoTime tmr_start = MonoTime.currTime;

            analyze_all_windows();

            MonoTime tmr_end = MonoTime.currTime;
            auto elapsed = tmr_end - tmr_start;

            log_analysis_time = elapsed.total!"usecs";
        }

        void analyze_all_windows() {
            auto final_commit_ix = (cast(long) trace.commits.length) - 1;

            // slide window through the commits
            for (long window_start = 0;
                window_start == 0 || window_start < (cast(long) trace.commits.length - window_size);
                window_start += window_slide) {
                long window_end = min(window_start + window_size, trace.commits.length);
                if (window_start >= window_end)
                    break;
                
                auto window_range = CommitRange(window_start, window_end);

                // analyze the window
                auto window_analysis = analyze_window(window_range);

                // save results
                window_analyses ~= window_analysis;

                auto commits_after = trace.commits.length - window_end;
                if (commits_after <= window_slide) {
                    // we are at the end of the trace, so we can't slide anymore
                    break;
                }
            }

            // sort our windows by start
            alias window_comp = (a, b) => a.commit_range.start < b.commit_range.start;
            window_analyses.sort!(window_comp);

            // now that we have all our window analysis, combine them into a single analysis
            // for each register, we want to combine all free ranges
            RegUsages full_usages;

            // for each reg
            foreach (reg_id; REG_IDS) {
                // for each window

                // collect all free ranges for this reg
                CommitRange[] my_free_ranges;
                foreach (window_analysis; window_analyses) {
                    my_free_ranges ~= window_analysis.reg_usages[reg_id].free_ranges;                    
                }

                // combine free ranges, merging overlapping ranges
                // 1. sort
                my_free_ranges.sort!((a, b) => a.start < b.start);
                // 2. merge
                CommitRange[] merged_free_ranges;

                long last_end = 0;
                foreach (free_range; my_free_ranges) {
                    if (free_range.start > last_end) {
                        // we have a gap, so add it
                        merged_free_ranges ~= CommitRange(last_end, free_range.start);
                    }
                    last_end = max(last_end, free_range.end);
                }

                // save the merged free ranges
                full_usages[reg_id] = RegUsage(-1, -1, merged_free_ranges);
            }

            // finally, do one last pass to see if any of the registers are fully unused
            foreach (reg_id; REG_IDS) {
                // writefln("final check for: %s", reg_id);
                // auto reg_last_touch_commit =
                //     find_commit_reg_usage(final_commit_ix, reg_id, AccessType.ReadWrite, false);
                auto reg_last_read =
                    find_commit_reg_usage(final_commit_ix, reg_id, AccessType.Read, false);
                auto reg_last_write =
                    find_commit_reg_usage(final_commit_ix, reg_id, AccessType.Write, false);
                if (reg_last_read == -1 && reg_last_write == -1) {                    
                    // the register is fully unused
                    full_usages[reg_id] = RegUsage(-1, -1, [CommitRange(0, final_commit_ix)]);
                    continue;
                } else if (reg_last_read == -1 && reg_last_write >= 0) {
                    // the register is never read, but it is written to
                    full_usages[reg_id] = RegUsage(-1, reg_last_write, [CommitRange(0, final_commit_ix)]);
                    continue;
                }

                // one more scenario: register is never read after a certain point
                auto last_useful_usage = reg_last_read;
                if (last_useful_usage < final_commit_ix) {
                    auto last_useful_dist = final_commit_ix - last_useful_usage;
                    enum LAST_USEFUL_MIN_DIST = 8;
                    if (last_useful_dist < LAST_USEFUL_MIN_DIST) continue;

                    // there is room between when it's last read and the end of the trace
                    full_usages[reg_id].free_ranges ~= CommitRange(last_useful_usage, final_commit_ix);
                    continue;
                }
            }

            full_analysis = WindowAnalysis(CommitRange(0, final_commit_ix), full_usages);
        }

        WindowAnalysis analyze_window(CommitRange window_range) {
            auto window_start = window_range.start;
            auto window_end = window_range.end;
            auto window_commits = trace.commits[window_start..window_end];

            mixin(LOG_INFO!(`format("analyzing window [%d, %d]", window_start, window_end)`));

            // initialize the reg usage
            RegUsages reg_usage;

            auto REG_IDS = [EnumMembers!TRegSet];
            foreach (reg_id; REG_IDS) {
                reg_usage[reg_id] = RegUsage(-1, -1);
            }

            // go through the window
            for (auto i = 0; i < window_commits.length; i++) {
                auto commit = &window_commits[i];

                // for each reg
                foreach (reg_id; REG_IDS) {
                    bool reg_was_read = false;
                    bool reg_was_written = false;

                    // check if the reg is read (sources)
                    for (auto j = 0; j < commit.sources.length; j++) {
                        auto source = &commit.sources[j];
                        if ((source.type & InfoType.Register) > 0 && source.data == reg_id) {
                            reg_usage[reg_id].commit_last_read = i + window_start;
                            reg_was_read = true;

                            mixin(LOG_TRACE!(
                                    `format(" reg %s read at commit %d", reg_id, i + window_start)`));
                        }
                    }

                    // check if the reg is written (effects)
                    for (auto j = 0; j < commit.effects.length; j++) {
                        auto effect = commit.effects[j];
                        if ((effect.type & InfoType.Register) > 0 && effect.data == reg_id) {
                            reg_usage[reg_id].commit_last_write = i + window_start;
                            reg_was_written = true;

                            mixin(LOG_TRACE!(
                                    `format(" reg %s written at commit %d", reg_id, i + window_start)`));
                        }
                    }

                    // now update our analysis of when the reg is "free"
                    // a register is free in the window between its last read to its last write
                    if (reg_was_written) {
                        // ensure it was read within the window
                        if (reg_usage[reg_id].commit_last_read < window_start)
                            continue;
                        // check the distance between the last read and last write
                        auto read_write_dist = reg_usage[reg_id].commit_last_write - reg_usage[reg_id]
                            .commit_last_read;
                        enum MIN_USEFUL_DIST = 2;
                        if (read_write_dist <= MIN_USEFUL_DIST)
                            continue;

                        // there was a useful write/read distance
                        // add a free range
                        auto free_range = CommitRange(
                            reg_usage[reg_id].commit_last_read + 1,
                            reg_usage[reg_id].commit_last_write - 1);
                        reg_usage[reg_id].free_ranges ~= free_range;

                        // log
                        mixin(LOG_TRACE!(
                                `format("  reg %s free range [%d, %d]", reg_id, free_range.start, free_range.end)`));
                    }
                }
            }

            return WindowAnalysis(window_range, reg_usage);
        }

        RangeStats calculate_range_stats(CommitRange[] ranges) {
            RangeStats stats;
            float length_sum = 0;
            long[] range_lengths;

            if (ranges.length == 0) return stats;

            for (auto i = 0; i < ranges.length; i++) {
                auto range = ranges[i];
                auto length = range.end - range.start;

                length_sum += length;
                range_lengths ~= length;
            }
            // sort the lengths
            range_lengths.sort();

            stats.n = ranges.length;
            stats.mean = cast(float) length_sum / ranges.length;
            stats.median = range_lengths[range_lengths.length / 2];
            stats.min = range_lengths[0];
            stats.max = range_lengths[range_lengths.length - 1];
            stats.q1 = range_lengths[range_lengths.length / 4];
            stats.q3 = range_lengths[range_lengths.length / 4 * 3];

            return stats;
        }

        void dump_analysis() {
            // dump the full analysis
            writefln(" reg usage:");
            foreach (reg_id; REG_IDS) {
                writefln("  reg %s:", reg_id);
                
                // show free ranges
                auto reg_free_ranges = full_analysis.reg_usages[reg_id].free_ranges;
                if (reg_free_ranges.length == 0) continue;

                writefln("   free ranges");
                foreach (free_range; reg_free_ranges) {
                    writefln("    free [%s, %s]", free_range.start, free_range.end);
                }
                
                // calculate some statistics
                auto stats = calculate_range_stats(reg_free_ranges);
                writefln("   stats: %s", stats);
            }
        }

        void dump_summary() {
        }
    }
}
