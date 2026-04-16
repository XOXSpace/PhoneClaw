#!/usr/bin/env python3
"""
Offline conversion script: Pipecat smart-turn-v3 ONNX → Apple CoreML (.mlpackage).

Model shape (confirmed from ONNX graph inspection):
    Input:  input_features [batch, 80, 800]   float32  (Whisper mel, 8s @ 10ms/frame)
    Output: logits         [batch, 1]          float32  (sigmoid probability)

ENVIRONMENT CONSTRAINTS (discovered):
    - coremltools ≥ 5.x dropped direct ONNX support (only PyTorch/TF/MIL)
    - coremltools 4.x (last version with ONNX) requires Python 3.8 + x86_64
    - onnx2torch 1.5.x does NOT support DequantizeLinear opset 13 (used in this model)
    - onnxsim segfaults on this model on macOS ARM64

RECOMMENDED CONVERSION PATHS:

  OPTION A — CoreML (requires Rosetta terminal):
    arch -x86_64 /usr/bin/python3 -m pip install coremltools==4.1 onnx==1.10.2 numpy
    arch -x86_64 python3 scripts/convert_smart_turn.py
    → Output: smart-turn-v3.mlpackage  (add to Xcode project → Copy Bundle Resources)

  OPTION B — ORT Mobile, no conversion needed (recommended for current environment):
    1. In Xcode: File → Add Package Dependency
       URL: https://github.com/microsoft/onnxruntime-swift-package-manager
       Target: onnxruntime  (iOS arm64)
    2. Copy smart-turn-v3.2-cpu.onnx into Xcode project Resources
    3. LocalSmartTurnAnalyzer.swift: switch inference backend from MLModel → ORTSession

Output (if Option A succeeds):
    smart-turn-v3.mlpackage   (add to Xcode project → Copy Bundle Resources)
"""
import os
import sys
import numpy as np

try:
    import onnx
    import onnxruntime as ort
    import coremltools as ct
except ImportError:
    print("ERROR: pip install coremltools onnx onnxruntime")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Locate the bundled ONNX model from pipecat package
# ---------------------------------------------------------------------------
MODEL_NAME = "smart-turn-v3.2-cpu.onnx"
try:
    import importlib.resources as impresources
    PACKAGE = "pipecat.audio.turn.smart_turn.data"
    with impresources.path(PACKAGE, MODEL_NAME) as p:
        onnx_path = str(p)
except Exception:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    onnx_path = os.path.join(
        script_dir, "..", "..", "pipecat", "src",
        "pipecat", "audio", "turn", "smart_turn", "data", MODEL_NAME
    )
    if not os.path.exists(onnx_path):
        print(f"ERROR: Cannot locate {MODEL_NAME}.\n  Searched: {onnx_path}")
        sys.exit(1)

print(f"Loading ONNX model from:\n  {onnx_path}")
model = onnx.load(onnx_path)
onnx.checker.check_model(model)
print("ONNX model validated ✓")

# ---------------------------------------------------------------------------
# Dequantize: remove QuantizeLinear / DequantizeLinear → fp32 model
# ---------------------------------------------------------------------------
print("Dequantizing ONNX model to fp32…")
from onnxruntime.tools.onnx_model_utils import fix_output_shapes
from onnxruntime.quantization import dequantize_model

dequant_path = onnx_path.replace(".onnx", "-fp32.onnx")
dequantize_model(onnx_path, dequant_path)
print(f"  fp32 model saved to: {dequant_path}")

# Reload fp32 model
model_fp32 = onnx.load(dequant_path)

# ---------------------------------------------------------------------------
# Actual input shape: [batch, 80, 800]  (confirmed from graph inspection)
# 800 frames = 8s at 10ms/frame  (Whisper 16kHz, hop=160)
# ---------------------------------------------------------------------------
input_shape = ct.Shape(shape=(1, 80, 800))

# ---------------------------------------------------------------------------
# Convert fp32 ONNX → PyTorch → CoreML
# ---------------------------------------------------------------------------
print("Converting fp32 ONNX → PyTorch (onnx2torch)…")
try:
    import onnx2torch
    import torch
except ImportError:
    print("ERROR: pip install onnx2torch torch")
    sys.exit(1)

torch_model = onnx2torch.convert(dequant_path)
torch_model.eval()

dummy_input = torch.zeros(1, 80, 800, dtype=torch.float32)
with torch.no_grad():
    traced = torch.jit.trace(torch_model, dummy_input)

print("Converting PyTorch → CoreML (coremltools)…")
coreml_model = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_features", shape=input_shape)],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT32,
    compute_units=ct.ComputeUnit.ALL,
)

# ---------------------------------------------------------------------------
# Annotate metadata
# ---------------------------------------------------------------------------
coreml_model.short_description = (
    "Smart-turn-v3 end-of-turn detector. "
    "Input: Whisper mel spectrogram [1,80,800] at 16 kHz (8s window). "
    "Output: sigmoid probability of speech completion (>0.5 = complete)."
)
coreml_model.input_description["input_features"] = "Whisper mel spectrogram [1, 80, 800]"
coreml_model.output_description["logits"] = "Sigmoid probability >0.5 → complete"

# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------
output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
output_path = os.path.join(output_dir, "smart-turn-v3.mlpackage")
coreml_model.save(output_path)
print(f"\nSaved CoreML model to:\n  {output_path}")
print("→ Add smart-turn-v3.mlpackage to Xcode project under Copy Bundle Resources.")

# ---------------------------------------------------------------------------
# Numerical parity check: ONNX (onnxruntime) vs CoreML
# ---------------------------------------------------------------------------
print("\nRunning numerical parity check…")
try:
    dummy = np.random.randn(1, 80, 800).astype(np.float32)

    # ONNX inference (fp32 model)
    session = ort.InferenceSession(dequant_path)
    onnx_out = float(session.run(None, {"input_features": dummy})[0].flatten()[0])

    # CoreML inference
    loaded = ct.models.MLModel(output_path)
    ct_out_dict = loaded.predict({"input_features": dummy})
    ct_out = float(list(ct_out_dict.values())[0].flatten()[0])

    diff = abs(onnx_out - ct_out)
    print(f"  ONNX output  : {onnx_out:.6f}")
    print(f"  CoreML output: {ct_out:.6f}")
    print(f"  Absolute diff: {diff:.6f}")
    if diff < 0.01:
        print("  Parity check PASSED ✓ (diff < 0.01)")
    else:
        print(f"  WARNING: diff={diff:.4f} > 0.01. Check model conversion.")
except Exception as e:
    print(f"  Skipped parity check: {e}")

print("\nDone.")
