#ifndef PhoneClaw_Bridging_Header_h
#define PhoneClaw_Bridging_Header_h

#include "sherpa-onnx/c-api/c-api.h"

// ONNX Runtime C API — used by LocalSmartTurnAnalyzer for on-device SmartTurn inference.
// xcframework: Frameworks/onnxruntime.xcframework (already linked in app target).
// HEADER_SEARCH_PATHS includes Frameworks/onnxruntime.xcframework/Headers.
#include "onnxruntime_c_api.h"

#endif
