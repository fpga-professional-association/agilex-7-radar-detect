// -----------------------------------------------------------------------------
// files_packet.f — RTL file list for the packet-network build (issue #18).
//
// A self-contained file list, for the reason every other secondary list in this
// directory is self-contained: a failure in this build is then unambiguously a
// failure of the SPEC 7.8 fabric — the packet format, the ingress adapter, the
// switch stage, the butterfly wiring or the egress reassembly — and not of the
// stream fabric, the register plane, the FFT, the polyphase bank, the covariance
// engine or the detector, none of whose datapaths appear here.
//
// Used by:
//   scripts/build_verilator.py --top packet_top --files sim/verilator/files_packet.f
// which `make lint` and `make sim-tiny` invoke. Paths are repo-relative; order
// matters (packages first, then the primitives the RTL instantiates, then the
// DUT modules bottom-up, then the top).
//
// The generated config_pkg.sv IS listed: PACKET_W is a SPEC 11 sized parameter
// and N_VIRTUAL_CHANS a SPEC 3 invariant, and sim/verilator/tops/packet_top.sv
// checks both against packet_pkg at elaboration. The packet FORMAT does not come
// from the configuration — every header field width is a constant of
// rtl/packages/packet_pkg.sv — which is the property that lets one decoder read
// a captured packet from any SPEC 11 size.
//
// cfar_pkg (and covar_pkg and fxp_pkg beneath it) are here because packet_pkg
// states the detection-event payload width BY REFERENCE to cfar_pkg rather than
// by copy: a detection event is the network's primary payload, and its flit
// count must move when cfar_pkg's event layout moves. No CFAR datapath is in
// this build.
//
// rtl/packet/*.sv and rtl/packages/packet_pkg.sv are ALSO in files.f: they are
// design RTL, and files.f is the single definition of what "the design" is. This
// list adds only the simulation-only top.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ----------------------
+incdir+sim/assertions

// ---- generated configuration package -----------------------------------
// Written by scripts/build_verilator.py from config/<name>.json before every
// build. Not committed (see .gitignore).
sim/verilator/generated/config_pkg.sv

// ---- shared packages ---------------------------------------------------
rtl/packages/fxp_pkg.sv
rtl/packages/covar_pkg.sv
rtl/packages/cfar_pkg.sv
rtl/packages/packet_pkg.sv

// ---- SPEC 14 property set used by the primitives the fabric is built on --
// perf_counter instantiates telemetry_assertions directly under `ifndef
// SYNTHESIS, so the checker must precede it.
sim/assertions/telemetry_assertions.sv

// ---- shared primitives (issues #6 and #8) ------------------------------
rtl/common/perf_counter.sv
rtl/common/sync_fifo.sv

// ---- the fabric (SPEC 7.8, SPEC 19 Phase 4) ----------------------------
rtl/packet/pkt_rr_arb.sv
rtl/packet/pkt_ingress.sv
rtl/packet/pkt_switch_stage.sv
rtl/packet/pkt_egress.sv
rtl/packet/pkt_fabric.sv

// ---- SPEC 18 calibration wrappers --------------------------------------
// Listed here so `make lint` covers them. RTL that no lint ever sees is RTL
// that rots, and the Quartus calibration projects depend on these files. They
// are synthesis wrappers only: no simulation instantiates them.
quartus/calibration/pkt_switch_wrap.sv
quartus/calibration/pkt_slice_core.sv
quartus/calibration/pkt_slice_wrap.sv

// ---- verification top --------------------------------------------------
sim/verilator/tops/packet_top.sv
