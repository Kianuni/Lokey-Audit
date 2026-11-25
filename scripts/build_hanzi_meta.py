#!/usr/bin/env python3
"""
Builds `Shared/Resources/lokey_hanzi_meta.bin` (`LKHM` v1, ~80 KB) offline from
`Unihan.zip`.

Binary format (`LKHM` v1, little-endian):
- Header (16 bytes):
    magic           : 4B  b"LKHM"
    version         : u16 1
    start_cp        : u16 0x4E00
    char_count      : u32 20992  (U+4E00 .. U+9FFF inclusive)
    radical_count   : u16 N      (1-based radical IDs 1..N; 0 = unknown)
    syllable_count  : u16 M      (number of indexed toneless Pinyin syllables; 0 if omitted)
- Radical Label Table:
    offsets         : (N + 1) * u16 byte offsets into UTF-8 label blob (padded to 2-byte alignment)
    utf8_blob       : concatenated UTF-8 display labels (e.g. "亻", "氵", "艹", "扌", "礻", "钅", ...)
- Character Table (2-byte aligned):
    20992 * 2 bytes : (radical_id: u8, total_strokes: u8) for U+4E00 .. U+9FFF
- Syllable Inverted Index (present when `syllable_count > 0`, 4-byte aligned before u32 offsets):
    syl_offsets     : (M + 1) * u16 byte offsets into `syl_blob` (sorted lexicographically by ASCII syllable)
    syl_blob        : concatenated ASCII syllable strings (`ü` normalized to `v`: `nv`, `lv`, `nve`, `lve`), padded to 4B
    post_offsets    : (M + 1) * u32 element offsets into `post_codepoints`
    post_codepoints : K * u16 BMP codepoints (`0x4E00 .. 0x9FFF`), `kTGHZ2013` (8,105-char Table of General Standard Chinese Characters) ranked first
"""
from __future__ import annotations

import argparse
import re
import struct
import unicodedata
import zipfile
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_MAIN = ROOT / "Shared" / "Resources" / "lokey_hanzi_meta.bin"


def resolve_unihan_zip(explicit: Path | None = None) -> Path:
    if explicit is not None:
        return explicit
    candidates = [
        ROOT / "vendor" / "permissive" / "unihan" / "Unihan.zip",
        ROOT.parent / "Lokey" / "vendor" / "permissive" / "unihan" / "Unihan.zip",
        Path.home() / ".cache" / "lokey-audit" / "permissive" / "unihan" / "Unihan.zip",
    ]
    for cand in candidates:
        if cand.exists():
            return cand
    return candidates[0]

START_CP = 0x4E00
END_CP = 0x9FFF
CHAR_COUNT = END_CP - START_CP + 1  # 20,992

KANGXI_TO_LABEL: dict[int, str] = {
    1: "一", 2: "丨", 3: "丶", 4: "丿", 5: "乙", 6: "亅",
    7: "二", 8: "亠", 9: "亻", 10: "儿", 11: "入", 12: "八",
    13: "冂", 14: "冖", 15: "冫", 16: "几", 17: "凵", 18: "刂",
    19: "力", 20: "勹", 21: "匕", 22: "匚", 23: "匚", 24: "十",
    25: "卜", 26: "卩", 27: "厂", 28: "厶", 29: "又", 30: "口",
    31: "囗", 32: "土", 33: "士", 34: "夂", 35: "夂", 36: "夕",
    37: "大", 38: "女", 39: "子", 40: "宀", 41: "寸", 42: "小",
    43: "尤", 44: "尸", 45: "屮", 46: "山", 47: "川", 48: "工",
    49: "己", 50: "巾", 51: "干", 52: "幺", 53: "广", 54: "廴",
    55: "廾", 56: "弋", 57: "弓", 58: "彐", 59: "彡", 60: "彳",
    61: "忄", 62: "戈", 63: "户", 64: "扌", 65: "支", 66: "攵",
    67: "文", 68: "斗", 69: "斤", 70: "方", 71: "无", 72: "日",
    73: "曰", 74: "月", 75: "木", 76: "欠", 77: "止", 78: "歹",
    79: "殳", 80: "母", 81: "比", 82: "毛", 83: "氏", 84: "气",
    85: "氵", 86: "火", 87: "爪", 88: "父", 89: "爻", 90: "爿",
    91: "片", 92: "牙", 93: "牛", 94: "犭", 95: "玄", 96: "王",
    97: "瓜", 98: "瓦", 99: "甘", 100: "生", 101: "用", 102: "田",
    103: "疋", 104: "疒", 105: "癶", 106: "白", 107: "皮", 108: "皿",
    109: "目", 110: "矛", 111: "矢", 112: "石", 113: "礻", 114: "禸",
    115: "禾", 116: "穴", 117: "立", 118: "竹", 119: "米", 120: "纟",
    121: "缶", 122: "罒", 123: "羊", 124: "羽", 125: "老", 126: "而",
    127: "耒", 128: "耳", 129: "聿", 130: "月", 131: "臣", 132: "自",
    133: "至", 134: "臼", 135: "舌", 136: "舛", 137: "舟", 138: "艮",
    139: "色", 140: "艹", 141: "虍", 142: "虫", 143: "血", 144: "行",
    145: "衤", 146: "西", 147: "见", 148: "角", 149: "讠", 150: "谷",
    151: "豆", 152: "豕", 153: "豸", 154: "贝", 155: "赤", 156: "走",
    157: "足", 158: "身", 159: "车", 160: "辛", 161: "辰", 162: "辶",
    163: "阝", 164: "酉", 165: "采", 166: "里", 167: "钅", 168: "长",
    169: "门", 170: "阝", 171: "隶", 172: "隹", 173: "雨", 174: "青",
    175: "非", 176: "面", 177: "革", 178: "韦", 179: "韭", 180: "音",
    181: "页", 182: "风", 183: "飞", 184: "饣", 185: "首", 186: "香",
    187: "马", 188: "骨", 189: "高", 190: "髟", 191: "斗", 192: "鬯",
    193: "鬲", 194: "鬼", 195: "鱼", 196: "鸟", 197: "卤", 198: "鹿",
    199: "麦", 200: "麻", 201: "黄", 202: "黍", 203: "黑", 204: "黹",
    205: "黾", 206: "鼎", 207: "鼓", 208: "鼠", 209: "鼻", 210: "齐",
    211: "齿", 212: "龙", 213: "龟", 214: "龠",
}

RS_TOKEN_RE = re.compile(r"^(\d+)('{0,3})\.(-?\d+)$")


def normalize_toneless_pinyin(raw: str) -> str | None:
    s = raw.strip().lower()
    if not s:
        return None
    nfd = unicodedata.normalize("NFD", s)
    out = []
    i = 0
    while i < len(nfd):
        ch = nfd[i]
        # u + combining diaeresis (U+0308) -> 'v'
        if ch == "u" and i + 1 < len(nfd) and ord(nfd[i + 1]) == 0x0308:
            out.append("v")
            i += 2
            continue
        if unicodedata.category(ch) == "Mn":
            i += 1
            continue
        if "a" <= ch <= "z":
            out.append(ch)
        i += 1
    clean = "".join(out)
    if not clean:
        return None
    # Normalize ju/qu/xu/yu with v -> u (only n/l keep v: nv, lv, nve, lve)
    if clean.startswith(("jv", "qv", "xv", "yv")):
        clean = clean[0] + "u" + clean[2:]
    return clean if (1 <= len(clean) <= 6 and clean != "ng" and clean != "hm" and clean != "hng") else None


def build_binary(unihan_zip: Path | None = None) -> bytes:
    zip_path = resolve_unihan_zip(unihan_zip)
    ordered_labels: list[str] = []
    label_to_id: dict[str, int] = {}
    for kx in range(1, 215):
        lbl = KANGXI_TO_LABEL[kx]
        if lbl not in label_to_id:
            ordered_labels.append(lbl)
            label_to_id[lbl] = len(ordered_labels)  # 1-based

    rad_ids = [0] * CHAR_COUNT
    strokes = [0] * CHAR_COUNT
    has_g_source = [False] * CHAR_COUNT
    has_simp_variant = [False] * CHAR_COUNT
    tghz_syls: dict[int, list[str]] = defaultdict(list)
    xhc_syls: dict[int, list[str]] = defaultdict(list)
    mandarin_syls: dict[int, list[str]] = defaultdict(list)

    with zipfile.ZipFile(zip_path, "r") as zf:
        irg_lines = zf.read("Unihan_IRGSources.txt").decode("utf-8").splitlines()
        reading_lines = zf.read("Unihan_Readings.txt").decode("utf-8").splitlines()
        variant_lines = zf.read("Unihan_Variants.txt").decode("utf-8").splitlines()

    for line in irg_lines:
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3 or not parts[0].startswith("U+"):
            continue
        cp = int(parts[0][2:], 16)
        if cp < START_CP or cp > END_CP:
            continue
        idx = cp - START_CP
        field, val = parts[1], parts[2].strip()
        if field == "kRSUnicode":
            tokens = val.split()
            chosen_kx = None
            for tok in tokens:
                m = RS_TOKEN_RE.match(tok)
                if not m:
                    continue
                kx_num = int(m.group(1))
                is_simp = bool(m.group(2))
                if chosen_kx is None or is_simp:
                    chosen_kx = kx_num
            if chosen_kx and chosen_kx in KANGXI_TO_LABEL:
                rad_ids[idx] = label_to_id[KANGXI_TO_LABEL[chosen_kx]]
        elif field == "kTotalStrokes":
            first_tok = val.split()[0]
            if first_tok.isdigit():
                strokes[idx] = min(63, max(1, int(first_tok)))
        elif field == "kIRG_GSource":
            has_g_source[idx] = True

    for line in variant_lines:
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 3 and parts[0].startswith("U+") and parts[1] == "kSimplifiedVariant":
            cp = int(parts[0][2:], 16)
            if START_CP <= cp <= END_CP:
                # True if every listed simplified variant differs from `cp` itself
                targets = [int(t[2:].split("<")[0], 16) for t in parts[2].split() if t.startswith("U+")]
                if targets and cp not in targets:
                    has_simp_variant[cp - START_CP] = True

    for line in reading_lines:
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3 or not parts[0].startswith("U+"):
            continue
        cp = int(parts[0][2:], 16)
        if cp < START_CP or cp > END_CP:
            continue
        field, val = parts[1], parts[2].strip()
        if field == "kTGHZ2013":
            for entry in val.split():
                raw_py = entry.split(":")[-1]
                for sub in raw_py.split(","):
                    norm = normalize_toneless_pinyin(sub)
                    if norm and norm not in tghz_syls[cp]:
                        tghz_syls[cp].append(norm)
        elif field == "kXHC1983":
            for entry in val.split():
                raw_py = entry.split(":")[-1]
                for sub in raw_py.split(","):
                    norm = normalize_toneless_pinyin(sub)
                    if norm and norm not in xhc_syls[cp]:
                        xhc_syls[cp].append(norm)
        elif field == "kMandarin":
            for sub in val.split():
                norm = normalize_toneless_pinyin(sub)
                if norm and norm not in mandarin_syls[cp]:
                    mandarin_syls[cp].append(norm)

    # Build syllable -> [(tier, strokes, cp)]
    # Tier 0: Official 8,105-character `kTGHZ2013` (includes `祎`, `鋆`, `镕`, `喆`, `淼`, `垚`, `煊`, `瑄`, `璟`...)
    # Tier 1: `kXHC1983` (Xiandai Hanyu Cidian) non-traditional characters
    # Tier 2: Other Mainland `kIRG_GSource` characters without a distinct simplified replacement
    syl_postings: dict[str, list[tuple[int, int, int]]] = defaultdict(list)
    for idx in range(CHAR_COUNT):
        cp = START_CP + idx
        st = strokes[idx] if strokes[idx] > 0 else 99
        if cp in tghz_syls:
            for syl in tghz_syls[cp]:
                syl_postings[syl].append((0, st, cp))
        elif cp in xhc_syls and not has_simp_variant[idx]:
            for syl in xhc_syls[cp]:
                syl_postings[syl].append((1, st, cp))
        elif cp in mandarin_syls and has_g_source[idx] and not has_simp_variant[idx]:
            for syl in mandarin_syls[cp]:
                syl_postings[syl].append((2, st, cp))

    sorted_syllables = sorted(syl_postings.keys())
    syl_offsets = [0]
    syl_blob = bytearray()
    post_offsets = [0]
    post_cps: list[int] = []

    for syl in sorted_syllables:
        enc = syl.encode("ascii")
        syl_blob.extend(enc)
        syl_offsets.append(len(syl_blob))
        items = sorted(syl_postings[syl])
        seen_cp = set()
        for _, _, cp in items:
            if cp not in seen_cp:
                seen_cp.add(cp)
                post_cps.append(cp)
        post_offsets.append(len(post_cps))

    offsets = [0]
    blob = bytearray()
    for lbl in ordered_labels:
        enc = lbl.encode("utf-8")
        blob.extend(enc)
        offsets.append(len(blob))

    header = struct.pack(
        "<4sHHIHH",
        b"LKHM",
        1,
        START_CP,
        CHAR_COUNT,
        len(ordered_labels),
        len(sorted_syllables),
    )
    offset_bytes = struct.pack(f"<{len(offsets)}H", *offsets)
    if len(blob) % 2 == 1:
        blob.append(0)

    char_bytes = bytearray(CHAR_COUNT * 2)
    for i in range(CHAR_COUNT):
        char_bytes[i * 2] = rad_ids[i]
        char_bytes[i * 2 + 1] = strokes[i]

    prefix = header + offset_bytes + bytes(blob) + bytes(char_bytes)
    syl_offset_bytes = struct.pack(f"<{len(syl_offsets)}H", *syl_offsets)
    cur_len = len(prefix) + len(syl_offset_bytes) + len(syl_blob)
    if cur_len % 4 != 0:
        syl_blob.extend(b"\x00" * (4 - (cur_len % 4)))

    post_offset_bytes = struct.pack(f"<{len(post_offsets)}I", *post_offsets)
    post_cp_bytes = struct.pack(f"<{len(post_cps)}H", *post_cps)

    total_payload = prefix + syl_offset_bytes + bytes(syl_blob) + post_offset_bytes + post_cp_bytes
    filled = sum(1 for r, s in zip(rad_ids, strokes) if r > 0 and s > 0)
    print(
        f"Built LKHM v1: {CHAR_COUNT} CJK chars ({filled} with radical+strokes), "
        f"{len(ordered_labels)} radicals, {len(sorted_syllables)} syllables, "
        f"{len(post_cps)} syllable-char postings, total {len(total_payload)} bytes"
    )
    return total_payload


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Shared/Resources/lokey_hanzi_meta.bin (LKHM v1) offline.")
    parser.add_argument("--unihan-zip", type=Path, default=None, help="Path to Unihan.zip")
    parser.add_argument("-o", "--output", type=Path, default=OUT_MAIN, help="Output binary path")
    args = parser.parse_args()

    payload = build_binary(args.unihan_zip)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(payload)
    print(f"Wrote {args.output} ({len(payload)} bytes)")


if __name__ == "__main__":
    main()
