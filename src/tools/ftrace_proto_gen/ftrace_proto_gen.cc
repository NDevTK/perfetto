/*
 * Copyright (C) 2018 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "src/tools/ftrace_proto_gen/ftrace_proto_gen.h"

#include <algorithm>
#include <fstream>
#include <regex>

#include "perfetto/base/logging.h"
#include "perfetto/ext/base/file_utils.h"
#include "perfetto/ext/base/pipe.h"
#include "perfetto/ext/base/string_splitter.h"
#include "perfetto/ext/base/string_utils.h"

namespace perfetto {

namespace {

const char kCopyrightHeader[] = R"(/*
 * Copyright (C) 2017 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

)";

}  // namespace

using base::Contains;
using base::StartsWith;

std::string EventNameToProtoFieldName(const std::string& group,
                                      const std::string& name) {
  std::string event_name = (name == "0") ? "zero" : name;
  // These groups have events where the name alone conflicts with an existing
  // proto:
  if (group == "sde" || group == "g2d" || group == "dpu" || group == "mali" ||
      group == "lwis" || group == "samsung" ||
      (group == "kgsl" && name == "gpu_frequency")) {
    event_name = group + "_" + event_name;
  }
  return event_name;
}

std::string EventNameToProtoName(const std::string& group,
                                 const std::string& name) {
  return ToCamelCase(EventNameToProtoFieldName(group, name)) + "FtraceEvent";
}

std::vector<FtraceEventName> ReadAllowList(const std::string& filename) {
  std::string line;
  std::vector<FtraceEventName> lines;
  std::ifstream fin(filename, std::ios::in);
  if (!fin) {
    fprintf(stderr, "failed to open event list %s\n", filename.c_str());
    return lines;
  }
  while (std::getline(fin, line)) {
    if (!StartsWith(line, "#"))
      lines.emplace_back(FtraceEventName(line));
  }
  return lines;
}

std::vector<Proto::Field> ToProtoFields(const FtraceEvent& format) {
  std::vector<Proto::Field> ret;
  for (size_t i = 0; i < format.fields.size(); i++) {
    const FtraceEvent::Field& field = format.fields[i];
    std::string name = GetNameFromTypeAndName(field.type_and_name);
    // Skip tracepoint fields whose names cannot be used as an identifier in the
    // generated C++ code due to stdlib header conflicts.
    if (name == "" || name == "sa_handler" || name == "errno")
      continue;
    ProtoType type = InferProtoType(field);
    if (type.type == ProtoType::INVALID)
      continue;
    ret.push_back({type, std::move(name), static_cast<uint32_t>(i)});
  }
  return ret;
}

void GenerateFtraceEventProto(const std::vector<FtraceEventName>& raw_eventlist,
                              const std::set<std::string>& groups,
                              std::ostream* fout) {
  *fout << kCopyrightHeader;
  *fout << "// Autogenerated by:\n";
  *fout << std::string("// ") + __FILE__ + "\n";
  *fout << "// Do not edit.\n\n";
  *fout << R"(syntax = "proto2";)"
        << "\n\n";

  for (const std::string& group : groups) {
    *fout << R"(import "protos/perfetto/trace/ftrace/)" << group
          << R"(.proto";)"
          << "\n";
  }
  *fout << "import \"protos/perfetto/trace/ftrace/generic.proto\";\n";
  *fout << "\n";
  *fout << "package perfetto.protos;\n\n";
  *fout << R"(message FtraceEvent {
  // Timestamp in nanoseconds using .../tracing/trace_clock.
  optional uint64 timestamp = 1;

  // Kernel pid (do not confuse with userspace pid aka tgid).
  optional uint32 pid = 2;

  // Not populated in actual traces. Wire format might change.
  // Placeholder declaration so that the ftrace parsing code accepts the
  // existence of this common field. If this becomes needed for all events:
  // consider merging with common_preempt_count to avoid extra proto tags.
  optional uint32 common_flags = 5;

  oneof event {
)";

  int i = 3;
  for (const FtraceEventName& event : raw_eventlist) {
    if (!event.valid()) {
      *fout << "    // removed field with id " << i << ";\n";
      ++i;
      continue;
    }

    std::string field_name =
        EventNameToProtoFieldName(event.group(), event.name());
    std::string type_name = EventNameToProtoName(event.group(), event.name());

    // "    " (indent) + TypeName + " " + field_name + " = " + 123 + ";"
    if (4 + type_name.size() + 1 + field_name.size() + 3 + 3 + 1 <= 80) {
      // Everything fits in one line:
      *fout << "    " << type_name << " " << field_name << " = " << i << ";\n";
    } else if (4 + type_name.size() + 1 + field_name.size() + 2 <= 80) {
      // Everything fits except the field id:
      *fout << "    " << type_name << " " << field_name << " =\n        " << i
            << ";\n";
    } else {
      // Nothing fits:
      *fout << "    " << type_name << "\n        " << field_name << " = " << i
            << ";\n";
    }
    ++i;
    // We cannot depend on the proto file to get this number because
    // it would cause a dependency cycle between this generator and the
    // generated code.
    if (i == 327) {
      *fout << "    GenericFtraceEvent generic = " << i << ";\n";
      ++i;
    }
  }
  *fout << "  }\n";
  *fout << "}\n";
}

// Generates section of event_info.cc for a single event.
std::string SingleEventInfo(perfetto::Proto proto,
                            const std::string& group,
                            const uint32_t proto_field_id) {
  std::string s = "{";
  s += "\"" + proto.event_name + "\", ";
  s += "\"" + group + "\", ";

  // Vector of fields.
  s += "{ ";
  for (const auto& field : proto.SortedFields()) {
    // Ignore the "ip" field from print events. This field has not proven
    // particularly useful and takes up a large amount of space (30% of total
    // PrintFtraceEvent size and up to 12% of the entire trace in some
    // configurations)
    if (group == "ftrace" && proto.event_name == "print" && field->name == "ip")
      continue;
    // Ignore the "nid" field. On new kernels, this field has a type that we
    // don't know how to parse. See b/281660544
    if (group == "f2fs" && proto.event_name == "f2fs_truncate_partial_nodes" &&
        field->name == "nid")
      continue;
    s += "{";
    s += "kUnsetOffset, ";
    s += "kUnsetSize, ";
    s += "FtraceFieldType::kInvalidFtraceFieldType, ";
    s += "\"" + field->name + "\", ";
    s += std::to_string(field->number) + ", ";
    s += "ProtoSchemaType::k" + ToCamelCase(field->type.ToString()) + ", ";
    s += "TranslationStrategy::kInvalidTranslationStrategy";
    s += "}, ";
  }
  s += "}, ";

  s += "kUnsetFtraceId, ";
  s += std::to_string(proto_field_id) + ", ";
  s += "kUnsetSize";
  s += "}";
  return s;
}

// This will generate the event_info.cc file for the listed protos.
void GenerateEventInfo(const std::vector<std::string>& events_info,
                       std::ostream* fout) {
  std::string s = kCopyrightHeader;
  s += "// Autogenerated by:\n";
  s += std::string("// ") + __FILE__ + "\n";
  s += "// Do not edit.\n";
  s += R"(
#include "src/traced/probes/ftrace/event_info.h"

#include "perfetto/protozero/proto_utils.h"

namespace perfetto {

using protozero::proto_utils::ProtoSchemaType;

std::vector<Event> GetStaticEventInfo() {
  static constexpr uint16_t kUnsetOffset = 0;
  static constexpr uint16_t kUnsetSize = 0;
  static constexpr uint16_t kUnsetFtraceId = 0;
  return
)";

  s += " {";
  for (const auto& event : events_info) {
    s += event;
    s += ",\n";
  }
  s += "};";

  s += R"(
}

}  // namespace perfetto
)";

  *fout << s;
}

std::string ProtoHeader() {
  std::string s = "// Autogenerated by:\n";
  s += std::string("// ") + __FILE__ + "\n";
  s += "// Do not edit.\n";

  s += R"(
syntax = "proto2";
package perfetto.protos;

)";
  return s;
}

}  // namespace perfetto
