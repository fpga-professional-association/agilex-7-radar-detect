// -----------------------------------------------------------------------------
// iq_loader.h -- read an ``iq_ascii_v1`` scenario file and convert it into
// the pipeline_tb Session's per-frame stimulus format (issue #44 part 2).
//
// The generator (``model/python/gen_target_iq.py``) writes a scenario file
// with a ``# key: value`` header block and one whitespace-separated line per
// (frame, antenna, beat):
//
//     frame ant beat sof eof s0_re s0_im s1_re s1_im ...
//
// with ``SAMPLES_PER_CYCLE`` complex Q1.15 sample pairs per line. See
// ``gen_target_iq.render_iq`` and ``range_doppler.load_iq`` for the reference
// parsers -- this header is the C++ counterpart, so the sim test can consume
// the exact file the visualiser sees. The loader also parses the matching
// ``scenario.json`` sidecar so the ground-truth targets and their bin/beam/
// angle indices are available to the test.
//
// Sizes are validated against the medium-config constants baked into
// ``pipeline_tb.h`` (``kNAnt = 4``, ``kSpc = 2``, ``kFftSize = 256``,
// history = 16 by convention -- see ``load_scenario`` documentation).
// A mismatch fails the load rather than silently truncating.
// -----------------------------------------------------------------------------
#ifndef HARNESS_IQ_LOADER_H_
#define HARNESS_IQ_LOADER_H_

#include <cstdint>
#include <string>
#include <vector>

#include "pipeline_tb.h"

namespace pipeline_tb {

struct ScenarioTarget {
  std::string name;
  int         range_bin   = 0;  // fast-time FFT bin, 0..FFT_SIZE-1
  int         doppler_bin = 0;  // slow-time bin, 0..HISTORY_FRAMES-1
  int         angle_idx   = 0;  // per-antenna spatial index, 0..N_ANTENNAS-1
  double      snr_db      = 0.0;
};

struct ScenarioMeta {
  // Parsed IQ header fields, cross-checked at load time. Any mismatch with
  // the compiled-in medium-config sizes is a hard error -- a partial load is
  // never useful and would silently distort the test's arithmetic.
  std::string name;
  std::uint64_t seed = 0;
  unsigned n_antennas       = 0;
  unsigned samples_per_cycle = 0;
  unsigned fft_size         = 0;
  unsigned history_frames   = 0;
  unsigned sample_w         = 0;
  double  noise_sigma       = 0.0;
  double  target_amp        = 0.03;
  std::vector<ScenarioTarget> targets;
};

// Parse an ``iq_ascii_v1`` file. Fills ``frames`` in frame order (index 0 is
// frame 0, etc.). Returns false and writes a diagnostic to stderr on any
// framing / size mismatch or an unreadable file. Populates ``meta`` from the
// header block; on success ``frames.size() == meta.history_frames``.
bool load_iq_file(const std::string& path,
                  ScenarioMeta& meta,
                  std::vector<StimFrame>& frames);

// Parse the JSON ground-truth sidecar written by ``gen_target_iq``. Only the
// fields the test uses are extracted; the parser is deliberately minimal
// (no dependency on nlohmann/json) because the file layout is fixed by
// ``render_json`` and this loader owns the same schema by construction.
bool load_scenario_json(const std::string& path, ScenarioMeta& meta);

// Convenience: given the base directory of a generated scenario, load both
// ``scenario.iq`` and ``scenario.json``. The IQ header keys and JSON keys
// have to agree; a mismatch is a load error.
bool load_scenario(const std::string& base_dir,
                   ScenarioMeta& meta,
                   std::vector<StimFrame>& frames);

// Given a scene FFT bin and the pipeline's BIN_PAR, return the CFAR bin
// index the pipeline's tap will observe for the tapped parity (lane 0).
// For BIN_PAR = 2 this is fft_bin / 2 for even fft_bin. If fft_bin is on
// the untapped parity, returns -1 (the target is invisible to the tap).
int cfar_bin_for_fft_bin(int fft_bin, unsigned bin_par);

}  // namespace pipeline_tb

#endif  // HARNESS_IQ_LOADER_H_
