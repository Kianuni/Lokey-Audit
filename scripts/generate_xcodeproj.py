#!/usr/bin/env python3
"""
Generates `AuditDemoApp/Assets.xcassets` and `LokeyAudit.xcodeproj`
(`AuditDemoApp`, `LokeyKeyboard`, `LokeyAuditTests`) without external dependencies.
"""
from __future__ import annotations

import json
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def write_app_icon_png(dest: Path) -> None:
    """Writes a clean 1024x1024 RGB PNG app icon (obsidian-slate gradient + tactile ivory keycaps)."""
    w = h = 1024
    rows = []
    for y in range(h):
        ty = y / (h - 1)
        bg_r = int(36 + (18 - 36) * ty)
        bg_g = int(39 + (20 - 39) * ty)
        bg_b = int(46 + (24 - 46) * ty)

        row = bytearray([0])
        in_board_y = 280 <= y <= 744
        for x in range(w):
            r, g, b = bg_r, bg_g, bg_b
            if in_board_y and 180 <= x <= 844:
                dx = max(0, 228 - x, x - 796)
                dy = max(0, 328 - y, y - 696)
                if dx * dx + dy * dy <= 48 * 48:
                    r, g, b = 52, 56, 65
                    if 352 <= y <= 452:
                        rel_x = x - 236
                        if 0 <= rel_x < 552 and (rel_x % 142) < 116:
                            r, g, b = (244, 245, 248) if y < 446 else (182, 186, 196)
                    elif 476 <= y <= 576:
                        rel_x = x - 307
                        if 0 <= rel_x < 410 and (rel_x % 142) < 116:
                            r, g, b = (244, 245, 248) if y < 570 else (182, 186, 196)
                    elif 600 <= y <= 676 and 280 <= x <= 744:
                        r, g, b = (244, 245, 248) if y < 670 else (182, 186, 196)
            row.extend((r, g, b))
        rows.append(bytes(row))

    raw_data = b"".join(rows)

    def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png_bytes = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(raw_data, level=6))
        + png_chunk(b"IEND", b"")
    )
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(png_bytes)


def generate_assets() -> None:
    assets_dir = ROOT / "AuditDemoApp" / "Assets.xcassets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    (assets_dir / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )
    appicon_dir = assets_dir / "AppIcon.appiconset"
    appicon_dir.mkdir(parents=True, exist_ok=True)
    write_app_icon_png(appicon_dir / "AppIcon-1024.png")
    (appicon_dir / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {
                        "filename": "AppIcon-1024.png",
                        "idiom": "universal",
                        "platform": "ios",
                        "size": "1024x1024",
                    }
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def generate_pbxproj() -> None:
    proj_dir = ROOT / "LokeyAudit.xcodeproj"
    proj_dir.mkdir(parents=True, exist_ok=True)

    pbx = r"""// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		B10000010000000000000001 /* AuditDemoApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000010000000000000001 /* AuditDemoApp.swift */; };
		B10000020000000000000001 /* ContentView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000020000000000000001 /* ContentView.swift */; };
		B10000030000000000000001 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = B20000030000000000000001 /* Assets.xcassets */; };
		B10000050000000000000001 /* lokey_opencc.bin in Resources */ = {isa = PBXBuildFile; fileRef = B200002C0000000000000001 /* lokey_opencc.bin */; };
		B10000060000000000000001 /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = B20000060000000000000001 /* PrivacyInfo.xcprivacy */; };
		B10000070000000000000001 /* lokey_emoji.bin in Resources */ = {isa = PBXBuildFile; fileRef = B200001A0000000000000001 /* lokey_emoji.bin */; };

		/* Shared Engine compiled into AuditDemoApp */
		B10000100000000000000001 /* LokeySettings.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000100000000000000001 /* LokeySettings.swift */; };
		B10000110000000000000001 /* SpatialTouchModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000110000000000000001 /* SpatialTouchModel.swift */; };
		B10000120000000000000001 /* MmapLexicon.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000120000000000000001 /* MmapLexicon.swift */; };
		B10000130000000000000001 /* PinyinSyllableAutomaton.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000130000000000000001 /* PinyinSyllableAutomaton.swift */; };
		B10000140000000000000001 /* UserLexiconStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000140000000000000001 /* UserLexiconStore.swift */; };
		B10000150000000000000001 /* ViterbiDecoder.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000150000000000000001 /* ViterbiDecoder.swift */; };
		B10000160000000000000001 /* LokeySessionController.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000160000000000000001 /* LokeySessionController.swift */; };
		B10000170000000000000001 /* NeuralSentenceScorer.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000190000000000000001 /* NeuralSentenceScorer.swift */; };
		B10000180000000000000001 /* LokeyDiagnosticLogger.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001B0000000000000001 /* LokeyDiagnosticLogger.swift */; };
		B10000190000000000000001 /* NoisyChannelRefiner.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001C0000000000000001 /* NoisyChannelRefiner.swift */; };
		B100001A0000000000000001 /* OpenCCConverter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001D0000000000000001 /* OpenCCConverter.swift */; };
		B100001B0000000000000001 /* RimeUserLexiconImporter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001E0000000000000001 /* RimeUserLexiconImporter.swift */; };

		/* Shared Engine + UI compiled into LokeyKeyboard extension */
		B10000200000000000000001 /* LokeySettings.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000100000000000000001 /* LokeySettings.swift */; };
		B10000210000000000000001 /* SpatialTouchModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000110000000000000001 /* SpatialTouchModel.swift */; };
		B10000220000000000000001 /* MmapLexicon.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000120000000000000001 /* MmapLexicon.swift */; };
		B10000230000000000000001 /* PinyinSyllableAutomaton.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000130000000000000001 /* PinyinSyllableAutomaton.swift */; };
		B10000240000000000000001 /* UserLexiconStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000140000000000000001 /* UserLexiconStore.swift */; };
		B10000250000000000000001 /* ViterbiDecoder.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000150000000000000001 /* ViterbiDecoder.swift */; };
		B10000260000000000000001 /* LokeySessionController.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000160000000000000001 /* LokeySessionController.swift */; };
		B100002E0000000000000001 /* NeuralSentenceScorer.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000190000000000000001 /* NeuralSentenceScorer.swift */; };
		B10000310000000000000001 /* LokeyDiagnosticLogger.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001B0000000000000001 /* LokeyDiagnosticLogger.swift */; };
		B10000320000000000000001 /* NoisyChannelRefiner.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001C0000000000000001 /* NoisyChannelRefiner.swift */; };
		B10000330000000000000001 /* OpenCCConverter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001D0000000000000001 /* OpenCCConverter.swift */; };
		B10000270000000000000001 /* KeyboardViewController.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000200000000000000001 /* KeyboardViewController.swift */; };
		B10000280000000000000001 /* KeyboardTheme.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000210000000000000001 /* KeyboardTheme.swift */; };
		B10000290000000000000001 /* KeyCalloutBubbleView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000220000000000000001 /* KeyCalloutBubbleView.swift */; };
		B100002A0000000000000001 /* KeyGridView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000230000000000000001 /* KeyGridView.swift */; };
		B100002B0000000000000001 /* CandidateBarView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000240000000000000001 /* CandidateBarView.swift */; };
		B100002C0000000000000001 /* EmojiKeyboardView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000250000000000000001 /* EmojiKeyboardView.swift */; };
		B100002F0000000000000001 /* lokey_emoji.bin in Resources */ = {isa = PBXBuildFile; fileRef = B200001A0000000000000001 /* lokey_emoji.bin */; };
		B100006C0000000000000001 /* lokey_opencc.bin in Resources */ = {isa = PBXBuildFile; fileRef = B200002C0000000000000001 /* lokey_opencc.bin */; };
		B100006E0000000000000001 /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = B20000280000000000000001 /* PrivacyInfo.xcprivacy */; };

		/* Embed App Extension into Host App PlugIns */
		B10000300000000000000001 /* LokeyKeyboard.appex in Embed App Extensions */ = {isa = PBXBuildFile; fileRef = B20000910000000000000001 /* LokeyKeyboard.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };

		/* Unit & Audit Tests */
		B10000400000000000000001 /* LokeyAuditTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000400000000000000001 /* LokeyAuditTests.swift */; };
		B10000510000000000000001 /* lokey_emoji.bin in Resources */ = {isa = PBXBuildFile; fileRef = B200001A0000000000000001 /* lokey_emoji.bin */; };
		B100006D0000000000000001 /* lokey_opencc.bin in Resources */ = {isa = PBXBuildFile; fileRef = B200002C0000000000000001 /* lokey_opencc.bin */; };
		B10000420000000000000001 /* KeyboardViewController.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000200000000000000001 /* KeyboardViewController.swift */; };
		B10000430000000000000001 /* KeyboardTheme.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000210000000000000001 /* KeyboardTheme.swift */; };
		B10000440000000000000001 /* KeyCalloutBubbleView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000220000000000000001 /* KeyCalloutBubbleView.swift */; };
		B10000450000000000000001 /* KeyGridView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000230000000000000001 /* KeyGridView.swift */; };
		B10000460000000000000001 /* CandidateBarView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000240000000000000001 /* CandidateBarView.swift */; };
		B10000470000000000000001 /* EmojiKeyboardView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000250000000000000001 /* EmojiKeyboardView.swift */; };
		B10000480000000000000001 /* LokeySettings.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000100000000000000001 /* LokeySettings.swift */; };
		B10000490000000000000001 /* SpatialTouchModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000110000000000000001 /* SpatialTouchModel.swift */; };
		B100004A0000000000000001 /* MmapLexicon.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000120000000000000001 /* MmapLexicon.swift */; };
		B100004B0000000000000001 /* PinyinSyllableAutomaton.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000130000000000000001 /* PinyinSyllableAutomaton.swift */; };
		B100004C0000000000000001 /* UserLexiconStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000140000000000000001 /* UserLexiconStore.swift */; };
		B100004D0000000000000001 /* ViterbiDecoder.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000150000000000000001 /* ViterbiDecoder.swift */; };
		B100004E0000000000000001 /* LokeySessionController.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000160000000000000001 /* LokeySessionController.swift */; };
		B100004F0000000000000001 /* NeuralSentenceScorer.swift in Sources */ = {isa = PBXBuildFile; fileRef = B20000190000000000000001 /* NeuralSentenceScorer.swift */; };
		B10000520000000000000001 /* LokeyDiagnosticLogger.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001B0000000000000001 /* LokeyDiagnosticLogger.swift */; };
		B10000530000000000000001 /* NoisyChannelRefiner.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001C0000000000000001 /* NoisyChannelRefiner.swift */; };
		B10000540000000000000001 /* OpenCCConverter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001D0000000000000001 /* OpenCCConverter.swift */; };
		B10000550000000000000001 /* RimeUserLexiconImporter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B200001E0000000000000001 /* RimeUserLexiconImporter.swift */; };
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		B30000010000000000000001 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = B80000010000000000000001 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = B60000020000000000000001;
			remoteInfo = LokeyKeyboard;
		};
		B30000020000000000000001 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = B80000010000000000000001 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = B60000010000000000000001;
			remoteInfo = AuditDemoApp;
		};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
		B45000010000000000000001 /* Embed App Extensions */ = {
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				B10000300000000000000001 /* LokeyKeyboard.appex in Embed App Extensions */,
			);
			name = "Embed App Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
		B20000010000000000000001 /* AuditDemoApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AuditDemoApp.swift; sourceTree = "<group>"; };
		B20000020000000000000001 /* ContentView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ContentView.swift; sourceTree = "<group>"; };
		B20000030000000000000001 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
		B20000040000000000000001 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		B20000050000000000000001 /* AuditDemoApp.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = AuditDemoApp.entitlements; sourceTree = "<group>"; };
		B20000060000000000000001 /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };

		B20000100000000000000001 /* LokeySettings.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LokeySettings.swift; sourceTree = "<group>"; };
		B20000110000000000000001 /* SpatialTouchModel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SpatialTouchModel.swift; sourceTree = "<group>"; };
		B20000120000000000000001 /* MmapLexicon.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MmapLexicon.swift; sourceTree = "<group>"; };
		B20000130000000000000001 /* PinyinSyllableAutomaton.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PinyinSyllableAutomaton.swift; sourceTree = "<group>"; };
		B20000140000000000000001 /* UserLexiconStore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UserLexiconStore.swift; sourceTree = "<group>"; };
		B20000150000000000000001 /* ViterbiDecoder.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ViterbiDecoder.swift; sourceTree = "<group>"; };
		B20000160000000000000001 /* LokeySessionController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LokeySessionController.swift; sourceTree = "<group>"; };
		B20000190000000000000001 /* NeuralSentenceScorer.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NeuralSentenceScorer.swift; sourceTree = "<group>"; };
		B200001B0000000000000001 /* LokeyDiagnosticLogger.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LokeyDiagnosticLogger.swift; sourceTree = "<group>"; };
		B200001C0000000000000001 /* NoisyChannelRefiner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NoisyChannelRefiner.swift; sourceTree = "<group>"; };
		B200001D0000000000000001 /* OpenCCConverter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OpenCCConverter.swift; sourceTree = "<group>"; };
		B200001E0000000000000001 /* RimeUserLexiconImporter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RimeUserLexiconImporter.swift; sourceTree = "<group>"; };
		B20000180000000000000001 /* demo_lexicon.bin */ = {isa = PBXFileReference; lastKnownFileType = archive.macbinary; path = demo_lexicon.bin; sourceTree = "<group>"; };
		B200001A0000000000000001 /* lokey_emoji.bin */ = {isa = PBXFileReference; lastKnownFileType = archive.macbinary; path = lokey_emoji.bin; sourceTree = "<group>"; };
		B200002C0000000000000001 /* lokey_opencc.bin */ = {isa = PBXFileReference; lastKnownFileType = archive.macbinary; path = lokey_opencc.bin; sourceTree = "<group>"; };

		B20000200000000000000001 /* KeyboardViewController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = KeyboardViewController.swift; sourceTree = "<group>"; };
		B20000210000000000000001 /* KeyboardTheme.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = KeyboardTheme.swift; sourceTree = "<group>"; };
		B20000220000000000000001 /* KeyCalloutBubbleView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = KeyCalloutBubbleView.swift; sourceTree = "<group>"; };
		B20000230000000000000001 /* KeyGridView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = KeyGridView.swift; sourceTree = "<group>"; };
		B20000240000000000000001 /* CandidateBarView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CandidateBarView.swift; sourceTree = "<group>"; };
		B20000250000000000000001 /* EmojiKeyboardView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = EmojiKeyboardView.swift; sourceTree = "<group>"; };
		B20000260000000000000001 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		B20000270000000000000001 /* LokeyKeyboard.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = LokeyKeyboard.entitlements; sourceTree = "<group>"; };
		B20000280000000000000001 /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };

		B20000400000000000000001 /* LokeyAuditTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LokeyAuditTests.swift; sourceTree = "<group>"; };
		B20000410000000000000001 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };

		B20000900000000000000001 /* AuditDemoApp.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AuditDemoApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
		B20000910000000000000001 /* LokeyKeyboard.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = LokeyKeyboard.appex; sourceTree = BUILT_PRODUCTS_DIR; };
		B20000920000000000000001 /* LokeyAuditTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = LokeyAuditTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		B40000010000000000000001 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B40000020000000000000001 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B40000030000000000000001 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		B50000010000000000000001 = {
			isa = PBXGroup;
			children = (
				B50000020000000000000001 /* AuditDemoApp */,
				B50000030000000000000001 /* Shared */,
				B50000060000000000000001 /* KeyboardExtension */,
				B50000080000000000000001 /* LokeyAuditTests */,
				B50000090000000000000001 /* Products */,
			);
			sourceTree = "<group>";
		};
		B50000020000000000000001 /* AuditDemoApp */ = {
			isa = PBXGroup;
			children = (
				B20000010000000000000001 /* AuditDemoApp.swift */,
				B20000020000000000000001 /* ContentView.swift */,
				B20000030000000000000001 /* Assets.xcassets */,
				B20000040000000000000001 /* Info.plist */,
				B20000050000000000000001 /* AuditDemoApp.entitlements */,
				B20000060000000000000001 /* PrivacyInfo.xcprivacy */,
			);
			path = AuditDemoApp;
			sourceTree = "<group>";
		};
		B50000030000000000000001 /* Shared */ = {
			isa = PBXGroup;
			children = (
				B50000040000000000000001 /* Engine */,
				B50000050000000000000001 /* Resources */,
			);
			path = Shared;
			sourceTree = "<group>";
		};
		B50000040000000000000001 /* Engine */ = {
			isa = PBXGroup;
			children = (
				B20000100000000000000001 /* LokeySettings.swift */,
				B20000110000000000000001 /* SpatialTouchModel.swift */,
				B20000120000000000000001 /* MmapLexicon.swift */,
				B20000130000000000000001 /* PinyinSyllableAutomaton.swift */,
				B20000140000000000000001 /* UserLexiconStore.swift */,
				B20000150000000000000001 /* ViterbiDecoder.swift */,
				B20000160000000000000001 /* LokeySessionController.swift */,
				B20000190000000000000001 /* NeuralSentenceScorer.swift */,
				B200001B0000000000000001 /* LokeyDiagnosticLogger.swift */,
				B200001C0000000000000001 /* NoisyChannelRefiner.swift */,
				B200001D0000000000000001 /* OpenCCConverter.swift */,
				B200001E0000000000000001 /* RimeUserLexiconImporter.swift */,
			);
			path = Engine;
			sourceTree = "<group>";
		};
		B50000050000000000000001 /* Resources */ = {
			isa = PBXGroup;
			children = (
				B20000180000000000000001 /* demo_lexicon.bin */,
				B200001A0000000000000001 /* lokey_emoji.bin */,
				B200002C0000000000000001 /* lokey_opencc.bin */,
			);
			path = Resources;
			sourceTree = "<group>";
		};
		B50000060000000000000001 /* KeyboardExtension */ = {
			isa = PBXGroup;
			children = (
				B20000200000000000000001 /* KeyboardViewController.swift */,
				B50000070000000000000001 /* UI */,
				B20000260000000000000001 /* Info.plist */,
				B20000270000000000000001 /* LokeyKeyboard.entitlements */,
				B20000280000000000000001 /* PrivacyInfo.xcprivacy */,
			);
			path = KeyboardExtension;
			sourceTree = "<group>";
		};
		B50000070000000000000001 /* UI */ = {
			isa = PBXGroup;
			children = (
				B20000210000000000000001 /* KeyboardTheme.swift */,
				B20000220000000000000001 /* KeyCalloutBubbleView.swift */,
				B20000230000000000000001 /* KeyGridView.swift */,
				B20000240000000000000001 /* CandidateBarView.swift */,
				B20000250000000000000001 /* EmojiKeyboardView.swift */,
			);
			path = UI;
			sourceTree = "<group>";
		};
		B50000080000000000000001 /* LokeyAuditTests */ = {
			isa = PBXGroup;
			children = (
				B20000400000000000000001 /* LokeyAuditTests.swift */,
				B20000410000000000000001 /* Info.plist */,
			);
			path = LokeyAuditTests;
			sourceTree = "<group>";
		};
		B50000090000000000000001 /* Products */ = {
			isa = PBXGroup;
			children = (
				B20000900000000000000001 /* AuditDemoApp.app */,
				B20000910000000000000001 /* LokeyKeyboard.appex */,
				B20000920000000000000001 /* LokeyAuditTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		B60000010000000000000001 /* AuditDemoApp */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = B90000020000000000000001 /* Build configuration list for PBXNativeTarget "AuditDemoApp" */;
			buildPhases = (
				B70000010000000000000001 /* Sources */,
				B40000010000000000000001 /* Frameworks */,
				B71000010000000000000001 /* Resources */,
				B72000010000000000000001 /* Copy demo_lexicon.bin as lokey_lexicon.bin */,
				B45000010000000000000001 /* Embed App Extensions */,
			);
			buildRules = (
			);
			dependencies = (
				B65000010000000000000001 /* PBXTargetDependency */,
			);
			name = AuditDemoApp;
			productName = AuditDemoApp;
			productReference = B20000900000000000000001 /* AuditDemoApp.app */;
			productType = "com.apple.product-type.application";
		};
		B60000020000000000000001 /* LokeyKeyboard */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = B90000030000000000000001 /* Build configuration list for PBXNativeTarget "LokeyKeyboard" */;
			buildPhases = (
				B70000020000000000000001 /* Sources */,
				B40000020000000000000001 /* Frameworks */,
				B71000020000000000000001 /* Resources */,
				B72000020000000000000001 /* Copy demo_lexicon.bin as lokey_lexicon.bin */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = LokeyKeyboard;
			productName = LokeyKeyboard;
			productReference = B20000910000000000000001 /* LokeyKeyboard.appex */;
			productType = "com.apple.product-type.app-extension";
		};
		B60000030000000000000001 /* LokeyAuditTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = B90000040000000000000001 /* Build configuration list for PBXNativeTarget "LokeyAuditTests" */;
			buildPhases = (
				B70000030000000000000001 /* Sources */,
				B40000030000000000000001 /* Frameworks */,
				B71000030000000000000001 /* Resources */,
				B72000030000000000000001 /* Copy demo_lexicon.bin as lokey_lexicon.bin */,
			);
			buildRules = (
			);
			dependencies = (
				B65000020000000000000001 /* PBXTargetDependency */,
			);
			name = LokeyAuditTests;
			productName = LokeyAuditTests;
			productReference = B20000920000000000000001 /* LokeyAuditTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		B80000010000000000000001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {
					B60000010000000000000001 = {
						CreatedOnToolsVersion = 16.0;
					};
					B60000020000000000000001 = {
						CreatedOnToolsVersion = 16.0;
					};
					B60000030000000000000001 = {
						CreatedOnToolsVersion = 16.0;
						TestTargetID = B60000010000000000000001;
					};
				};
			};
			buildConfigurationList = B90000010000000000000001 /* Build configuration list for PBXProject "LokeyAudit" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = zh_CN;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				zh_CN,
				Base,
			);
			mainGroup = B50000010000000000000001;
			productRefGroup = B50000090000000000000001 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				B60000010000000000000001 /* AuditDemoApp */,
				B60000020000000000000001 /* LokeyKeyboard */,
				B60000030000000000000001 /* LokeyAuditTests */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		B71000010000000000000001 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				B10000030000000000000001 /* Assets.xcassets in Resources */,
				B10000050000000000000001 /* lokey_opencc.bin in Resources */,
				B10000060000000000000001 /* PrivacyInfo.xcprivacy in Resources */,
				B10000070000000000000001 /* lokey_emoji.bin in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B71000020000000000000001 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				B100002F0000000000000001 /* lokey_emoji.bin in Resources */,
				B100006C0000000000000001 /* lokey_opencc.bin in Resources */,
				B100006E0000000000000001 /* PrivacyInfo.xcprivacy in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B71000030000000000000001 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				B10000510000000000000001 /* lokey_emoji.bin in Resources */,
				B100006D0000000000000001 /* lokey_opencc.bin in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
		B72000010000000000000001 /* Copy demo_lexicon.bin as lokey_lexicon.bin */ = {
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
				"$(SRCROOT)/Shared/Resources/demo_lexicon.bin",
			);
			name = "Copy demo_lexicon.bin as lokey_lexicon.bin";
			outputPaths = (
				"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/lokey_lexicon.bin",
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "mkdir -p \"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}\"\ncp -f \"${SRCROOT}/Shared/Resources/demo_lexicon.bin\" \"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/lokey_lexicon.bin\"\n";
		};
		B72000020000000000000001 /* Copy demo_lexicon.bin as lokey_lexicon.bin */ = {
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
				"$(SRCROOT)/Shared/Resources/demo_lexicon.bin",
			);
			name = "Copy demo_lexicon.bin as lokey_lexicon.bin";
			outputPaths = (
				"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/lokey_lexicon.bin",
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "mkdir -p \"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}\"\ncp -f \"${SRCROOT}/Shared/Resources/demo_lexicon.bin\" \"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/lokey_lexicon.bin\"\n";
		};
		B72000030000000000000001 /* Copy demo_lexicon.bin as lokey_lexicon.bin */ = {
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
				"$(SRCROOT)/Shared/Resources/demo_lexicon.bin",
			);
			name = "Copy demo_lexicon.bin as lokey_lexicon.bin";
			outputPaths = (
				"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/lokey_lexicon.bin",
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "mkdir -p \"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}\"\ncp -f \"${SRCROOT}/Shared/Resources/demo_lexicon.bin\" \"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/lokey_lexicon.bin\"\n";
		};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		B70000010000000000000001 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				B10000010000000000000001 /* AuditDemoApp.swift in Sources */,
				B10000020000000000000001 /* ContentView.swift in Sources */,
				B10000100000000000000001 /* LokeySettings.swift in Sources */,
				B10000110000000000000001 /* SpatialTouchModel.swift in Sources */,
				B10000120000000000000001 /* MmapLexicon.swift in Sources */,
				B10000130000000000000001 /* PinyinSyllableAutomaton.swift in Sources */,
				B10000140000000000000001 /* UserLexiconStore.swift in Sources */,
				B10000150000000000000001 /* ViterbiDecoder.swift in Sources */,
				B10000160000000000000001 /* LokeySessionController.swift in Sources */,
				B10000170000000000000001 /* NeuralSentenceScorer.swift in Sources */,
				B10000180000000000000001 /* LokeyDiagnosticLogger.swift in Sources */,
				B10000190000000000000001 /* NoisyChannelRefiner.swift in Sources */,
				B100001A0000000000000001 /* OpenCCConverter.swift in Sources */,
				B100001B0000000000000001 /* RimeUserLexiconImporter.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B70000020000000000000001 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				B10000200000000000000001 /* LokeySettings.swift in Sources */,
				B10000210000000000000001 /* SpatialTouchModel.swift in Sources */,
				B10000220000000000000001 /* MmapLexicon.swift in Sources */,
				B10000230000000000000001 /* PinyinSyllableAutomaton.swift in Sources */,
				B10000240000000000000001 /* UserLexiconStore.swift in Sources */,
				B10000250000000000000001 /* ViterbiDecoder.swift in Sources */,
				B10000260000000000000001 /* LokeySessionController.swift in Sources */,
				B100002E0000000000000001 /* NeuralSentenceScorer.swift in Sources */,
				B10000310000000000000001 /* LokeyDiagnosticLogger.swift in Sources */,
				B10000320000000000000001 /* NoisyChannelRefiner.swift in Sources */,
				B10000330000000000000001 /* OpenCCConverter.swift in Sources */,
				B10000270000000000000001 /* KeyboardViewController.swift in Sources */,
				B10000280000000000000001 /* KeyboardTheme.swift in Sources */,
				B10000290000000000000001 /* KeyCalloutBubbleView.swift in Sources */,
				B100002A0000000000000001 /* KeyGridView.swift in Sources */,
				B100002B0000000000000001 /* CandidateBarView.swift in Sources */,
				B100002C0000000000000001 /* EmojiKeyboardView.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B70000030000000000000001 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				B10000400000000000000001 /* LokeyAuditTests.swift in Sources */,
				B10000420000000000000001 /* KeyboardViewController.swift in Sources */,
				B10000430000000000000001 /* KeyboardTheme.swift in Sources */,
				B10000440000000000000001 /* KeyCalloutBubbleView.swift in Sources */,
				B10000450000000000000001 /* KeyGridView.swift in Sources */,
				B10000460000000000000001 /* CandidateBarView.swift in Sources */,
				B10000470000000000000001 /* EmojiKeyboardView.swift in Sources */,
				B10000480000000000000001 /* LokeySettings.swift in Sources */,
				B10000490000000000000001 /* SpatialTouchModel.swift in Sources */,
				B100004A0000000000000001 /* MmapLexicon.swift in Sources */,
				B100004B0000000000000001 /* PinyinSyllableAutomaton.swift in Sources */,
				B100004C0000000000000001 /* UserLexiconStore.swift in Sources */,
				B100004D0000000000000001 /* ViterbiDecoder.swift in Sources */,
				B100004E0000000000000001 /* LokeySessionController.swift in Sources */,
				B100004F0000000000000001 /* NeuralSentenceScorer.swift in Sources */,
				B10000520000000000000001 /* LokeyDiagnosticLogger.swift in Sources */,
				B10000530000000000000001 /* NoisyChannelRefiner.swift in Sources */,
				B10000540000000000000001 /* OpenCCConverter.swift in Sources */,
				B10000550000000000000001 /* RimeUserLexiconImporter.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		B65000010000000000000001 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = B60000020000000000000001 /* LokeyKeyboard */;
			targetProxy = B30000010000000000000001 /* PBXContainerItemProxy */;
		};
		B65000020000000000000001 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = B60000010000000000000001 /* AuditDemoApp */;
			targetProxy = B30000020000000000000001 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		BA0000010000000000000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1";
			};
			name = Debug;
		};
		BA0000020000000000000001 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1";
				VALIDATE_PRODUCT = YES;
			};
			name = Release;
		};
		BA0000110000000000000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = AuditDemoApp/AuditDemoApp.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 87;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = AuditDemoApp/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 0.9.5;
				OTHER_LDFLAGS = "-lsqlite3";
				PRODUCT_BUNDLE_IDENTIFIER = com.kianuni.lokey.audit;
				PRODUCT_NAME = "$(TARGET_NAME)";
			};
			name = Debug;
		};
		BA0000120000000000000001 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = AuditDemoApp/AuditDemoApp.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 87;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = AuditDemoApp/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 0.9.5;
				OTHER_LDFLAGS = "-lsqlite3";
				PRODUCT_BUNDLE_IDENTIFIER = com.kianuni.lokey.audit;
				PRODUCT_NAME = "$(TARGET_NAME)";
			};
			name = Release;
		};
		BA0000210000000000000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				APPLICATION_EXTENSION_API_ONLY = YES;
				CODE_SIGN_ENTITLEMENTS = KeyboardExtension/LokeyKeyboard.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 87;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = KeyboardExtension/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@executable_path/../../Frameworks",
				);
				MARKETING_VERSION = 0.9.5;
				OTHER_LDFLAGS = "-lsqlite3";
				PRODUCT_BUNDLE_IDENTIFIER = com.kianuni.lokey.audit.keyboard;
				PRODUCT_NAME = LokeyKeyboard;
				SKIP_INSTALL = YES;
			};
			name = Debug;
		};
		BA0000220000000000000001 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				APPLICATION_EXTENSION_API_ONLY = YES;
				CODE_SIGN_ENTITLEMENTS = KeyboardExtension/LokeyKeyboard.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 87;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = KeyboardExtension/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@executable_path/../../Frameworks",
				);
				MARKETING_VERSION = 0.9.5;
				OTHER_LDFLAGS = "-lsqlite3";
				PRODUCT_BUNDLE_IDENTIFIER = com.kianuni.lokey.audit.keyboard;
				PRODUCT_NAME = LokeyKeyboard;
				SKIP_INSTALL = YES;
			};
			name = Release;
		};
		BA0000310000000000000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 87;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = LokeyAuditTests/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 0.9.5;
				OTHER_LDFLAGS = "-lsqlite3";
				PRODUCT_BUNDLE_IDENTIFIER = com.kianuni.lokey.audit.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/AuditDemoApp.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/AuditDemoApp";
			};
			name = Debug;
		};
		BA0000320000000000000001 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 87;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = LokeyAuditTests/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 0.9.5;
				OTHER_LDFLAGS = "-lsqlite3";
				PRODUCT_BUNDLE_IDENTIFIER = com.kianuni.lokey.audit.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/AuditDemoApp.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/AuditDemoApp";
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		B90000010000000000000001 /* Build configuration list for PBXProject "LokeyAudit" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				BA0000010000000000000001 /* Debug */,
				BA0000020000000000000001 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		B90000020000000000000001 /* Build configuration list for PBXNativeTarget "AuditDemoApp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				BA0000110000000000000001 /* Debug */,
				BA0000120000000000000001 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		B90000030000000000000001 /* Build configuration list for PBXNativeTarget "LokeyKeyboard" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				BA0000210000000000000001 /* Debug */,
				BA0000220000000000000001 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		B90000040000000000000001 /* Build configuration list for PBXNativeTarget "LokeyAuditTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				BA0000310000000000000001 /* Debug */,
				BA0000320000000000000001 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = B80000010000000000000001 /* Project object */;
}
"""
    (proj_dir / "project.pbxproj").write_text(pbx, encoding="utf-8")

    schemes_dir = proj_dir / "xcshareddata" / "xcschemes"
    schemes_dir.mkdir(parents=True, exist_ok=True)
    scheme_xml = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "B60000010000000000000001"
               BuildableName = "AuditDemoApp.app"
               BlueprintName = "AuditDemoApp"
               ReferencedContainer = "container:LokeyAudit.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "B60000030000000000000001"
               BuildableName = "LokeyAuditTests.xctest"
               BlueprintName = "LokeyAuditTests"
               ReferencedContainer = "container:LokeyAudit.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "B60000010000000000000001"
            BuildableName = "AuditDemoApp.app"
            BlueprintName = "AuditDemoApp"
            ReferencedContainer = "container:LokeyAudit.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "B60000010000000000000001"
            BuildableName = "AuditDemoApp.app"
            BlueprintName = "AuditDemoApp"
            ReferencedContainer = "container:LokeyAudit.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    (schemes_dir / "LokeyAudit.xcscheme").write_text(scheme_xml, encoding="utf-8")
    print("Generated Assets.xcassets and LokeyAudit.xcodeproj successfully.")


if __name__ == "__main__":
    generate_assets()
    generate_pbxproj()
