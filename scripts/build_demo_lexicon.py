#!/usr/bin/env python3
"""
Self-contained Permissive Demo Lexicon Compiler for Lokey-Audit.

Generates minimal, 100% GPL-free binary assets in `Shared/Resources/`:
  1. `demo_lexicon.bin` (`LKLF-v2` + un-tuned neutral `LNLM-v2`, ~3,500–4,500 entries,
     all 416 canonical Mandarin syllables, basic English, clean next-word associations,
     zero `=` spoken-reading entries, zero `target-deltas.tsv`/`commit-deltas.tsv`).
  2. `lokey_emoji.bin` (`LEMJ-v1`, ~60–100 common emoji keywords).
  3. `lokey_opencc.bin` (`LOCC-v1`, ~250–600 essential OpenCC mappings).

Sources (strictly permissive):
  - rime/rime-pinyin-simp (Apache-2.0)
  - Unicode Unihan_Readings.txt (Unicode-3.0)
  - BYVoid/OpenCC (Apache-2.0)
  - Unicode CLDR zh.xml (Unicode-3.0)
"""

from __future__ import annotations

import argparse
import hashlib
import math
import re
import struct
import sys
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

LKLF_MAGIC = 0x464C4B4C  # "LKLF"
LNLM_MAGIC = 0x4D4C4E4C  # "LNLM"
LEMJ_MAGIC = 0x4A4D454C  # "LEMJ"
LOCC_MAGIC = 0x43434F4C  # "LOCC"

LNLM_DIM = 32
NORM_Z = 2.65e8

SYLLABLE_RE = re.compile(r"^[a-z]{1,7}$")

INVALID_NON_MANDARIN_SYLLABLES = frozenset({
    "azusawa", "chiaki", "chihara", "fujii", "fujita", "harase", "hasegawa",
    "hashimoto", "hayashi", "hiroi", "ishikawa", "ito", "junding", "kato",
    "kobayashi", "koichi", "konaka", "kyoko", "masuda", "matsumoto", "maya",
    "miki", "muneaki", "nakamura", "naruse", "oji", "okino", "saito", "sato",
    "shogo", "takahashi", "utano", "yamamoto", "yoko", "yutaka",
    "hm", "hng", "m", "n", "ng",
})

# Exact 416 canonical Mandarin syllables -> representative BMP Hanzi (Unicode-3.0 / pinyin_simp)
CANONICAL_416_SYLLABLE_SEED: Dict[str, str] = {
    "a": "啊", "ai": "爱", "an": "安", "ang": "昂", "ao": "奥",
    "ba": "把", "bai": "白", "ban": "办", "bang": "帮", "bao": "包",
    "bei": "北", "ben": "本", "beng": "蹦", "bi": "比", "bian": "变",
    "biao": "表", "bie": "别", "bin": "宾", "bing": "并", "bo": "波", "bu": "不",
    "ca": "擦", "cai": "才", "can": "参", "cang": "藏", "cao": "草",
    "ce": "测", "cen": "参", "ceng": "曾", "cha": "查", "chai": "拆",
    "chan": "产", "chang": "长", "chao": "超", "che": "车", "chen": "陈",
    "cheng": "成", "chi": "吃", "chong": "重", "chou": "抽", "chu": "出",
    "chua": "歘", "chuai": "揣", "chuan": "穿", "chuang": "窗", "chui": "吹",
    "chun": "春", "chuo": "戳", "ci": "次", "cong": "从", "cou": "凑",
    "cu": "粗", "cuan": "窜", "cui": "催", "cun": "存", "cuo": "错",
    "da": "大", "dai": "带", "dan": "但", "dang": "当", "dao": "到",
    "de": "的", "dei": "得", "den": "扽", "deng": "等", "di": "地",
    "dia": "嗲", "dian": "点", "diao": "掉", "die": "跌", "ding": "定",
    "diu": "丢", "dong": "东", "dou": "都", "du": "度", "duan": "段",
    "dui": "对", "dun": "顿", "duo": "多",
    "e": "饿", "ei": "诶", "en": "嗯", "eng": "鞥", "er": "而",
    "fa": "发", "fan": "反", "fang": "方", "fei": "飞", "fen": "分",
    "feng": "风", "fiao": "覅", "fo": "佛", "fou": "否", "fu": "服",
    "ga": "嘎", "gai": "该", "gan": "干", "gang": "刚", "gao": "高",
    "ge": "个", "gei": "给", "gen": "跟", "geng": "更", "gong": "工",
    "gou": "够", "gu": "古", "gua": "瓜", "guai": "怪", "guan": "关",
    "guang": "光", "gui": "归", "gun": "滚", "guo": "国",
    "ha": "哈", "hai": "还", "han": "汉", "hang": "行", "hao": "好",
    "he": "和", "hei": "黑", "hen": "很", "heng": "横", "hong": "红",
    "hou": "后", "hu": "和", "hua": "话", "huai": "坏", "huan": "换",
    "huang": "黄", "hui": "会", "hun": "混", "huo": "或",
    "ji": "及", "jia": "家", "jian": "见", "jiang": "将", "jiao": "教",
    "jie": "接", "jin": "今", "jing": "京", "jiong": "窘", "jiu": "就",
    "ju": "局", "juan": "卷", "jue": "觉", "jun": "军",
    "ka": "卡", "kai": "开", "kan": "看", "kang": "康", "kao": "考",
    "ke": "可", "kei": "剋", "ken": "肯", "keng": "坑", "kong": "空",
    "kou": "口", "ku": "库", "kua": "夸", "kuai": "快", "kuan": "宽",
    "kuang": "框", "kui": "亏", "kun": "困", "kuo": "扩",
    "la": "拉", "lai": "来", "lan": "蓝", "lang": "浪", "lao": "老",
    "le": "了", "lei": "类", "leng": "冷", "li": "里", "lia": "俩",
    "lian": "连", "liang": "两", "liao": "料", "lie": "列", "lin": "林",
    "ling": "零", "liu": "六", "lo": "咯", "long": "龙", "lou": "楼",
    "lu": "路", "luan": "乱", "lue": "略", "lun": "论", "luo": "落",
    "lv": "旅", "lve": "略",
    "ma": "吗", "mai": "买", "man": "满", "mang": "忙", "mao": "猫",
    "me": "么", "mei": "没", "men": "们", "meng": "梦", "mi": "米",
    "mian": "面", "miao": "秒", "mie": "灭", "min": "民", "ming": "明",
    "miu": "谬", "mo": "模", "mou": "某", "mu": "目",
    "na": "那", "nai": "奶", "nan": "南", "nang": "囊", "nao": "脑",
    "ne": "呢", "nei": "内", "nen": "嫩", "neng": "能", "ni": "你",
    "nian": "年", "niang": "娘", "niao": "鸟", "nie": "捏", "nin": "您",
    "ning": "宁", "niu": "牛", "nong": "农", "nou": "耨", "nu": "努",
    "nuan": "暖", "nue": "虐", "nun": "嫩", "nuo": "诺", "nv": "女",
    "nve": "虐",
    "o": "哦", "ou": "欧",
    "pa": "怕", "pai": "拍", "pan": "盘", "pang": "旁", "pao": "跑",
    "pei": "配", "pen": "盆", "peng": "朋", "pi": "批", "pian": "片",
    "piao": "票", "pie": "撇", "pin": "拼", "ping": "平", "po": "破",
    "pou": "剖", "pu": "普",
    "qi": "起", "qia": "恰", "qian": "前", "qiang": "强", "qiao": "桥",
    "qie": "切", "qin": "亲", "qing": "请", "qiong": "穷", "qiu": "球",
    "qu": "去", "quan": "全", "que": "确", "qun": "群",
    "ran": "然", "rang": "让", "rao": "扰", "re": "热", "ren": "人",
    "reng": "仍", "ri": "日", "rong": "容", "rou": "肉", "ru": "如",
    "rua": "挼", "ruan": "软", "rui": "瑞", "run": "润", "ruo": "若",
    "sa": "撒", "sai": "赛", "san": "三", "sang": "丧", "sao": "扫",
    "se": "色", "sei": "塞", "sen": "森", "seng": "僧", "sha": "沙",
    "shai": "晒", "shan": "山", "shang": "上", "shao": "少", "she": "设",
    "shei": "谁", "shen": "什", "sheng": "生", "shi": "是", "shou": "手",
    "shu": "书", "shua": "刷", "shuai": "帅", "shuan": "栓", "shuang": "双",
    "shui": "水", "shun": "顺", "shuo": "说", "si": "四", "song": "送",
    "sou": "搜", "su": "苏", "suan": "算", "sui": "岁", "sun": "孙",
    "suo": "所",
    "ta": "他", "tai": "太", "tan": "谈", "tang": "糖", "tao": "套",
    "te": "特", "tei": "忒", "teng": "疼", "ti": "题", "tian": "天",
    "tiao": "条", "tie": "贴", "ting": "听", "tong": "同", "tou": "头",
    "tu": "图", "tuan": "团", "tui": "推", "tun": "吞", "tuo": "托",
    "wa": "瓦", "wai": "外", "wan": "万", "wang": "网", "wei": "为",
    "wen": "文", "weng": "翁", "wo": "我", "wu": "无",
    "xi": "西", "xia": "下", "xian": "先", "xiang": "想", "xiao": "小",
    "xie": "写", "xin": "新", "xing": "行", "xiong": "兄", "xiu": "修",
    "xu": "需", "xuan": "选", "xue": "学", "xun": "训",
    "ya": "呀", "yan": "研", "yang": "样", "yao": "要", "ye": "也",
    "yi": "一", "yin": "音", "ying": "应", "yo": "哟", "yong": "用",
    "you": "有", "yu": "与", "yuan": "元", "yue": "月", "yun": "云",
    "za": "杂", "zai": "在", "zan": "赞", "zang": "脏", "zao": "早",
    "ze": "则", "zei": "贼", "zen": "怎", "zeng": "增", "zha": "查",
    "zhai": "摘", "zhan": "站", "zhang": "长", "zhao": "找", "zhe": "这",
    "zhei": "这", "zhen": "真", "zheng": "正", "zhi": "只", "zhong": "中",
    "zhou": "周", "zhu": "主", "zhua": "抓", "zhuai": "拽", "zhuan": "转",
    "zhuang": "装", "zhui": "追", "zhun": "准", "zhuo": "着", "zi": "字",
    "zong": "总", "zou": "走", "zu": "组", "zuan": "钻", "zui": "最",
    "zun": "尊", "zuo": "作",
}
assert len(CANONICAL_416_SYLLABLE_SEED) == 416

# Essential audit & demo phrases guaranteed to be present regardless of frequency cutoff
ESSENTIAL_DEMO_PHRASES: Dict[Tuple[str, Tuple[str, ...]], float] = {
    ("你好", ("ni", "hao")): 250_000.0,
    ("中国", ("zhong", "guo")): 450_000.0,
    ("拼音", ("pin", "yin")): 160_000.0,
    ("我们", ("wo", "men")): 520_000.0,
    ("你们", ("ni", "men")): 220_000.0,
    ("他们", ("ta", "men")): 240_000.0,
    ("今天", ("jin", "tian")): 320_000.0,
    ("明天", ("ming", "tian")): 260_000.0,
    ("昨天", ("zuo", "tian")): 180_000.0,
    ("现在", ("xian", "zai")): 340_000.0,
    ("上午", ("shang", "wu")): 140_000.0,
    ("中午", ("zhong", "wu")): 140_000.0,
    ("下午", ("xia", "wu")): 180_000.0,
    ("晚上", ("wan", "shang")): 190_000.0,
    ("有空", ("you", "kong")): 120_000.0,
    ("哪里", ("na", "li")): 180_000.0,
    ("去哪", ("qu", "na")): 110_000.0,
    ("去哪儿", ("qu", "na", "er")): 90_000.0,
    ("吃饭", ("chi", "fan")): 160_000.0,
    ("北京", ("bei", "jing")): 360_000.0,
    ("上海", ("shang", "hai")): 280_000.0,
    ("西安", ("xi", "an")): 220_000.0,
    ("天安门", ("tian", "an", "men")): 150_000.0,
    ("北京大学", ("bei", "jing", "da", "xue")): 140_000.0,
    ("学生", ("xue", "sheng")): 200_000.0,
    ("老师", ("lao", "shi")): 210_000.0,
    ("输入法", ("shu", "ru", "fa")): 220_000.0,
    ("谢谢", ("xie", "xie")): 260_000.0,
    ("没有", ("mei", "you")): 420_000.0,
    ("可以", ("ke", "yi")): 400_000.0,
    ("什么", ("shen", "me")): 390_000.0,
    ("这个", ("zhe", "ge")): 380_000.0,
    ("怎么", ("zen", "me")): 280_000.0,
    ("为什么", ("wei", "shen", "me")): 230_000.0,
    ("已经", ("yi", "jing")): 310_000.0,
    ("知道", ("zhi", "dao")): 300_000.0,
    ("人工智能", ("ren", "gong", "zhi", "neng")): 180_000.0,
    ("电脑", ("dian", "nao")): 190_000.0,
    ("手机", ("shou", "ji")): 240_000.0,
    ("软件", ("ruan", "jian")): 200_000.0,
    ("鼠标", ("shu", "biao")): 130_000.0,
    ("内存", ("nei", "cun")): 140_000.0,
    ("网络", ("wang", "luo")): 210_000.0,
    ("键盘", ("jian", "pan")): 160_000.0,
    ("头发", ("tou", "fa")): 140_000.0,
    ("发财", ("fa", "cai")): 120_000.0,
    ("皇后", ("huang", "hou")): 130_000.0,
    ("后面", ("hou", "mian")): 160_000.0,
    ("哈哈", ("ha", "ha")): 200_000.0,
    ("大哭", ("da", "ku")): 110_000.0,
    ("开心", ("kai", "xin")): 190_000.0,
    ("晚安", ("wan", "an")): 160_000.0,
    ("早安", ("zao", "an")): 140_000.0,
    ("女孩", ("nv", "hai")): 150_000.0,
    ("女生", ("nv", "sheng")): 150_000.0,
    ("男生", ("nan", "sheng")): 150_000.0,
    ("旅游", ("lv", "you")): 180_000.0,
    ("考虑", ("kao", "lv")): 170_000.0,
    ("一会儿", ("yi", "hui", "er")): 120_000.0,
    ("好的", ("hao", "de")): 280_000.0,
    ("谢谢你", ("xie", "xie", "ni")): 160_000.0,
    ("没问题", ("mei", "wen", "ti")): 170_000.0,
    ("一起", ("yi", "qi")): 270_000.0,
    ("工作", ("gong", "zuo")): 290_000.0,
    ("学习", ("xue", "xi")): 260_000.0,
    ("系统", ("xi", "tong")): 220_000.0,
    ("安全", ("an", "quan")): 210_000.0,
    ("隐私", ("yin", "si")): 160_000.0,
    ("离线", ("li", "xian")): 150_000.0,
    ("审计", ("shen", "ji")): 140_000.0,
    ("测试", ("ce", "shi")): 180_000.0,
    ("验证", ("yan", "zheng")): 150_000.0,
    ("大学", ("da", "xue")): 220_000.0,
    ("明天见", ("ming", "tian", "jian")): 160_000.0,
    ("很高兴", ("hen", "gao", "xing")): 140_000.0,
    ("不好意思", ("bu", "hao", "yi", "si")): 130_000.0,
    ("苹果", ("ping", "guo")): 190_000.0,
    ("开源", ("kai", "yuan")): 140_000.0,
}

# Clean basic English / mixed vocabulary (~140 entries)
BASIC_ENGLISH_WORDS: Dict[str, Tuple[str, int]] = {
    "about": ("about", -2050), "account": ("account", -2100), "action": ("action", -2100),
    "after": ("after", -2000), "again": ("again", -2050), "air": ("air", -2100),
    "airpods": ("AirPods", -1800), "algorithm": ("algorithm", -2150), "all": ("all", -1980),
    "already": ("already", -2100), "also": ("also", -2020), "always": ("always", -2080),
    "and": ("and", -1900), "android": ("Android", -1850), "api": ("API", -1750),
    "app": ("App", -1700), "apple": ("Apple", -1680), "appstore": ("App Store", -1720),
    "archive": ("archive", -2200), "audit": ("audit", -1850), "auto": ("auto", -2050),
    "back": ("back", -2020), "backup": ("backup", -2100), "base": ("base", -2080),
    "best": ("best", -2050), "beta": ("beta", -2050), "binary": ("binary", -2050),
    "bug": ("bug", -1820), "build": ("build", -1920), "bundle": ("bundle", -2050),
    "byte": ("byte", -2100), "cache": ("cache", -2050), "call": ("call", -2050),
    "cancel": ("cancel", -2100), "case": ("case", -2080), "check": ("check", -1980),
    "chinese": ("Chinese", -1880), "clean": ("clean", -2020), "clear": ("clear", -2020),
    "cli": ("CLI", -1950), "close": ("close", -2050), "code": ("code", -1900),
    "commit": ("commit", -2000), "config": ("config", -2050), "copy": ("copy", -2050),
    "core": ("core", -2020), "cpu": ("CPU", -1850), "csv": ("CSV", -2050),
    "data": ("data", -1950), "debug": ("debug", -1950), "default": ("default", -2050),
    "delete": ("delete", -2050), "demo": ("demo", -1900), "dev": ("dev", -2000),
    "device": ("device", -2050), "dict": ("dict", -2100), "diff": ("diff", -2050),
    "done": ("done", -1980), "email": ("email", -1920), "emoji": ("emoji", -1880),
    "end": ("end", -2050), "engine": ("engine", -1980), "english": ("English", -1820),
    "error": ("error", -1950), "export": ("export", -2080), "fail": ("fail", -2080),
    "fast": ("fast", -2050), "file": ("file", -1980), "find": ("find", -2050),
    "fix": ("fix", -1980), "for": ("for", -1950), "format": ("format", -2080),
    "from": ("from", -1980), "full": ("full", -2050), "function": ("function", -2100),
    "git": ("git", -1920), "github": ("GitHub", -1720), "good": ("good", -1920),
    "google": ("Google", -1800), "gpu": ("GPU", -1900), "group": ("group", -2050),
    "hash": ("hash", -2050), "hello": ("hello", -1720), "help": ("help", -1980),
    "home": ("home", -2000), "host": ("host", -2050), "html": ("HTML", -2000),
    "icon": ("icon", -2050), "import": ("import", -2050), "index": ("index", -2050),
    "info": ("info", -2000), "input": ("input", -2000), "install": ("install", -2020),
    "ios": ("iOS", -1660), "ipad": ("iPad", -1740), "iphone": ("iPhone", -1620),
    "json": ("JSON", -1900), "key": ("key", -2000), "keyboard": ("keyboard", -1880),
    "lexicon": ("lexicon", -2000), "license": ("license", -2000), "line": ("line", -2050),
    "link": ("link", -2050), "linux": ("Linux", -1900), "list": ("list", -2020),
    "local": ("local", -1980), "log": ("log", -1980), "lokey": ("Lokey", -1600),
    "mac": ("Mac", -1780), "macbook": ("MacBook", -1720), "macos": ("macOS", -1720),
    "main": ("main", -2020), "make": ("make", -2050), "map": ("map", -2050),
    "markdown": ("Markdown", -2020), "memory": ("memory", -2050), "menu": ("menu", -2080),
    "merge": ("merge", -2100), "message": ("message", -2050), "mode": ("mode", -2050),
    "model": ("model", -2020), "name": ("name", -2000), "network": ("network", -2050),
    "new": ("new", -1980), "next": ("next", -2000), "node": ("node", -2080),
    "note": ("note", -2020), "null": ("null", -2100), "offline": ("offline", -1820),
    "ok": ("OK", -1680), "open": ("open", -1980), "opencc": ("OpenCC", -1900),
    "option": ("option", -2080), "output": ("output", -2050), "pack": ("pack", -2020),
    "page": ("page", -2050), "pass": ("pass", -1980), "path": ("path", -2050),
    "pdf": ("PDF", -1760), "pinyin": ("Pinyin", -1860), "please": ("please", -1820),
    "plist": ("plist", -2050), "privacy": ("privacy", -1840), "pro": ("Pro", -1780),
    "project": ("project", -2000), "python": ("Python", -1840), "readme": ("README", -1950),
    "release": ("release", -1980), "repo": ("repo", -2000), "reset": ("reset", -2050),
    "run": ("run", -1980), "sandbox": ("sandbox", -2000), "save": ("save", -2020),
    "scheme": ("scheme", -2080), "script": ("script", -2020), "search": ("search", -2020),
    "security": ("security", -1920), "send": ("send", -2020), "server": ("server", -2050),
    "set": ("set", -2050), "settings": ("settings", -2000), "sha256": ("SHA256", -1950),
    "share": ("share", -2020), "shell": ("shell", -2050), "simd": ("SIMD", -2000),
    "simulator": ("Simulator", -1980), "size": ("size", -2050), "sorry": ("sorry", -1800),
    "source": ("source", -1980), "space": ("space", -2050), "sqlite": ("SQLite", -1950),
    "start": ("start", -2000), "state": ("state", -2050), "status": ("status", -2020),
    "stop": ("stop", -2050), "string": ("string", -2050), "swift": ("Swift", -1740),
    "swiftui": ("SwiftUI", -1820), "sync": ("sync", -2020), "system": ("system", -1980),
    "table": ("table", -2080), "tag": ("tag", -2050), "target": ("target", -2050),
    "test": ("test", -1880), "text": ("text", -2000), "thanks": ("thanks", -1780),
    "time": ("time", -1980), "today": ("today", -1920), "tomorrow": ("tomorrow", -1880),
    "true": ("true", -2050), "type": ("type", -2050), "uikit": ("UIKit", -1900),
    "unicode": ("Unicode", -1950), "update": ("update", -1980), "url": ("URL", -1820),
    "user": ("user", -1980), "utf8": ("UTF-8", -1980), "value": ("value", -2080),
    "verify": ("verify", -1980), "version": ("version", -2000), "view": ("view", -2020),
    "viterbi": ("Viterbi", -2000), "wifi": ("Wi-Fi", -1740), "work": ("work", -1980),
    "world": ("world", -1780), "xcode": ("Xcode", -1720), "xctest": ("XCTest", -1920),
    "yaml": ("YAML", -2020), "yes": ("yes", -1850), "zero": ("zero", -1950),
}

# Clean next-word conversational associations (ZERO `=` spoken entries, ZERO `$` commit entries)
CLEAN_DEMO_ASSOC: Dict[str, List[str]] = {
    "明天": ["我们", "见", "早上", "下午", "晚上", "有空"],
    "今天": ["下午", "晚上", "早上", "我们", "有空"],
    "我们": ["可以", "一起", "明天", "今天", "现在", "去"],
    "你们": ["可以", "一起", "明天", "现在", "有空"],
    "你好": ["吗", "呀", "请问", "啊"],
    "没有": ["问题", "关系", "时间", "看到"],
    "北京": ["大学", "的", "天安门", "时间"],
    "可以": ["吗", "啊", "一起", "直接"],
    "谢谢": ["你", "大家", "老师", "你们"],
    "什么": ["时候", "意思", "情况", "问题"],
    "怎么": ["样", "办", "回事", "用"],
    "为什么": ["不", "要", "会", "没有"],
    "已经": ["收到", "完成", "开始", "知道"],
    "知道": ["了", "吗", "怎么", "什么"],
    "现在": ["可以", "开始", "有空", "已经"],
    "输入法": ["很好用", "体验", "词库", "离线"],
    "人工": ["智能"],
    "我": ["们", "今天", "明天", "现在", "可以"],
    "你": ["好", "们", "今天", "明天", "现在"],
    "好": ["的", "吧", "啊", "吗"],
}

FALLBACK_EMOJI_MAP: Dict[str, List[str]] = {
    "哈哈": ["😂", "🤣"], "哈哈哈": ["😂", "🤣"], "笑哭": ["😂", "🤣"], "大笑": ["😂", "🤣"],
    "嘻嘻": ["😁", "😊"], "开心": ["😄", "😊"], "高兴": ["😄", "😊"], "太好了": ["🎉", "😄"],
    "大哭": ["😭", "😢"], "哭了": ["😭", "😢"], "难过": ["😢", "😔"], "伤心": ["😢", "💔"],
    "心碎": ["💔", "😭"], "无语": ["😅", "😑"], "尴尬": ["😅", "🫠"], "生气": ["😡", "😠"],
    "谢谢": ["🙏", "😊"], "感谢": ["🙏", "❤️"], "拜托": ["🙏", "🥺"], "点赞": ["👍", "🔥"],
    "厉害": ["👍", "🔥"], "加油": ["💪", "🔥"], "好的": ["👌", "😊"], "没问题": ["👌"],
    "收到": ["👌", "🫡"], "比心": ["🫶", "❤️"], "爱心": ["❤️", "🫶"], "喜欢": ["❤️", "😍"],
    "爱你": ["❤️", "😘"], "抱抱": ["🤗", "🫂"], "庆祝": ["🎉", "🥳"], "恭喜": ["🎉", "🎊"],
    "干杯": ["🍻", "🥂"], "生日快乐": ["🎂", "🎉"], "新年快乐": ["🧧", "🎉"], "红包": ["🧧"],
    "发财": ["🧧", "💰"], "晚安": ["🌙", "😴"], "早安": ["☀️", "😊"], "早上好": ["☀️", "😊"],
    "睡觉": ["😴", "💤"], "玫瑰": ["🌹"], "咖啡": ["☕"], "奶茶": ["🧋"],
    "西瓜": ["🍉"], "苹果": ["🍎"], "太阳": ["☀️"], "月亮": ["🌙"],
    "星星": ["⭐"], "火焰": ["🔥"], "电脑": ["💻"], "手机": ["📱"],
    "键盘": ["⌨️"], "锁": ["🔒"], "盾牌": ["🛡️"], "代码": ["💻"],
    "中国": ["🇨🇳"], "飞机": ["✈️"], "汽车": ["🚗"], "火车": ["🚄"],
    "猫咪": ["🐱"], "狗狗": ["🐶"], "熊猫": ["🐼"], "音乐": ["🎵"],
    "赞": ["👍"], "棒": ["👍"], "笑": ["😂", "😄"], "哭": ["😭", "😢"],
    "心": ["❤️"], "爱": ["❤️"],
}

FALLBACK_OPENCC_ST_CHARS: Dict[str, str] = {
    "发": "發", "后": "後", "面": "麵", "发财": "發財",
    "国": "國", "东": "東", "车": "車", "马": "馬", "鸟": "鳥", "鱼": "魚",
    "书": "書", "画": "畫", "写": "寫", "学": "學", "习": "習", "语": "語",
    "言": "言", "话": "話", "说": "說", "请": "請", "读": "讀", "认": "認",
    "识": "識", "记": "記", "设": "設", "计": "計", "试": "試", "验": "驗",
    "证": "證", "词": "詞", "库": "庫", "软": "軟", "件": "件", "硬": "硬",
    "盘": "盤", "鼠": "鼠", "标": "標", "键": "鍵", "网": "網", "络": "絡",
    "内": "內", "存": "存", "系": "系", "统": "統", "机": "機", "电": "電",
    "脑": "腦", "输": "輸", "入": "入", "法": "法", "开": "開", "关": "關",
    "门": "門", "问": "問", "题": "題", "间": "間", "时": "時", "们": "們",
    "这": "這", "个": "個", "为": "為", "什": "什", "么": "麼", "没": "沒",
    "会": "會", "能": "能", "过": "過", "进": "進", "还": "還", "达": "達",
    "选": "選", "运": "運", "动": "動", "经": "經", "济": "濟", "线": "線",
    "离": "離", "隐": "隱", "审": "審", "护": "護", "区": "區", "华": "華",
    "北": "北", "京": "京", "广": "廣", "州": "州", "深": "深", "港": "港",
    "台": "台", "湾": "灣", "爱": "愛", "乐": "樂", "欢": "歡", "迎": "迎",
    "头": "頭", "财": "財", "皇": "皇", "体": "體", "实": "實", "现": "現",
    "义": "義", "产": "產", "业": "業", "专": "專", "传": "傳", "统": "統",
    "优": "優", "伪": "偽", "体": "體", "余": "餘", "作": "作", "佣": "傭",
    "侠": "俠", "保": "保", "信": "信", "修": "修", "值": "值", "假": "假",
    "备": "備", "复": "複", "够": "夠", "天": "天", "太": "太", "失": "失",
    "奥": "奧", "奖": "獎", "好": "好", "如": "如", "妇": "婦", "妈": "媽",
    "孙": "孫", "安": "安", "完": "完", "定": "定", "宝": "寶", "将": "將",
    "导": "導", "对": "對", "寻": "尋", "专": "專", "层": "層", "岁": "歲",
    "岛": "島", "师": "師", "帮": "幫", "常": "常", "干": "乾", "广": "廣",
    "应": "應", "底": "底", "张": "張", "当": "當", "录": "錄", "归": "歸",
    "总": "總", "态": "態", "思": "思", "性": "性", "总": "總", "情": "情",
    "想": "想", "意": "意", "感": "感", "愿": "願", "戏": "戲", "战": "戰",
    "户": "戶", "才": "才", "打": "打", "找": "找", "技": "技", "报": "報",
    "担": "擔", "拉": "拉", "换": "換", "据": "據", "接": "接", "推": "推",
    "提": "提", "搜": "搜", "支": "支", "改": "改", "放": "放", "数": "數",
    "整": "整", "文": "文", "新": "新", "方": "方", "无": "無", "旧": "舊",
    "明": "明", "易": "易", "春": "春", "显": "顯", "晚": "晚", "书": "書",
    "最": "最", "会": "會", "月": "月", "有": "有", "服": "服", "条": "條",
    "来": "來", "极": "極", "构": "構", "果": "果", "标": "標", "样": "樣",
    "格": "格", "校": "校", "检": "檢", "模": "模", "欢": "歡", "步": "步",
    "历": "歷", "死": "死", "残": "殘", "每": "每", "气": "氣", "水": "水",
    "汇": "匯", "汉": "漢", "没": "沒", "河": "河", "治": "治", "注": "註",
    "测": "測", "海": "海", "消": "消", "游": "遊", "满": "滿", "点": "點",
    "热": "熱", "然": "然", "照": "照", "爱": "愛", "父": "父", "版": "版",
    "独": "獨", "环": "環", "现": "現", "理": "理", "生": "生", "用": "用",
    "由": "由", "画": "畫", "留": "留", "百": "百", "的": "的", "真": "真",
    "眼": "眼", "着": "著", "知": "知", "码": "碼", "确": "確", "示": "示",
    "社": "社", "神": "神", "福": "福", "离": "離", "种": "種", "科": "科",
    "称": "稱", "移": "移", "程": "程", "究": "究", "空": "空", "立": "立",
    "端": "端", "第": "第", "简": "簡", "算": "算", "管": "管", "类": "類",
    "精": "精", "系": "系", "紧": "緊", "繁": "繁", "红": "紅", "约": "約",
    "级": "級", "纪": "紀", "纯": "純", "组": "組", "细": "細", "终": "終",
    "经": "經", "结": "結", "给": "給", "统": "統", "续": "續", "维": "維",
    "网": "網", "编": "編", "练": "練", "置": "置", "美": "美", "群": "群",
    "老": "老", "考": "考", "者": "者", "联": "聯", "职": "職", "能": "能",
    "脑": "腦", "自": "自", "致": "致", "与": "與", "兴": "興", "举": "舉",
    "苏": "蘇", "范": "範", "获": "獲", "行": "行", "表": "表", "装": "裝",
    "西": "西", "要": "要", "见": "見", "观": "觀", "规": "規", "视": "視",
    "觉": "覺", "解": "解", "触": "觸", "言": "言", "计": "計", "订": "訂",
    "认": "認", "讨": "討", "让": "讓", "训": "訓", "议": "議", "讯": "訊",
    "记": "記", "讲": "講", "许": "許", "论": "論", "设": "設", "访": "訪",
    "证": "證", "评": "評", "识": "識", "词": "詞", "译": "譯", "试": "試",
    "诗": "詩", "话": "話", "该": "該", "详": "詳", "语": "語", "误": "誤",
    "说": "說", "请": "請", "诸": "諸", "读": "讀", "课": "課", "调": "調",
    "谈": "談", "谢": "謝", "谨": "謹", "贝": "貝", "负": "負", "贡": "貢",
    "财": "財", "责": "責", "败": "敗", "货": "貨", "质": "質", "费": "費",
    "资": "資", "赋": "賦", "赏": "賞", "赖": "賴", "赚": "賺", "赛": "賽",
    "赞": "贊", "赢": "贏", "走": "走", "起": "起", "越": "越", "足": "足",
    "路": "路", "跳": "跳", "身": "身", "车": "車", "转": "轉", "轮": "輪",
    "软": "軟", "轻": "輕", "载": "載", "较": "較", "辅": "輔", "输": "輸",
    "辞": "辭", "边": "邊", "达": "達", "过": "過", "迈": "邁", "运": "運",
    "近": "近", "返": "返", "还": "還", "这": "這", "进": "進", "远": "遠",
    "连": "連", "选": "選", "适": "適", "递": "遞", "通": "通", "速": "速",
    "造": "造", "逢": "逢", "道": "道", "遗": "遺", "邻": "鄰", "邮": "郵",
    "都": "都", "配": "配", "酒": "酒", "采": "採", "里": "裡", "重": "重",
    "量": "量", "金": "金", "针": "針", "钟": "鐘", "钢": "鋼", "钱": "錢",
    "铁": "鐵", "链": "鏈", "锁": "鎖", "错": "錯", "键": "鍵", "长": "長",
    "门": "門", "闪": "閃", "闭": "閉", "问": "問", "间": "間", "阅": "閱",
    "防": "防", "阳": "陽", "阶": "階", "际": "際", "陆": "陸", "险": "險",
    "随": "隨", "隐": "隱", "难": "難", "集": "集", "雨": "雨", "雪": "雪",
    "云": "雲", "零": "零", "雷": "雷", "需": "需", "震": "震", "青": "青",
    "静": "靜", "非": "非", "面": "面", "音": "音", "页": "頁", "顶": "頂",
    "项": "項", "顺": "順", "须": "須", "预": "預", "领": "領", "频": "頻",
    "题": "題", "颜": "顏", "风": "風", "飞": "飛", "食": "食", "饭": "飯",
    "饮": "飲", "馆": "館", "首": "首", "马": "馬", "驱": "驅", "验": "驗",
    "体": "體", "高": "高", "鲜": "鮮", "鸟": "鳥", "麦": "麥", "黄": "黃",
    "黑": "黑", "默": "默", "齐": "齊", "龙": "龍",
}
FALLBACK_ST_PHRASES: Dict[str, str] = {
    "头发": "頭髮", "发财": "發財", "后面": "後面", "皇后": "皇后",
    "里面": "裡面", "下面": "下面", "上面": "上面", "前面": "前面",
    "联系": "聯繫", "系统": "系統", "软件": "軟件", "鼠标": "鼠標",
}
FALLBACK_TW_PHRASES: Dict[str, str] = {
    "軟件": "軟體", "鼠標": "滑鼠", "內存": "記憶體", "網絡": "網路",
    "隨身碟": "隨身碟", "U盤": "隨身碟",
}
FALLBACK_TW_VARIANTS: Dict[str, str] = {"裡": "裡", "為": "為", "台": "台", "着": "著"}
FALLBACK_HK_VARIANTS: Dict[str, str] = {"裡": "裏", "為": "為", "台": "台", "着": "著"}

PINNED_FETCH_ASSETS = {
    "rime_dict": (
        "https://raw.githubusercontent.com/rime/rime-pinyin-simp/0c6861ef7420ee780270ca6d993d18d4101049d0/pinyin_simp.dict.yaml",
        "rime-pinyin-simp/pinyin_simp.dict.yaml",
        "e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b",
    ),
    "unihan_zip": (
        "https://www.unicode.org/Public/18.0.0/ucd/Unihan.zip",
        "unihan/Unihan.zip",
        "4c93ea9c1f636451729a840978f1667a53886af37ba854fdcce109721c63d43e",
    ),
    "opencc_st_chars": (
        "https://raw.githubusercontent.com/BYVoid/OpenCC/fae2a0a911c30764e669a7d8b0591cd8e852934a/data/dictionary/STCharacters.txt",
        "opencc/STCharacters.txt",
        None,
    ),
    "opencc_st_phrases": (
        "https://raw.githubusercontent.com/BYVoid/OpenCC/fae2a0a911c30764e669a7d8b0591cd8e852934a/data/dictionary/STPhrases.txt",
        "opencc/STPhrases.txt",
        None,
    ),
    "opencc_tw_phrases": (
        "https://raw.githubusercontent.com/BYVoid/OpenCC/fae2a0a911c30764e669a7d8b0591cd8e852934a/data/dictionary/TWPhrases.txt",
        "opencc/TWPhrases.txt",
        None,
    ),
    "opencc_tw_variants": (
        "https://raw.githubusercontent.com/BYVoid/OpenCC/fae2a0a911c30764e669a7d8b0591cd8e852934a/data/dictionary/TWVariants.txt",
        "opencc/TWVariants.txt",
        None,
    ),
    "opencc_hk_variants": (
        "https://raw.githubusercontent.com/BYVoid/OpenCC/fae2a0a911c30764e669a7d8b0591cd8e852934a/data/dictionary/HKVariants.txt",
        "opencc/HKVariants.txt",
        None,
    ),
    "cldr_zh": (
        "https://raw.githubusercontent.com/unicode-org/cldr/267bae66b10db620caca6d5df88c1719fc0fd457/common/annotations/zh.xml",
        "cldr/zh.xml",
        "820de5034133077d2baa31464de0c91e748ae3c659880c2918bf6a55e560a282",
    ),
}


def align8(buf: bytearray) -> None:
    rem = len(buf) % 8
    if rem:
        buf.extend(b"\x00" * (8 - rem))


def is_bmp_han_word(text: str) -> bool:
    if not text:
        return False
    for ch in text:
        cp = ord(ch)
        if not (0x4E00 <= cp <= 0x9FFF or cp == 0x3007):
            return False
    return True


def normalize_syllable(tok: str, canonical: Set[str]) -> str:
    s = tok.strip().lower()
    if s in ("lue", "lve"):
        return "lve" if "lve" in canonical else s
    if s in ("nue", "nve"):
        return "nve" if "nve" in canonical else s
    s = s.replace("u:", "v").replace("ü", "v")
    if s in canonical:
        return s
    return s if SYLLABLE_RE.match(s) and s not in INVALID_NON_MANDARIN_SYLLABLES else ""


def pack_code_be(acronym: str) -> int:
    raw = acronym.encode("ascii")[:8]
    padded = raw + b"\x00" * (8 - len(raw))
    return struct.unpack(">Q", padded)[0]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def fetch_pinned_sources(dest_dir: Path) -> None:
    print(f"==> Fetching pinned permissive upstream sources into {dest_dir}...")
    for _, (url, rel_path, expected_sha) in PINNED_FETCH_ASSETS.items():
        target = dest_dir / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if expected_sha is None or sha256_file(target) == expected_sha:
                continue
        print(f"  -> {url}")
        tmp = target.with_suffix(target.suffix + ".tmp")
        urllib.request.urlretrieve(url, tmp)
        if expected_sha is not None:
            got = sha256_file(tmp)
            if got != expected_sha:
                tmp.unlink(missing_ok=True)
                raise RuntimeError(f"SHA-256 mismatch for {url}: expected {expected_sha}, got {got}")
        tmp.replace(target)

    unihan_txt = dest_dir / "unihan" / "Unihan_Readings.txt"
    unihan_zip = dest_dir / "unihan" / "Unihan.zip"
    if not unihan_txt.exists() and unihan_zip.exists():
        with zipfile.ZipFile(unihan_zip, "r") as zf:
            zf.extract("Unihan_Readings.txt", dest_dir / "unihan")


def resolve_permissive_dir(project_root: Path, explicit: Optional[Path]) -> Optional[Path]:
    if explicit is not None:
        return explicit if explicit.exists() else None
    candidates = [
        project_root / "vendor" / "permissive",
        project_root.parent / "Lokey" / "vendor" / "permissive",
        Path.home() / ".cache" / "lokey-audit" / "permissive",
    ]
    for c in candidates:
        if (c / "rime-pinyin-simp" / "pinyin_simp.dict.yaml").exists():
            return c
    return None


def parse_rime_pinyin_simp(path: Path) -> List[Tuple[str, str, float]]:
    entries: List[Tuple[str, str, float]] = []
    in_body = False
    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if not in_body:
                if line.strip() == "...":
                    in_body = True
                continue
            line = line.rstrip("\r\n")
            if not line or line[0] in ("#", "-", ".", " ") or "\t" not in line:
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            text = parts[0].strip()
            code = parts[1].strip()
            weight = 1.0
            if len(parts) >= 3:
                try:
                    weight = float(parts[2].strip())
                except ValueError:
                    weight = 1.0
            entries.append((text, code, weight))
    return entries


def strip_tone_pinyin(syl_with_tone: str) -> str:
    tone_map = {
        "ā": "a", "á": "a", "ǎ": "a", "à": "a",
        "ē": "e", "é": "e", "ě": "e", "è": "e",
        "ī": "i", "í": "i", "ǐ": "i", "ì": "i",
        "ō": "o", "ó": "o", "ǒ": "o", "ò": "o",
        "ū": "u", "ú": "u", "ǔ": "u", "ù": "u",
        "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v", "ü": "v",
    }
    out = []
    for ch in syl_with_tone.lower():
        if ch in tone_map:
            out.append(tone_map[ch])
        elif "a" <= ch <= "z":
            out.append(ch)
    return "".join(out)


def parse_unihan_readings(path: Path, canonical: Set[str]) -> Dict[str, List[str]]:
    out: Dict[str, List[str]] = defaultdict(list)
    if not path.exists():
        return out
    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if not line.startswith("U+"):
                continue
            parts = line.rstrip("\r\n").split("\t")
            if len(parts) < 3 or parts[1] not in ("kMandarin", "kHanyuPinyin"):
                continue
            cp = int(parts[0][2:], 16)
            if not (0x4E00 <= cp <= 0x9FFF):
                continue
            ch = chr(cp)
            raw_val = parts[2]
            if ":" in raw_val:
                raw_val = raw_val.split(":", 1)[1]
            for tok in re.split(r"[\s,]+", raw_val.strip()):
                syl = normalize_syllable(strip_tone_pinyin(tok), canonical)
                if syl and syl not in out[ch]:
                    out[ch].append(syl)
    return out


class TrieBuilderNode:
    __slots__ = ("depth", "children", "words", "flat_index", "max_subtree_score")

    def __init__(self, depth: int) -> None:
        self.depth = depth
        self.children: Dict[int, "TrieBuilderNode"] = {}
        self.words: List[Tuple[int, int, int]] = []
        self.flat_index = 0
        self.max_subtree_score = -32000


def compile_demo_lexicon(permissive_dir: Optional[Path], out_dir: Path) -> Dict[str, int]:
    canonical_syllables = set(CANONICAL_416_SYLLABLE_SEED.keys())
    sorted_syllables = sorted(canonical_syllables)
    assert len(sorted_syllables) == 416
    syl_to_id = {s: idx + 1 for idx, s in enumerate(sorted_syllables)}

    cn_entries: Dict[Tuple[str, Tuple[str, ...]], float] = {}

    # Seed every canonical syllable with at least 1 clean single-char BMP Hanzi
    for syl, ch in CANONICAL_416_SYLLABLE_SEED.items():
        cn_entries[(ch, (syl,))] = 40_000.0

    if permissive_dir is not None and (permissive_dir / "rime-pinyin-simp" / "pinyin_simp.dict.yaml").exists():
        raw_rime = parse_rime_pinyin_simp(permissive_dir / "rime-pinyin-simp" / "pinyin_simp.dict.yaml")
        unihan = parse_unihan_readings(permissive_dir / "unihan" / "Unihan_Readings.txt", canonical_syllables)

        per_syl_chars: Dict[str, List[Tuple[str, float]]] = defaultdict(list)
        phrase_pool: List[Tuple[str, Tuple[str, ...], float]] = []

        for text, code, weight in raw_rime:
            if not is_bmp_han_word(text) or len(text) > 6:
                continue
            syls = tuple(normalize_syllable(tok, canonical_syllables) for tok in code.split())
            if not syls or any(s not in canonical_syllables for s in syls):
                continue
            if len(text) == 1:
                eff_w = weight * 1.65 if weight > 600_000 else max(1.0, weight * 2.1)
                per_syl_chars[syls[0]].append((text, eff_w))
            elif len(text) == len(syls):
                eff_w = max(10.0, (max(weight, 1.0) ** 0.83) * 10.5)
                if eff_w > 135_000.0:
                    eff_w = 135_000.0 + (eff_w - 135_000.0) * 0.22
                phrase_pool.append((text, syls, eff_w))

        # Top 2 single-char BMP Hanzi per canonical syllable (~830 single chars)
        for syl in sorted_syllables:
            cands = sorted(per_syl_chars.get(syl, []), key=lambda x: x[1], reverse=True)
            for ch, eff_w in cands[:2]:
                k = (ch, (syl,))
                if eff_w > cn_entries.get(k, 0.0):
                    cn_entries[k] = max(eff_w, 50.0)
            if not cands:
                # Try Unihan fallback for rare syllables like `nun`, `rua`
                for ch, syl_list in unihan.items():
                    if syl in syl_list:
                        cn_entries.setdefault((ch, (syl,)), 50.0)
                        break

        # Top ~3,100 highest-weight multi-char phrases from rime-pinyin-simp
        phrase_pool.sort(key=lambda x: x[2], reverse=True)
        for text, syls, eff_w in phrase_pool[:3100]:
            k = (text, syls)
            if eff_w > cn_entries.get(k, 0.0):
                cn_entries[k] = eff_w

    # Ensure lue/lve and nue/nve aliases share key chars cleanly
    for ch, syl, w in [
        ("略", "lue", 120_000.0), ("略", "lve", 120_000.0),
        ("虐", "nue", 80_000.0), ("虐", "nve", 80_000.0),
        ("女", "nv", 220_000.0), ("旅", "lv", 180_000.0),
        ("我", "wo", 950_000.0), ("你", "ni", 750_000.0),
        ("他", "ta", 650_000.0), ("她", "ta", 520_000.0),
        ("的", "de", 1_400_000.0), ("了", "le", 900_000.0),
        ("是", "shi", 1_100_000.0), ("在", "zai", 800_000.0),
        ("塞", "sei", 10_000.0), ("嫩", "nun", 10_000.0),
        ("挼", "rua", 10_000.0),
    ]:
        k = (ch, (syl,))
        cn_entries[k] = max(cn_entries.get(k, 0.0), w)

    # Inject essential demo/audit phrases
    for (text, syls), w in ESSENTIAL_DEMO_PHRASES.items():
        k = (text, syls)
        cn_entries[k] = max(cn_entries.get(k, 0.0), w)

    # Also build string pool & trie
    string_pool = bytearray()
    str_offsets: Dict[str, Tuple[int, int]] = {}

    def intern_str(s: str) -> Tuple[int, int]:
        hit = str_offsets.get(s)
        if hit is not None:
            return hit
        b = s.encode("utf-8")
        off = len(string_pool)
        string_pool.extend(b)
        res = (off, len(b))
        str_offsets[s] = res
        return res

    root = TrieBuilderNode(0)
    jianpin_candidates: List[Tuple[int, int, int, int]] = []
    vocab_texts: Set[str] = set()

    for (text, syls), weight in sorted(cn_entries.items(), key=lambda x: (x[0][1], -x[1], x[0][0])):
        vocab_texts.add(text)
        log_p = math.log10(max(weight, 1e-4) / NORM_Z)
        score_q8 = max(-15000, min(-100, int(round(log_p * 512.0))))
        s_off, s_len = intern_str(text)

        node = root
        for s in syls:
            sid = syl_to_id[s]
            child = node.children.get(sid)
            if child is None:
                child = TrieBuilderNode(node.depth + 1)
                node.children[sid] = child
            node = child
        node.words.append((s_off, s_len, score_q8))

        if 2 <= len(syls) <= 8:
            acronym = "".join(s[0] for s in syls)
            code_be = pack_code_be(acronym)
            jianpin_candidates.append((code_be, s_off, s_len, score_q8))

    flat_nodes: List[TrieBuilderNode] = []

    def finalize_dfs(node: TrieBuilderNode) -> int:
        node.flat_index = len(flat_nodes)
        flat_nodes.append(node)
        if node.words:
            node.words.sort(key=lambda x: x[2], reverse=True)
            best = node.words[0][2]
        else:
            best = -32000
        for sid in sorted(node.children.keys()):
            child_best = finalize_dfs(node.children[sid])
            if child_best > best:
                best = child_best
        node.max_subtree_score = best
        return best

    finalize_dfs(root)

    jianpin_by_key: Dict[int, List[Tuple[int, int, int, int]]] = defaultdict(list)
    for item in jianpin_candidates:
        jianpin_by_key[item[0]].append(item)

    final_jianpin: List[Tuple[int, int, int, int]] = []
    for code_be in sorted(jianpin_by_key.keys()):
        bucket = jianpin_by_key[code_be]
        bucket.sort(key=lambda x: x[3], reverse=True)
        seen_off = set()
        for rec in bucket:
            if rec[1] in seen_off:
                continue
            seen_off.add(rec[1])
            final_jianpin.append(rec)
            if len(seen_off) >= 8:
                break

    final_english: List[Tuple[int, int, int, int, int]] = []
    for lower_key in sorted(BASIC_ENGLISH_WORDS.keys(), key=lambda s: s.encode("utf-8")):
        disp, score_q8 = BASIC_ENGLISH_WORDS[lower_key]
        l_off, l_len = intern_str(lower_key)
        d_off, d_len = intern_str(disp)
        final_english.append((l_off, d_off, l_len, d_len, score_q8))

    # Clean next-word associations ONLY (zero `=` spoken readings, zero `$` commit deltas)
    final_assoc: List[Tuple[int, int, int, int, int, int]] = []
    for pref in sorted(CLEAN_DEMO_ASSOC.keys(), key=lambda s: s.encode("utf-8")):
        assert not pref.startswith(("=", "$")), "Demo lexicon must not contain spoken '=' or '$' keys"
        k_off, k_len = intern_str(pref)
        for rank_i, cont in enumerate(CLEAN_DEMO_ASSOC[pref]):
            v_off, v_len = intern_str(cont)
            sc = 2600 - rank_i * 80
            final_assoc.append((k_off, v_off, k_len, v_len, sc, rank_i))

    # Build un-tuned neutral LNLM-v2 section
    bmp_chars = sorted(
        {c for txt in vocab_texts for c in txt if 0x4E00 <= ord(c) < 0xA000}
    )
    char_to_idx = {c: idx + 1 for idx, c in enumerate(bmp_chars)}
    char_map_arr = [0] * 20992
    for ch, c_idx in char_to_idx.items():
        char_map_arr[ord(ch) - 0x4E00] = c_idx
    char_map_bytes = struct.pack("<20992H", *char_map_arr)

    char_emb_buf = bytearray(64)  # Slot 0: 64 zero bytes
    neutral_vec = bytes(4 if k in (10, 31) else 0 for k in range(32))
    for _ in bmp_chars:
        char_emb_buf.extend(neutral_vec)
        char_emb_buf.extend(neutral_vec)

    # 6,336 Float32 MLP weights: alpha = [0.5]*32 (index 6208..6240), all remaining 6,304 floats = 0.0
    mlp_floats = [0.0] * 6336
    alpha_start = 6 * 1024 + 2 * 32  # wCtx, wRec, b1, wProj, bDirect, bSkip, b2, wChar => 6144+64=6208
    for i in range(32):
        mlp_floats[alpha_start + i] = 0.5
    mlp_buf = struct.pack("<6336f", *mlp_floats)
    assert len(mlp_buf) == 25344

    # Serialize LKLF-v2
    buf = bytearray(72)

    syllable_offset = len(buf)
    buf.extend(b"\x00" * 16)
    for s in sorted_syllables:
        sb = s.encode("ascii")
        padded = sb + b"\x00" * (8 - len(sb))
        init_ascii = sb[0]
        init_group = init_ascii - ord("a") + 1
        if s.startswith(("zh", "ch", "sh")):
            init_group |= 0x100
        buf.extend(struct.pack("<8sBBHI", padded, init_ascii, len(sb), init_group, 0))
    align8(buf)

    edge_records: List[Tuple[int, int, int]] = []
    word_records: List[Tuple[int, int, int]] = []
    node_offset = len(buf)
    for node in flat_nodes:
        first_edge = len(edge_records)
        sorted_sids = sorted(node.children.keys())
        for sid in sorted_sids:
            syl_str = sorted_syllables[sid - 1]
            edge_records.append((sid, ord(syl_str[0]), node.children[sid].flat_index))
        first_word = len(word_records)
        word_records.extend(node.words)
        buf.extend(
            struct.pack(
                "<IHHIhH",
                first_edge,
                len(sorted_sids),
                len(node.words),
                first_word,
                max(-32768, min(32767, node.max_subtree_score)),
                min(65535, node.depth),
            )
        )
    align8(buf)

    edge_offset = len(buf)
    for sid, init_b, target_idx in edge_records:
        buf.extend(struct.pack("<HBBI", sid, init_b, 0, target_idx))
    align8(buf)

    word_offset = len(buf)
    for s_off, s_len, score_q8 in word_records:
        buf.extend(struct.pack("<IHh", s_off, s_len, score_q8))
    align8(buf)

    jianpin_offset = len(buf)
    for code_be, s_off, s_len, score_q8 in final_jianpin:
        buf.extend(struct.pack(">Q", code_be))
        buf.extend(struct.pack("<IHh", s_off, s_len, score_q8))
    align8(buf)

    english_offset = len(buf)
    for l_off, d_off, l_len, d_len, score_q8 in final_english:
        buf.extend(struct.pack("<IIHHhH", l_off, d_off, l_len, d_len, score_q8, 0))
    align8(buf)

    assoc_offset = len(buf)
    for k_off, v_off, k_len, v_len, sc, rank_i in final_assoc:
        buf.extend(struct.pack("<IIHHhH", k_off, v_off, k_len, v_len, sc, rank_i))
    align8(buf)

    string_pool_offset = len(buf)
    string_pool_size = len(string_pool)
    buf.extend(string_pool)
    align8(buf)

    buf[0:72] = struct.pack(
        "<18I",
        LKLF_MAGIC,
        2,
        len(sorted_syllables),
        syllable_offset,
        len(flat_nodes),
        node_offset,
        len(edge_records),
        edge_offset,
        len(word_records),
        word_offset,
        len(final_jianpin),
        jianpin_offset,
        len(final_english),
        english_offset,
        string_pool_size,
        string_pool_offset,
        len(final_assoc),
        assoc_offset,
    )

    # Append un-tuned LNLM-v2 + 16-byte footer
    lnlm_offset = len(buf)
    buf.extend(b"\x00" * 32)
    c_map_off = len(buf)
    buf.extend(char_map_bytes)
    align8(buf)
    c_emb_off = len(buf)
    buf.extend(char_emb_buf)
    align8(buf)
    w_tab_off = len(buf)  # wCount = 0
    mlp_off = len(buf)
    buf.extend(mlp_buf)
    align8(buf)
    lnlm_size = len(buf) - lnlm_offset

    buf[lnlm_offset : lnlm_offset + 32] = struct.pack(
        "<8I",
        LNLM_MAGIC,
        LNLM_DIM,
        len(bmp_chars),
        c_map_off,
        c_emb_off,
        0,
        w_tab_off,
        mlp_off,
    )
    buf.extend(struct.pack("<4I", LNLM_MAGIC, 2, lnlm_offset, lnlm_size))

    out_path = out_dir / "demo_lexicon.bin"
    out_path.write_bytes(buf)

    return {
        "bytes": len(buf),
        "syllables": len(sorted_syllables),
        "chinese_words": len(word_records),
        "jianpin": len(final_jianpin),
        "english": len(final_english),
        "assoc": len(final_assoc),
        "lnlm_chars": len(bmp_chars),
    }


def compile_demo_emoji(permissive_dir: Optional[Path], out_dir: Path) -> Dict[str, int]:
    word_to_emojis: Dict[str, List[str]] = {k: list(v) for k, v in FALLBACK_EMOJI_MAP.items()}

    if permissive_dir is not None and (permissive_dir / "cldr" / "zh.xml").exists():
        tree = ET.parse(permissive_dir / "cldr" / "zh.xml")
        added = 0
        for ann in tree.getroot().findall(".//annotation"):
            if ann.attrib.get("type") == "tts" or not ann.text:
                continue
            tok = (ann.attrib.get("cp") or "").strip()
            if tok == "♥️":
                tok = "❤️"
            if not tok or any(0x4E00 <= ord(c) <= 0x9FFF for c in tok) or tok.isascii():
                continue
            for raw_kw in ann.text.split("|"):
                key = raw_kw.strip()
                if len(key) < 2 or len(key) > 6 or any(ch.isspace() for ch in key):
                    continue
                if key not in word_to_emojis:
                    word_to_emojis[key] = [tok]
                    added += 1
                    if len(word_to_emojis) >= 95:
                        break
            if len(word_to_emojis) >= 95:
                break

    sorted_items = sorted(
        (
            (k.encode("utf-8"), [e.encode("utf-8") for e in v if 0 < len(e.encode("utf-8")) <= 64][:4])
            for k, v in word_to_emojis.items()
        ),
        key=lambda item: item[0],
    )
    sorted_items = [(kb, eb) for kb, eb in sorted_items if kb and eb]

    pool = bytearray()
    records: List[Tuple[int, int, int, int]] = []
    for key_bytes, emoji_bytes_list in sorted_items:
        key_off = len(pool)
        pool.extend(key_bytes)
        val_off = len(pool)
        for eb in emoji_bytes_list:
            pool.append(len(eb))
            pool.extend(eb)
        records.append((key_off, len(key_bytes), len(emoji_bytes_list), val_off))

    buf = bytearray(16)
    for k_off, k_len, e_cnt, v_off in records:
        buf.extend(struct.pack("<IHHI", k_off, k_len, e_cnt, v_off))
    align8(buf)
    pool_offset = len(buf)
    buf.extend(pool)
    align8(buf)
    buf[0:16] = struct.pack("<4I", LEMJ_MAGIC, 1, len(records), pool_offset)

    out_path = out_dir / "lokey_emoji.bin"
    out_path.write_bytes(buf)
    return {"entries": len(records), "bytes": len(buf)}


def parse_opencc_txt(path: Path) -> Dict[str, str]:
    out: Dict[str, str] = {}
    with path.open("r", encoding="utf-8-sig") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "\t" not in line:
                continue
            k, rhs = line.split("\t", 1)
            vals = [v for v in rhs.strip().split() if v]
            if k.strip() and vals:
                out[k.strip()] = vals[0]
    return out


def to_utf16_units(text: str) -> Tuple[int, ...]:
    raw = text.encode("utf-16-le")
    return struct.unpack(f"<{len(raw) // 2}H", raw)


def build_opencc_stage_table(
    entries: Dict[str, Optional[str]],
    pool_map: Dict[Tuple[int, ...], int],
    pool_units: List[int],
) -> Tuple[bytes, bytes, bytes, int]:
    bitmap = bytearray(8192)
    packed_items: List[Tuple[Tuple[int, ...], int, int]] = []

    def intern(s: Optional[str]) -> int:
        if s is None:
            return 0
        units = to_utf16_units(s)
        if not (1 <= len(units) <= 16):
            raise ValueError(f"Unsupported UTF-16 length {len(units)} for {s!r}")
        off = pool_map.get(units)
        if off is None:
            off = len(pool_units)
            pool_map[units] = off
            pool_units.extend(units)
        return (off << 8) | len(units)

    for k, v in entries.items():
        k_units = to_utf16_units(k)
        if not (1 <= len(k_units) <= 16):
            continue
        u0 = k_units[0]
        bitmap[u0 >> 3] |= 1 << (u0 & 7)
        packed_items.append((k_units, intern(k), intern(v)))

    packed_items.sort(key=lambda item: item[0])

    index_buf = bytearray()
    records_buf = bytearray()
    cur_u0: Optional[int] = None
    cur_mask = 0
    cur_start = 0

    for idx, (k_units, k_packed, v_packed) in enumerate(packed_items):
        u0 = k_units[0]
        ln_bit = 1 << (len(k_units) - 1)
        if cur_u0 is None:
            cur_u0 = u0
            cur_mask = ln_bit
            cur_start = idx
        elif u0 == cur_u0:
            cur_mask |= ln_bit
        else:
            index_buf.extend(struct.pack("<HHI", cur_u0, cur_mask, cur_start))
            cur_u0 = u0
            cur_mask = ln_bit
            cur_start = idx
        records_buf.extend(struct.pack("<II", k_packed, v_packed))

    if cur_u0 is not None:
        index_buf.extend(struct.pack("<HHI", cur_u0, cur_mask, cur_start))
    index_buf.extend(struct.pack("<HHI", 0xFFFF, 0, len(packed_items)))

    return bytes(bitmap), bytes(index_buf), bytes(records_buf), (len(index_buf) // 8) - 1


def pack_scalar_table(pairs: Dict[str, str]) -> Tuple[bytes, int]:
    rows = sorted((ord(k), ord(v)) for k, v in pairs.items() if len(k) == 1 and len(v) == 1)
    buf = bytearray()
    for ks, vs in rows:
        buf.extend(struct.pack("<II", ks, vs))
    return bytes(buf), len(rows)


def compile_demo_opencc(permissive_dir: Optional[Path], out_dir: Path) -> Dict[str, int]:
    opencc_dir = (permissive_dir / "opencc") if permissive_dir is not None else None
    if opencc_dir is not None and (opencc_dir / "STCharacters.txt").exists():
        all_st_chars = parse_opencc_txt(opencc_dir / "STCharacters.txt")
        all_st_phrases = parse_opencc_txt(opencc_dir / "STPhrases.txt")
        all_tw_phrases = parse_opencc_txt(opencc_dir / "TWPhrases.txt")
        all_tw_variants = parse_opencc_txt(opencc_dir / "TWVariants.txt")
        all_hk_variants = parse_opencc_txt(opencc_dir / "HKVariants.txt")

        # Select essential minimal subset (~350-500 mappings total)
        st_chars = {k: v for k, v in all_st_chars.items() if k in FALLBACK_OPENCC_ST_CHARS or k in "爱发后国车马书画学语文说请读认识记设计试验证词库软盘鼠标键网络内存系统机电脑输入开关问题间时们这为么没会过进还选运动经济线离隐审护区华北广深港台乐欢迎头财皇体实"}
        for k, v in list(all_st_chars.items())[:250]:
            st_chars.setdefault(k, v)
        st_phrases: Dict[str, Optional[str]] = {}
        for k in ("头发", "发财", "后面", "皇后", "里面", "联系", "系统", "软件", "鼠标", "发财了", "在后面"):
            if k in all_st_phrases:
                st_phrases[k] = all_st_phrases[k]
        for k, v in all_st_phrases.items():
            if len(st_phrases) >= 120:
                break
            if len(k) <= 4 and v != "".join(st_chars.get(c, c) for c in k):
                st_phrases[k] = v

        tw_phrases: Dict[str, Optional[str]] = {}
        for k in ("軟件", "鼠標", "內存", "網絡", "隨身碟", "U盤", "硬盤", "打印機", "操作系統"):
            if k in all_tw_phrases:
                tw_phrases[k] = all_tw_phrases[k]
        for k, v in all_tw_phrases.items():
            if len(tw_phrases) >= 80:
                break
            tw_phrases.setdefault(k, v)

        tw_variants = {k: v for k, v in list(all_tw_variants.items())[:80]}
        for k in FALLBACK_TW_VARIANTS:
            if k in all_tw_variants:
                tw_variants[k] = all_tw_variants[k]

        hk_variants = {k: v for k, v in list(all_hk_variants.items())[:80]}
        for k in FALLBACK_HK_VARIANTS:
            if k in all_hk_variants:
                hk_variants[k] = all_hk_variants[k]
    else:
        st_chars = dict(FALLBACK_OPENCC_ST_CHARS)
        st_phrases = dict(FALLBACK_ST_PHRASES)
        tw_phrases = dict(FALLBACK_TW_PHRASES)
        tw_variants = dict(FALLBACK_TW_VARIANTS)
        hk_variants = dict(FALLBACK_HK_VARIANTS)

    pool_map: Dict[Tuple[int, ...], int] = {}
    pool_units: List[int] = []

    st_char_bytes, st_char_count = pack_scalar_table(st_chars)
    tw_var_bytes, tw_var_count = pack_scalar_table(tw_variants)
    hk_var_bytes, hk_var_count = pack_scalar_table(hk_variants)

    st_bmp, st_idx_bytes, st_rec_bytes, st_idx_count = build_opencc_stage_table(
        st_phrases, pool_map, pool_units
    )
    tw_bmp, tw_idx_bytes, tw_rec_bytes, tw_idx_count = build_opencc_stage_table(
        tw_phrases, pool_map, pool_units
    )

    pool_bytes = struct.pack(f"<{len(pool_units)}H", *pool_units) if pool_units else b""
    if len(pool_bytes) % 4 != 0:
        pool_bytes += b"\x00\x00"

    buf = bytearray(80)
    st_char_off = len(buf); buf.extend(st_char_bytes)
    tw_var_off = len(buf); buf.extend(tw_var_bytes)
    hk_var_off = len(buf); buf.extend(hk_var_bytes)
    st_bmp_off = len(buf); buf.extend(st_bmp)
    st_idx_off = len(buf); buf.extend(st_idx_bytes)
    st_rec_off = len(buf); buf.extend(st_rec_bytes)
    tw_bmp_off = len(buf); buf.extend(tw_bmp)
    tw_idx_off = len(buf); buf.extend(tw_idx_bytes)
    tw_rec_off = len(buf); buf.extend(tw_rec_bytes)
    pool_off = len(buf); buf.extend(pool_bytes)

    struct.pack_into(
        "<20I",
        buf,
        0,
        LOCC_MAGIC,
        1,
        st_char_count, st_char_off,
        tw_var_count, tw_var_off,
        hk_var_count, hk_var_off,
        st_bmp_off, st_idx_count, st_idx_off, len(st_phrases), st_rec_off,
        tw_bmp_off, tw_idx_count, tw_idx_off, len(tw_phrases), tw_rec_off,
        len(pool_units), pool_off,
    )

    out_path = out_dir / "lokey_opencc.bin"
    out_path.write_bytes(buf)
    return {
        "bytes": len(buf),
        "st_chars": st_char_count,
        "st_phrases": len(st_phrases),
        "tw_phrases": len(tw_phrases),
        "tw_variants": tw_var_count,
        "hk_variants": hk_var_count,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build minimal permissive demo binaries for Lokey-Audit.")
    parser.add_argument("--permissive-dir", type=Path, default=None, help="Path to permissive upstream sources.")
    parser.add_argument("--fetch", action="store_true", help="Download SHA-256 pinned permissive sources into ./vendor/permissive.")
    parser.add_argument("-o", "--output-dir", type=Path, default=None, help="Output directory (defaults to Shared/Resources).")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parent.parent
    out_dir = args.output_dir or (project_root / "Shared" / "Resources")
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.fetch:
        fetch_dest = args.permissive_dir or (project_root / "vendor" / "permissive")
        fetch_pinned_sources(fetch_dest)
        permissive_dir = fetch_dest
    else:
        permissive_dir = resolve_permissive_dir(project_root, args.permissive_dir)

    source_mode = str(permissive_dir) if permissive_dir is not None else "embedded-permissive-fallback"
    print(f"==> Building Lokey-Audit permissive resources (source: {source_mode})")

    lex_stats = compile_demo_lexicon(permissive_dir, out_dir)
    emoji_stats = compile_demo_emoji(permissive_dir, out_dir)
    opencc_stats = compile_demo_opencc(permissive_dir, out_dir)

    print(
        f"    demo_lexicon.bin: {lex_stats['bytes']:,} B "
        f"(syllables={lex_stats['syllables']}, cn_words={lex_stats['chinese_words']:,}, "
        f"jianpin={lex_stats['jianpin']:,}, en={lex_stats['english']:,}, "
        f"assoc={lex_stats['assoc']:,}, lnlm_chars={lex_stats['lnlm_chars']:,})"
    )
    print(f"    lokey_emoji.bin:  {emoji_stats['bytes']:,} B (entries={emoji_stats['entries']:,})")
    print(
        f"    lokey_opencc.bin: {opencc_stats['bytes']:,} B "
        f"(st_chars={opencc_stats['st_chars']}, st_phrases={opencc_stats['st_phrases']}, "
        f"tw_phrases={opencc_stats['tw_phrases']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
