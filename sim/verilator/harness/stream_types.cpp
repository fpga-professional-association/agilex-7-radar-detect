#include "harness/stream_types.h"

#include <cstdio>

namespace harness {

std::string StreamBeat::to_string() const {
  char buf[160];
  std::snprintf(buf, sizeof(buf),
                "{data=0x%016llx sof=%d eof=%d id=%u seq=%u user=%u}",
                static_cast<unsigned long long>(data),
                start_of_frame ? 1 : 0, end_of_frame ? 1 : 0, stream_id,
                seq, user);
  return std::string(buf);
}

std::string StreamLayout::self_check() const {
  char buf[192];
  if (user_lsb != 0) {
    std::snprintf(buf, sizeof(buf), "user_lsb=%u, expected 0", user_lsb);
    return std::string(buf);
  }
  if (seq_lsb != user_lsb + user_w) {
    std::snprintf(buf, sizeof(buf), "seq_lsb=%u, expected %u", seq_lsb,
                  user_lsb + user_w);
    return std::string(buf);
  }
  if (id_lsb != seq_lsb + seq_w) {
    std::snprintf(buf, sizeof(buf), "id_lsb=%u, expected %u", id_lsb,
                  seq_lsb + seq_w);
    return std::string(buf);
  }
  if (eof_lsb != id_lsb + id_w) {
    std::snprintf(buf, sizeof(buf), "eof_lsb=%u, expected %u", eof_lsb,
                  id_lsb + id_w);
    return std::string(buf);
  }
  if (sof_lsb != eof_lsb + 1) {
    std::snprintf(buf, sizeof(buf), "sof_lsb=%u, expected %u", sof_lsb,
                  eof_lsb + 1);
    return std::string(buf);
  }
  if (data_lsb != sof_lsb + 1) {
    std::snprintf(buf, sizeof(buf), "data_lsb=%u, expected %u", data_lsb,
                  sof_lsb + 1);
    return std::string(buf);
  }
  if (payload_w != data_lsb + data_w) {
    std::snprintf(buf, sizeof(buf), "payload_w=%u, expected %u", payload_w,
                  data_lsb + data_w);
    return std::string(buf);
  }
  if (!fits_u64()) {
    std::snprintf(buf, sizeof(buf),
                  "payload_w=%u exceeds the 64-bit host payload type",
                  payload_w);
    return std::string(buf);
  }
  return std::string();
}

std::string StreamLayout::to_string() const {
  char buf[224];
  std::snprintf(buf, sizeof(buf),
                "payload_w=%u data[%u+:%u] sof@%u eof@%u id[%u+:%u] "
                "seq[%u+:%u] user[%u+:%u]",
                payload_w, data_lsb, data_w, sof_lsb, eof_lsb, id_lsb, id_w,
                seq_lsb, seq_w, user_lsb, user_w);
  return std::string(buf);
}

}  // namespace harness
