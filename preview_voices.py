#!/usr/bin/env python3
"""piper-zh_CN-huayan 试听（1个音色，轻量模型）"""
import sherpa_onnx
import numpy as np
import soundfile as sf
import os

MODEL_DIR = "/Users/zxw/AITOOL/PhoneC/Models/vits-piper-zh_CN-huayan-medium"
OUTPUT_DIR = "/Users/zxw/AITOOL/PhoneC/voice_preview_fanchen"
TEXT = "你好，我是你的智能助手，有什么可以帮你的吗？今天天气真不错。"

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    tts_config = sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(
            vits=sherpa_onnx.OfflineTtsVitsModelConfig(
                model=f"{MODEL_DIR}/zh_CN-huayan-medium.onnx",
                tokens=f"{MODEL_DIR}/tokens.txt",
                data_dir=f"{MODEL_DIR}/espeak-ng-data",
            ),
            num_threads=4,
        ),
    )
    tts = sherpa_onnx.OfflineTts(tts_config)
    out_path = f"{OUTPUT_DIR}/piper_huayan.wav"
    audio = tts.generate(TEXT, sid=0, speed=1.0)
    samples = np.array(audio.samples)
    sf.write(out_path, samples, audio.sample_rate)
    dur = len(audio.samples) / audio.sample_rate
    print(f"✅ piper-huayan → {dur:.1f}s → {out_path}")
    os.system(f"open {OUTPUT_DIR}")

if __name__ == "__main__":
    main()
