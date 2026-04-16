#!/usr/bin/env python3
"""
Add missing Swift files to PhoneClaw.xcodeproj/project.pbxproj.
Uses sourceTree = SOURCE_ROOT so paths are relative to project root.
Adds file refs to the PhoneClaw group (D21E6B56B839A63857912FE0) children.
"""
import os, re, hashlib, sys

PROJ_DIR = "/Users/zxw/AITOOL/PhoneC"
PBXPROJ = os.path.join(PROJ_DIR, "PhoneClaw.xcodeproj", "project.pbxproj")

FILES_TO_ADD = [
    "PipecatRuntime/App/LiveSessionState.swift",
    "PipecatRuntime/Audio/Turn/BaseTurnAnalyzer.swift",
    "PipecatRuntime/Audio/Turn/SmartTurn/BaseSmartTurn.swift",
    "PipecatRuntime/Audio/Turn/SmartTurn/LocalSmartTurnAnalyzer.swift",
    "PipecatRuntime/Frames/AudioChunk.swift",
    "PipecatRuntime/Frames/AudioFrames.swift",
    "PipecatRuntime/Frames/ControlFrames.swift",
    "PipecatRuntime/Frames/Frames.swift",
    "PipecatRuntime/Frames/FunctionFrames.swift",
    "PipecatRuntime/Frames/LLMFrames.swift",
    "PipecatRuntime/Observers/BaseObserver.swift",
    "PipecatRuntime/Observers/LiveStateObserver.swift",
    "PipecatRuntime/Pipeline/Pipeline.swift",
    "PipecatRuntime/Pipeline/PipelineTask.swift",
    "PipecatRuntime/Pipeline/PriorityFrameQueue.swift",
    "PipecatRuntime/Processors/Aggregators/LLMAssistantAggregator.swift",
    "PipecatRuntime/Processors/Aggregators/LLMContext.swift",
    "PipecatRuntime/Processors/Aggregators/LLMContextAggregator.swift",
    "PipecatRuntime/Processors/Aggregators/LLMContextAggregatorPair.swift",
    "PipecatRuntime/Processors/Aggregators/LLMUserAggregator.swift",
    "PipecatRuntime/Processors/Audio/BotSpeechGateProcessor.swift",
    "PipecatRuntime/Processors/Audio/FluidAudioVADAnalyzer.swift",
    "PipecatRuntime/Processors/Audio/VADAnalyzerProtocol.swift",
    "PipecatRuntime/Processors/Audio/VADController.swift",
    "PipecatRuntime/Processors/Audio/VADProcessor.swift",
    "PipecatRuntime/Processors/FrameProcessor.swift",
    "PipecatRuntime/Services/Local/MLXLLMServiceAdapter.swift",
    "PipecatRuntime/Services/Local/SherpaSTTServiceAdapter.swift",
    "PipecatRuntime/Services/Local/SherpaSegmentedSTTServiceAdapter.swift",
    "PipecatRuntime/Services/Local/SherpaStreamingSTTServiceAdapter.swift",
    "PipecatRuntime/Services/Local/SherpaTTSServiceAdapter.swift",
    "PipecatRuntime/Services/STTService.swift",
    "PipecatRuntime/Services/SegmentedSTTService.swift",
    "PipecatRuntime/Text/BaseTextFilter.swift",
    "PipecatRuntime/Text/MarkdownTextFilter.swift",
    "PipecatRuntime/Text/RemoveEmojiTextFilter.swift",
    "PipecatRuntime/Transports/BaseInputTransport.swift",
    "PipecatRuntime/Transports/BaseOutputTransport.swift",
    "PipecatRuntime/Transports/BaseTransport.swift",
    "PipecatRuntime/Transports/IOSLiveTransport.swift",
    "PipecatRuntime/Turns/Strategies/Start/BaseUserTurnStartStrategy.swift",
    "PipecatRuntime/Turns/Strategies/Start/TranscriptionUserTurnStartStrategy.swift",
    "PipecatRuntime/Turns/Strategies/Start/VADUserTurnStartStrategy.swift",
    "PipecatRuntime/Turns/Strategies/Stop/BaseUserTurnStopStrategy.swift",
    "PipecatRuntime/Turns/Strategies/Stop/SpeechTimeoutUserTurnStopStrategy.swift",
    "PipecatRuntime/Turns/Strategies/Stop/TurnAnalyzerUserTurnStopStrategy.swift",
    "PipecatRuntime/Turns/Strategies/UserTurnParams.swift",
    "PipecatRuntime/Turns/Types/ProcessFrameResult.swift",
    "PipecatRuntime/Turns/UserIdleController.swift",
    "PipecatRuntime/Turns/UserMute/AlwaysUserMuteStrategy.swift",
    "PipecatRuntime/Turns/UserMute/BaseUserMuteStrategy.swift",
    "PipecatRuntime/Turns/UserTurnController.swift",
    "PipecatRuntime/Turns/UserTurnProcessor.swift",
    "PipecatRuntime/Turns/UserTurnStrategies.swift",
    "Agent/PipecatBindings/UserTurnStrategies+iOSDefault.swift",
    "Agent/Engine/OutputSanitizer.swift",
    "Agent/ASRService.swift",
    "Agent/LiveCameraService.swift",
    "Agent/LiveComponentTest.swift",
    "Agent/LiveMetrics.swift",
    "Agent/OrbAudioAnalyser.swift",
    "Agent/PipecatLivePipeline.swift",
    "Agent/SherpaOnnx.swift",
    "Agent/TTSService.swift",
    "Agent/VADService.swift",
    "Agent/LiveAudioIO.swift",
    "Agent/LiveModeEngine.swift",
    "Agent/VoiceTurnController.swift",
    "UI/AudioUI.swift",
    "UI/LiveModeUI.swift",
    "UI/LiveOrb/OrbBackgroundView.swift",
    "UI/LiveOrb/OrbSceneView.swift",
    "UI/LiveOrb/OrbShaderSource.swift",
    "UI/ResponseUI.swift",
    "UI/SharedUI.swift",
]

def make_uuid(seed):
    return hashlib.md5(seed.encode()).hexdigest().upper()[:24]

def main():
    if not os.path.exists(PBXPROJ):
        print(f"ERROR: {PBXPROJ} not found"); sys.exit(1)

    for f in FILES_TO_ADD:
        if not os.path.exists(os.path.join(PROJ_DIR, f)):
            print(f"ERROR: {f} not found"); sys.exit(1)

    with open(PBXPROJ, "r") as fh:
        content = fh.read()

    # Skip already-registered files
    files = [f for f in FILES_TO_ADD if os.path.basename(f) not in content]
    if not files:
        print("All files already registered!"); return

    existing_uuids = set(re.findall(r'\b([0-9A-F]{24})\b', content))
    def safe_uuid(seed):
        u = make_uuid(seed)
        attempt = 0
        while u in existing_uuids:
            attempt += 1; u = make_uuid(seed + str(attempt))
        existing_uuids.add(u)
        return u

    entries = []
    for f in files:
        bn = os.path.basename(f)
        entries.append({
            "path": f,
            "basename": bn,
            "fileref": safe_uuid(f"fileref_{f}_v2"),
            "buildfile": safe_uuid(f"buildfile_{f}_v2"),
        })

    # --- Anchors ---
    # PBXBuildFile: after OutputCleaner
    anchor_bf = re.compile(r'(\t\tA31476FB2F85741500318978 /\* OutputCleaner\.swift in Sources \*/ = \{[^}]+\};)\n')
    # PBXFileReference: after OutputCleaner
    anchor_fr = re.compile(r'(\t\tA31476EF2F85741500318978 /\* OutputCleaner\.swift \*/ = \{[^}]+\};)\n')
    # Sources build phase: after OutputCleaner
    anchor_sp = re.compile(r'(\t\t\t\tA31476FB2F85741500318978 /\* OutputCleaner\.swift in Sources \*/,)\n')
    # PhoneClaw group children: D21E6B56B839A63857912FE0
    anchor_grp = re.compile(r'(\t\tD21E6B56B839A63857912FE0 /\* PhoneClaw \*/ = \{\s*\n\t\t\tisa = PBXGroup;\s*\n\t\t\tchildren = \(\n)')

    for name, pat in [("PBXBuildFile", anchor_bf), ("PBXFileReference", anchor_fr),
                       ("Sources", anchor_sp), ("Group", anchor_grp)]:
        if not pat.search(content):
            print(f"ERROR: anchor not found for {name}"); sys.exit(1)

    # 1. PBXBuildFile
    lines = "\n".join(
        f'\t\t{e["buildfile"]} /* {e["basename"]} in Sources */ = '
        f'{{isa = PBXBuildFile; fileRef = {e["fileref"]} /* {e["basename"]} */; }};'
        for e in entries
    ) + "\n"
    m = anchor_bf.search(content)
    content = content[:m.end()] + lines + content[m.end():]

    # 2. PBXFileReference — use sourceTree = SOURCE_ROOT with full relative path
    lines = "\n".join(
        f'\t\t{e["fileref"]} /* {e["basename"]} */ = '
        f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
        f'name = "{e["basename"]}"; path = "{e["path"]}"; sourceTree = SOURCE_ROOT; }};'
        for e in entries
    ) + "\n"
    m = anchor_fr.search(content)
    content = content[:m.end()] + lines + content[m.end():]

    # 3. Sources build phase
    lines = "\n".join(
        f'\t\t\t\t{e["buildfile"]} /* {e["basename"]} in Sources */,'
        for e in entries
    ) + "\n"
    m = anchor_sp.search(content)
    content = content[:m.end()] + lines + content[m.end():]

    # 4. PhoneClaw group children — add after opening "children = ("
    lines = "\n".join(
        f'\t\t\t\t{e["fileref"]} /* {e["basename"]} */,'
        for e in entries
    ) + "\n"
    m = anchor_grp.search(content)
    content = content[:m.end()] + lines + content[m.end():]

    with open(PBXPROJ, "w") as fh:
        fh.write(content)

    print(f"\n✅ Added {len(entries)} files to pbxproj (sourceTree = SOURCE_ROOT)")
    for e in entries:
        print(f"  + {e['path']}")

if __name__ == "__main__":
    main()
