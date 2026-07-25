#include "harness/stream_types.h"

#include <cstdio>

namespace harness {

std::string StreamBeat::to_string() const {
  char buf[160];
  std::snprintf(buf, sizeof(buf),
                "{data=0x%016llx sof=%d eof=%d id=%u seq=%u user=%u}",
                static_cast<unsigned long long>(data),
                start_of_frame ? 1 : 0, end_of_frame ? 1 : 0, stream_id,
                sequence, user);
  return std::string(buf);
}

}  // namespace harness
