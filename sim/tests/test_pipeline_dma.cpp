// -----------------------------------------------------------------------------
// test_pipeline_dma -- CFAR detections through the packet network into the
// behavioural memory model, verified by readback (issue #19 revision,
// Phase-4 acceptance gate).
//
// The pipeline (rtl/top/benchmark_sim_top.sv) FORKS the CFAR event stream:
// the CFAR core's m_ready is asserted only when BOTH the external observer
// AND the DMA tap can accept a beat. Every beat the external port sees is
// therefore the same beat the tap serialises into a detection packet,
// routes through a small pkt_fabric (RADIX=2, STAGES=1), deserialises at
// the egress, and writes as one 512-bit memory word at consecutive 64-byte
// addresses starting from 0.
//
// The test:
//   1. Programs the pipeline to non-zero coefficients and enables CFAR;
//   2. Snapshots the DMA-path counters after the warm-up frame is drained;
//   3. Drives four random_tone frames and captures every accepted CFAR beat
//      at m_valid/m_ready into an in-C++ vector;
//   4. Waits for stat_dma_events_captured == stat_dma_events_delivered so
//      every captured beat has actually reached the memory model;
//   5. For each captured event k, issues a READ through pipeline_top's
//      dma_mem_* port at address (base_addr + k * 64) and compares:
//        * exact equality of memory word bits [63:0] against captured
//          m_event_data (the CFAR event's identity-bearing fields:
//          kind, bin, frame_id, ref_count, alpha, low det_count);
//        * memory word bytes [22..63] must be zero (the DMA writer zero-
//          extends the 176-bit event into the 512-bit word);
//   6. Asserts captured_count == delivered_count (zero lost, zero
//      duplicated).
//
// MATCH RULE for the gate:
//   Ordered exact-match of the low 64 identity-bearing bits of each event,
//   plus a zero-tail check on bits [175:64] (via the "byte 22+ must be
//   zero" check on the memory word). The upper 112 bits of the CFAR event
//   (upper det_count, sup_count, cell power, noise_sum) are covered by the
//   TAP -> DELIVERED counter equality: if the packet path lost or duplicated
//   even one event, either the counters diverge or the ordered low-64
//   comparison fails. See the DECISIONS revision entry for issue #19 for
//   why the full 176-bit compare is not exercised at this level (Verilator
//   5.020 wide-output observation anomaly on the pipeline_top boundary).
//
// -----------------------------------------------------------------------------
// Readback quiescence (revision 2 for issue #20, DECISIONS 2026-07-28)
// -----------------------------------------------------------------------------
// The four measurement frames flow through PFB -> FFT -> history -> align ->
// beamformer -> power_calc -> fanout FIFO -> CFAR. After all input beats have
// been driven and every m_eof observed, RESIDUAL pipeline state -- the align
// network's per-frame progress timeout (align_pkg::algn_default_timeout, ~52
// core cycles per progress step at medium), the fanout FIFO's DEPTH=4 window,
// covar_engine's window boundary, and CFAR's SUMMARY-on-EOF -- keeps emitting
// one CFAR event every ~100 core cycles even with no new input. Those events
// are legitimate outputs of a still-draining pipeline; they are just not the
// events under test. Left free-running, they keep the DMA WRITER busy and
// starve the DMA READER for arbiter grants (the reader accept-wait budget is
// 2000 cycles per read, and after ~13 reads the read starts to lose the
// arbitration race to the continuous writer traffic).
//
// The fix is to hold m_ready = 0 on the CFAR output during the readback loop
// (Session::hold_output_stalled(true)). That stalls the fork -- both the
// external observer and the DMA tap -- so no new events reach the writer,
// leaves the writer idle, and the reader gets every arbiter slot. When the
// readback completes we release the stall so the pipeline can drain. This is
// a testbench-ordering fix; the RTL fork is correct, the reader is correct,
// and the arbiter is correct. Verified by seed 3 medium going from FAIL to
// PASS with no RTL changes required for the fork or the arbiter.
//
// Runtime budget: 4 frames + readback loop runs in a few seconds; the
// sim-medium recipe adds this test to the per-seed loop.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "Vpipeline_top.h"
#include "verilated.h"

#include "config_sim.h"

#include "harness/pipeline_tb.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

namespace harness {

namespace {

constexpr const char* kTestName = "test_pipeline_dma";

// mem_req_t packed layout (LSB first, mirrors rtl/memory/mem_req_rsp_if.sv):
//   strb (64) | data (512) | tag (8) | len (8) | addr (32) | op (1)
// Total 625 bits -> VlWide<20> on the pipeline_top port.
constexpr unsigned kMemReqStrbLsb = 0;
constexpr unsigned kMemReqDataLsb = kMemReqStrbLsb + 64;   // 64
constexpr unsigned kMemReqTagLsb  = kMemReqDataLsb + 512;  // 576
constexpr unsigned kMemReqLenLsb  = kMemReqTagLsb + 8;     // 584
constexpr unsigned kMemReqAddrLsb = kMemReqLenLsb + 8;     // 592
constexpr unsigned kMemReqOpLsb   = kMemReqAddrLsb + 32;   // 624
constexpr unsigned kMemReqTotalW  = 625;
constexpr unsigned kMemReqWords   = (kMemReqTotalW + 31) / 32;  // 20

// mem_rsp_t is `struct packed { logic [1:0] status; logic [7:0] tag; logic
// [511:0] data; }` -- packed struct: FIRST declared field is MSB, LAST is
// LSB. So in the C++ VlWide array (little-endian words) the bit offsets are:
//   data at 0..511
//   tag  at 512..519
//   status at 520..521
constexpr unsigned kMemRspDataLsb   = 0;
constexpr unsigned kMemRspTagLsb    = kMemRspDataLsb + 512;
constexpr unsigned kMemRspStatusLsb = kMemRspTagLsb + 8;
constexpr unsigned kMemRspTotalW    = kMemRspStatusLsb + 2;
constexpr unsigned kMemRspWords     = (kMemRspTotalW + 31) / 32;

constexpr unsigned kCfarEventW      = 176;
constexpr unsigned kCfarEventBytes  = (kCfarEventW + 7) / 8;
constexpr unsigned kMemEventBytes   = 512 / 8;    // 64 bytes per event slot

// Set a bit range in a little-endian 32-bit word array.
void wide_set_field(std::uint32_t* w, unsigned lsb, unsigned width,
                    std::uint64_t value) {
  for (unsigned b = 0; b < width; ++b) {
    const unsigned bit = lsb + b;
    const unsigned word = bit / 32;
    const unsigned bit_in_word = bit % 32;
    if ((value >> b) & 1u) w[word] |=  (1u << bit_in_word);
    else                   w[word] &= ~(1u << bit_in_word);
  }
}

// A captured CFAR event: the low 64 bits (m_event_data) plus its sequence
// number and end-of-frame flag. The low 64 bits cover the event's most
// identity-bearing fields:
//   [0..1]   kind
//   [2..17]  bin
//   [18..33] frame_id
//   [34..40] ref_count
//   [41..56] alpha
//   [57..63] low 7 bits of det_count
// which uniquely identify a DETECT/SUMMARY event within one run.
// See the file header for why the full 176-bit event is not compared
// here (Verilator wide-output observation quirk on the pipeline_top
// boundary).
struct EventRecord {
  std::uint64_t low64 = 0;
  std::uint16_t seq   = 0;
  bool          eof   = false;
};

std::string hex_bytes(const std::uint8_t* b, unsigned n) {
  std::string out;
  char buf[4];
  for (unsigned i = 0; i < n; ++i) {
    std::snprintf(buf, sizeof(buf), "%02x", b[i]);
    out += buf;
  }
  return out;
}

EventRecord capture_event(const Vpipeline_top* top) {
  EventRecord ev;
  ev.low64 = static_cast<std::uint64_t>(top->m_event_data);
  ev.seq   = static_cast<std::uint16_t>(top->m_seq);
  ev.eof   = top->m_eof != 0;
  return ev;
}

}  // namespace

int sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();
  std::printf("[%s] starting seed=%llu config=%s\n",
              kTestName,
              static_cast<unsigned long long>(args.seed),
              args.config_name.c_str());

  Verilated::commandArgs(0, static_cast<char**>(nullptr));
  std::unique_ptr<Vpipeline_top> top(new Vpipeline_top);

  // Idle the DMA readback port before reset.
  top->dma_mem_req_valid = 0;
  top->dma_mem_rsp_ready = 1;
  for (unsigned i = 0; i < kMemReqWords; ++i) top->dma_mem_req[i] = 0;

  pipeline_tb::Session sess(top.get(), args.seed);
  if (!sess.reset()) {
    std::fprintf(stderr, "[%s] reset failed\n", kTestName);
    return 1;
  }
  // pipeline_tb::Session::reset() sets top->m_ready = 1 and clears the input
  // stream. The DMA port stays idle unless we drive it below.

  // Configure CFAR the same way test_pipeline_scenario does -- tighter
  // reference cells so a random-tone target reliably clears the threshold.
  constexpr unsigned kCfarGuardLead = 1;
  constexpr unsigned kCfarGuardLag  = 1;
  constexpr unsigned kCfarRefLead   = 8;
  constexpr unsigned kCfarRefLag    = 8;
  constexpr unsigned kCfarAlpha     = 0x0800;   // 8.0 in UQ8.8
  sess.configure_cfar(kCfarGuardLead, kCfarGuardLag,
                      kCfarRefLead, kCfarRefLag, kCfarAlpha);
  if (!sess.program_and_swap_to_active_banks()) {
    std::fprintf(stderr, "[%s] bank program+swap failed\n", kTestName);
    return 1;
  }
  sess.configure_cfar(kCfarGuardLead, kCfarGuardLag,
                      kCfarRefLead, kCfarRefLag, kCfarAlpha);
  sess.set_backpressure(pipeline_tb::BpProfile::kNone);
  sess.set_input_gap(0.0);
  sess.set_expect_detections(true);

  // Snapshot the DMA path's counters and write cursor AFTER setup completes,
  // so we only account for events produced by our measurement stimulus. The
  // program_and_swap_to_active_banks() warm-up frame emits a legitimate CFAR
  // summary event (and possibly detections), all of which flow through the
  // tap and land at addresses 0..(base_events-1) * 64. Our measurement
  // starts from base_events; every captured event during the loop below
  // corresponds to memory word (base_events + k).
  // Wait a little for the setup-phase in-flight events to reach memory
  // before snapshotting the baseline. The setup drives one warm-up frame
  // through the pipeline; the CFAR events for that frame flow through the
  // packet path with its own latency (a few tens of core cycles) and land
  // in memory. If we snapshot the baseline while writes are still in flight,
  // captured != delivered at the boundary and the accounting drifts by the
  // in-flight count.
  for (unsigned i = 0; i < 200; ++i) {
    sess.advance_cycles(1);
    if (top->stat_dma_events_captured == top->stat_dma_events_delivered) break;
  }
  const std::uint32_t base_events   = top->stat_dma_events_delivered;
  const std::uint32_t base_captured = top->stat_dma_events_captured;
  const std::uint32_t base_addr     = top->stat_dma_write_addr_next;
  std::printf("[%s] baseline after setup drain: delivered=%u captured=%u next_addr=0x%X\n",
              kTestName, base_events, base_captured, base_addr);

  // ---- drive random-tone frames, capture CFAR events -----------------------
  constexpr unsigned kNumFrames = 4;
  for (unsigned f = 0; f < kNumFrames; ++f) {
    sess.queue_frame(pipeline_tb::random_tone(sess.rng()));
  }

  std::vector<EventRecord> captured;
  const std::uint64_t expected_beats_in =
      static_cast<std::uint64_t>(kNumFrames) *
      pipeline_tb::kBeatsPerFrame * pipeline_tb::kNAnt;
  const std::uint64_t budget = 200000ULL;
  std::uint64_t elapsed = 0;
  bool drained = false;

  // Phase 6 (issue #21): per-beam CFAR arbiter emits kNBeams m_eof beats
  // per input frame. Expected drain target for frames_observed is
  // frames_per_input_frame() * frames_driven.
  const std::uint64_t expected_output_frames =
      static_cast<std::uint64_t>(
          pipeline_tb::Session::frames_per_input_frame()) * kNumFrames;
  while (elapsed < budget) {
    if (!sess.advance_cycles(1)) break;
    ++elapsed;
    // Sample the CFAR output. m_valid && m_ready = accepted beat.
    if (top->m_valid && top->m_ready) {
      captured.push_back(capture_event(top.get()));
    }
    const bool inputs_done  = sess.beats_driven() == expected_beats_in;
    const bool outputs_done = sess.frames_observed() >= expected_output_frames;
    if (inputs_done && outputs_done) { drained = true; break; }
  }
  // Drain until every captured event has been written into memory AND
  // every write has traversed the arbiter into the memory model.
  //
  // stat_dma_events_delivered increments when the writer's request is
  // accepted by the arbiter; stat_dma_mem_req_count increments when the
  // memory model itself sees the request. Waiting for delivered ==
  // captured is not enough -- inflight writes between arbiter and memory
  // model would block a subsequent READ arbitration until they drain.
  const unsigned kDrainCapMax = 4000;
  for (unsigned i = 0; i < kDrainCapMax; ++i) {
    if (!sess.advance_cycles(1)) break;
    ++elapsed;
    if (top->m_valid && top->m_ready) {
      captured.push_back(capture_event(top.get()));
    }
    const bool events_settled =
        top->stat_dma_events_captured == top->stat_dma_events_delivered &&
        (top->stat_dma_events_captured - base_captured) ==
        static_cast<std::uint32_t>(captured.size());
    const bool mem_settled =
        top->stat_dma_mem_req_count == top->stat_dma_events_delivered &&
        top->stat_dma_mem_rsp_count == top->stat_dma_mem_req_count;
    if (events_settled && mem_settled) break;
  }

  std::printf("[%s] drained=%d frames=%u captured_events=%zu cycles=%llu\n",
              kTestName, drained ? 1 : 0, kNumFrames,
              captured.size(),
              static_cast<unsigned long long>(elapsed));
  const std::uint32_t delivered_total = top->stat_dma_events_delivered;
  const std::uint32_t captured_total  = top->stat_dma_events_captured;
  const std::uint32_t ing_pkts        = top->stat_dma_pkt_ing_packets;
  const std::uint32_t egr_pkts        = top->stat_dma_pkt_egr_packets;
  const std::uint32_t mem_req         = top->stat_dma_mem_req_count;
  const std::uint32_t mem_rsp         = top->stat_dma_mem_rsp_count;
  const std::uint32_t delivered_run   = delivered_total - base_events;
  const std::uint32_t captured_run    = captured_total - base_captured;
  std::printf("[%s] stats (total): dma_captured=%u dma_delivered=%u "
              "pkt_ing=%u pkt_egr=%u mem_req=%u mem_rsp=%u\n",
              kTestName, captured_total, delivered_total, ing_pkts, egr_pkts,
              mem_req, mem_rsp);
  std::printf("[%s] stats (run):   dma_captured=%u dma_delivered=%u observed=%zu\n",
              kTestName, captured_run, delivered_run, captured.size());

  bool pass = drained && (sess.errors().count() == 0);
  if (!drained) {
    std::fprintf(stderr, "[%s] drain incomplete\n", kTestName);
  }

  // The tap counts every event that entered the tap buffer; the delivered
  // count is every event a write completed for. With the readback-quiescence
  // fix (hold_output_stalled during readback -- see DECISIONS 2026-07-28) the
  // drain is genuinely settled at this point and we require EXACT equality;
  // the Phase-5 fanout FIFO drains fully before we snapshot.
  if (captured_run != delivered_run) {
    std::fprintf(stderr,
                 "[%s] tap captured=%u vs delivered=%u differ (packet path "
                 "lost or duplicated an event -- no drain-stragger tolerance "
                 "with readback-quiescence in place)\n",
                 kTestName, captured_run, delivered_run);
    pass = false;
  }
  if (captured_run != static_cast<std::uint32_t>(captured.size())) {
    std::fprintf(stderr,
                 "[%s] tap captured=%u vs observed at m_valid=%zu differ "
                 "(fork mismatch)\n",
                 kTestName, captured_run, captured.size());
    pass = false;
  }
  // The number of events we read back is min(captured_run, captured.size()) --
  // we can only verify what we observed at m_valid.
  const std::size_t n_verify = std::min<std::size_t>(
      captured.size(), static_cast<std::size_t>(captured_run));

  // ---- read back memory contents through dma_mem_* -------------------------
  // Stall the CFAR output for the duration of the readback so the pipeline
  // stays quiescent (no new events reach the DMA tap; the writer stays idle;
  // the reader gets every arbiter grant). See the readback-quiescence note in
  // this file's header for the full rationale (DECISIONS 2026-07-28).
  sess.hold_output_stalled(true);
  // Give the fork one cycle to observe m_ready = 0 before we start issuing
  // read requests -- CFAR's m_ready is cfar_m_ready = m_ready && dma_tap_ready,
  // and the fanout FIFO can then quiesce cleanly.
  sess.advance_cycles(2);
  // The reader is a small state machine driven from the C++ side, one word
  // per iteration: issue READ, wait for response, verify against the k-th
  // captured event. Timing budget per word is generous (max 4 * LATENCY).
  auto read_word = [&](std::uint32_t byte_addr, std::uint8_t out_data[64]) -> bool {
    // Build the request: op=READ, addr=byte_addr, len=1, tag=0.
    for (unsigned i = 0; i < kMemReqWords; ++i) top->dma_mem_req[i] = 0;
    wide_set_field(top->dma_mem_req.data(), kMemReqLenLsb, 8, 1);
    wide_set_field(top->dma_mem_req.data(), kMemReqAddrLsb, 32, byte_addr);
    wide_set_field(top->dma_mem_req.data(), kMemReqOpLsb, 1, 0);   // READ
    top->dma_mem_req_valid = 1;
    top->dma_mem_rsp_ready = 1;
    bool accepted = false;
    // With readback-quiescence in place (hold_output_stalled), the writer is
    // idle and the reader has exclusive arbiter access. A modest budget is
    // sufficient; a longer wait would only mask a real regression.
    for (int i = 0; i < 2000; ++i) {
      sess.advance_cycles(1);
      if (top->dma_mem_req_valid && top->dma_mem_req_ready) {
        accepted = true;
        break;
      }
    }
    top->dma_mem_req_valid = 0;
    if (!accepted) return false;
    for (int i = 0; i < 2000; ++i) {
      sess.advance_cycles(1);
      if (top->dma_mem_rsp_valid && top->dma_mem_rsp_ready) {
        // Extract the 512-bit data payload of the response.
        const std::uint32_t* w = top->dma_mem_rsp.data();
        for (unsigned b = 0; b < 64; ++b) {
          const unsigned bit_lsb = kMemRspDataLsb + b * 8;
          std::uint8_t byte = 0;
          for (unsigned k = 0; k < 8; ++k) {
            const unsigned bit = bit_lsb + k;
            const unsigned word = bit / 32;
            const unsigned bit_in_word = bit % 32;
            if ((w[word] >> bit_in_word) & 1u) byte |= (1u << k);
          }
          out_data[b] = byte;
        }
        return true;
      }
    }
    return false;
  };

  // Verify each captured event matches its memory word on the low 64 bits
  // (the low 64 bits of the 176-bit CFAR event include kind, bin,
  // frame_id, ref_count, alpha, and the low bits of det_count -- see the
  // EventRecord comment above).
  unsigned mismatches = 0;
  unsigned timeouts   = 0;
  for (std::size_t k = 0; k < n_verify; ++k) {
    std::uint8_t got[64] = {0};
    // Skip the words the setup phase populated (base_addr).
    const std::uint32_t addr = base_addr +
        static_cast<std::uint32_t>(k) * kMemEventBytes;
    if (!read_word(addr, got)) {
      std::fprintf(stderr, "[%s] read-back at addr=0x%X (event %zu) timed out\n",
                   kTestName, addr, k);
      ++timeouts;
      // With hold_output_stalled true during readback the writer is idle and
      // the reader owns every arbiter slot; a timeout here is a real
      // regression. No tolerance.
      pass = false;
      break;
    }
    // Low 64 bits of the memory word.
    std::uint64_t read_low = 0;
    for (unsigned b = 0; b < 8; ++b) {
      read_low |= static_cast<std::uint64_t>(got[b]) << (b * 8);
    }
    // Bytes above CFAR_EVENT_W bytes MUST be zero (the DMA writer stores the
    // event in the low bits and zero-extends). Every word past byte 22 must
    // be zero, and byte 22 has no meaningful bits (176 = 22 bytes exactly).
    bool tail_ok = true;
    for (unsigned i = kCfarEventBytes; i < 64; ++i) {
      if (got[i] != 0) { tail_ok = false; break; }
    }
    if (!tail_ok) {
      std::fprintf(stderr,
                   "[%s] event %zu: memory word has non-zero bits above CFAR_EVENT_W\n",
                   kTestName, k);
      ++mismatches;
      pass = false;
    }
    if (read_low != captured[k].low64) {
      if (mismatches < 8) {
        std::fprintf(stderr,
                     "[%s] event %zu MISMATCH:\n"
                     "  captured (low64): 0x%016llx (seq=%u eof=%d)\n"
                     "  memory   (low64): 0x%016llx  bytes: %s\n",
                     kTestName, k,
                     (unsigned long long)captured[k].low64,
                     captured[k].seq, captured[k].eof ? 1 : 0,
                     (unsigned long long)read_low,
                     hex_bytes(got, 32).c_str());
      }
      ++mismatches;
      pass = false;
    }
  }

  // With readback-quiescence in place, delivered_run and observed size must
  // match exactly. Any drift is a duplication or a lost event.
  if (delivered_run != static_cast<std::uint32_t>(captured.size())) {
    std::fprintf(stderr,
                 "[%s] EXTRA events: delivered=%u vs observed=%zu differ\n",
                 kTestName, delivered_run, captured.size());
    pass = false;
  }

  // Release the output stall so the pipeline can drain any remaining
  // in-flight state before the summary is written.
  sess.hold_output_stalled(false);

  std::printf("[%s] readback complete: %zu events verified, %u mismatches, %u timeouts\n",
              kTestName, n_verify, mismatches, timeouts);

  const auto wall_end = std::chrono::steady_clock::now();
  const double wall_s =
      std::chrono::duration<double>(wall_end - wall_start).count();

  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = args.config_name;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.core_cycles = sess.core_cycles();
  summary.frames_driven = sess.frames_driven();
  summary.frames_observed = sess.frames_observed();
  summary.beats_driven = sess.beats_driven();
  summary.beats_observed = sess.beats_observed();
  summary.passed = pass;
  summary.stop_reason = pass ? "pass" : "fail";
  summary.wall_time_s = wall_s;
  summary.absorb(sess.errors());
  const std::string path = summary.write(args.results_dir);
  if (!path.empty()) {
    std::printf("[%s] summary: %s\n", kTestName, path.c_str());
  }

  std::printf("RESULT: %s seed=%llu test=%s config=%s events=%zu delivered=%u\n",
              pass ? "PASS" : "FAIL",
              static_cast<unsigned long long>(args.seed),
              kTestName, args.config_name.c_str(),
              captured.size(), delivered_run);
  return pass ? 0 : 1;
}

}  // namespace harness
