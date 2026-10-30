#!/usr/bin/env python3
"""Static checks for Cron: action catalog, localizations, Info.plist, assets and project settings.

Behaviour is tested by the Swift Testing target (`xcodebuild test -scheme Cron`).
Pass --with-swift-tests to run it from here as well.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "Cron"
VIEWS = APP_DIR / "Views"
MODEL = APP_DIR / "Model"
CATALOG = VIEWS / "ActionCatalog.swift"
ACTION_TYPE = MODEL / "ActionType.swift"
INFO_PLIST = APP_DIR / "Info.plist"
APPICON = APP_DIR / "Assets.xcassets" / "AppIcon.appiconset"
PROJECT = ROOT / "Cron.xcodeproj" / "project.pbxproj"
REPORTS = ROOT / "TestReports"

STRING_LITERAL = r'"((?:[^"\\]|\\.)*)"'


@dataclass
class Check:
    area: str
    name: str
    status: str
    details: str = ""


def add(checks: list[Check], area: str, name: str, ok: bool, details: str = "") -> None:
    checks.append(Check(area, name, "OK" if ok else "FAIL", details))


def swift_sources() -> list[Path]:
    return sorted(APP_DIR.rglob("*.swift"))


# MARK: - Catalog


def parse_action_cases() -> list[str]:
    text = ACTION_TYPE.read_text(encoding="utf-8")
    start = text.index("enum TaskActionType")
    body = text[start : text.index("var id: String", start)]
    return re.findall(r"^\s+case (\w+)$", body, re.MULTILINE)


def parse_catalog() -> tuple[list[dict], list[dict]]:
    text = CATALOG.read_text(encoding="utf-8")
    categories = [
        {"id": match.group(1).strip('"'), "titleKey": match.group(2)}
        for match in re.finditer(r'ActionCatalogCategory\(id:\s*([^,]+),\s*titleKey:\s*' + STRING_LITERAL, text)
    ]
    for category in categories:
        if category["id"] == "libraryID":
            category["id"] = "library"

    items_block = text[text.index("static let items = [") : text.index("private static func item(")]
    items = []
    for match in re.finditer(r'item\("([^"]+)",\s*\[([^\]]*)\],\s*\.(\w+)(?:,\s*' + STRING_LITERAL + r')?\)', items_block):
        items.append({
            "id": match.group(1),
            "categoryIDs": re.findall(r'"([^"]+)"', match.group(2)),
            "actionType": match.group(3),
            "titleOverride": match.group(4),
        })
    return categories, items


def catalog_checks(checks: list[Check]) -> list[dict]:
    action_cases = parse_action_cases()
    categories, items = parse_catalog()
    category_ids = [c["id"] for c in categories]
    item_ids = [i["id"] for i in items]
    counts = Counter(c for item in items for c in item["categoryIDs"])

    add(checks, "Catalog", "Action types found", len(action_cases) > 0, f"{len(action_cases)} types")
    add(checks, "Catalog", "Catalog items found", len(items) > 0, f"{len(items)} items")
    add(checks, "Catalog", "Unique category IDs", len(category_ids) == len(set(category_ids)))
    add(checks, "Catalog", "Unique item IDs", len(item_ids) == len(set(item_ids)))

    unknown_categories = sorted({c for i in items for c in i["categoryIDs"] if c not in category_ids})
    add(checks, "Catalog", "Item categories exist", not unknown_categories, ", ".join(unknown_categories))

    unknown_actions = sorted({i["actionType"] for i in items if i["actionType"] not in action_cases})
    add(checks, "Catalog", "Item action types exist", not unknown_actions, ", ".join(unknown_actions))

    unreachable = sorted(set(action_cases) - {i["actionType"] for i in items})
    add(checks, "Catalog", "Every action type is in the library", not unreachable, ", ".join(unreachable))

    empty = sorted(c for c in category_ids if c != "library" and counts[c] == 0)
    add(checks, "Catalog", "No empty categories", not empty, ", ".join(empty))

    add(checks, "Catalog", "Every item has a category", all(i["categoryIDs"] for i in items))
    return items


# MARK: - Localization


def used_localization_keys() -> set[str]:
    keys: set[str] = set()

    for path in swift_sources():
        text = path.read_text(encoding="utf-8")
        keys.update(re.findall(r"\bL\(" + STRING_LITERAL + r"\)", text))

        if path.parent == VIEWS:
            keys.update(re.findall(r"\b(?:title|placeholder|text):\s*" + STRING_LITERAL, text))
            # Helpers that pass their first argument to L(), e.g. addButton("Add folder", kind: …).
            keys.update(re.findall(r"\baddButton\(" + STRING_LITERAL, text))
            # Enum cases whose raw value is shown through L(rawValue), e.g. editor tab names.
            keys.update(re.findall(r"^\s+case \w+ = " + STRING_LITERAL + r"$", text, re.MULTILINE))

        # Shortcuts actions: LocalizedStringResource literals are looked up in Localizable.strings.
        if "import AppIntents" in text:
            keys.update(re.findall(r"(?:LocalizedStringResource\s*=|IntentDescription\(|\btitle:|\bname:|return)\s*" + STRING_LITERAL, text))

        # Model enums return localization keys from *Key properties.
        for block in re.finditer(r"var \w*(?:titleKey|descriptionKey|reasonKey|amountTitleKey)[^{]*\{(.*?)\n    \}", text, re.DOTALL):
            keys.update(re.findall(r"return " + STRING_LITERAL, block.group(1)))

    _, items = parse_catalog()
    keys.update(i["titleOverride"] for i in items if i["titleOverride"])
    catalog_text = CATALOG.read_text(encoding="utf-8")
    keys.update(re.findall(r"titleKey:\s*" + STRING_LITERAL, catalog_text))

    # Interval unit raw values are used as keys ("minutes", "hours", "days").
    keys.update({"minutes", "hours", "days"})
    def is_text(key: str) -> bool:
        # Placeholders such as paths, URLs, commands and constants are shown as is.
        return bool(key) and key != "Cron" and "\\(" not in key and not key.startswith(("/", "http")) and not re.fullmatch(r"[A-Z0-9_ .\-]+", key)

    return {key for key in keys if is_text(key)}


def parse_strings(path: Path) -> tuple[dict[str, str], list[str]]:
    entries: dict[str, str] = {}
    duplicates: list[str] = []
    for match in re.finditer(STRING_LITERAL + r"\s*=\s*" + STRING_LITERAL + r"\s*;", path.read_text(encoding="utf-8")):
        key = match.group(1)
        if key in entries:
            duplicates.append(key)
        entries[key] = match.group(2)
    return entries, duplicates


def localization_checks(checks: list[Check]) -> None:
    used = used_localization_keys()
    languages = sorted(APP_DIR.glob("*.lproj"))
    english, _ = parse_strings(APP_DIR / "en.lproj" / "Localizable.strings")

    add(checks, "Localization", "Languages", len(languages) == 43, f"{len(languages)} lproj folders")
    add(checks, "Localization", "Keys used in code", len(used) > 0, f"{len(used)} keys")

    for lproj in languages:
        path = lproj / "Localizable.strings"
        lint = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
        entries, duplicates = parse_strings(path)
        missing = sorted(used - entries.keys())
        add(checks, "Localization", f"{lproj.stem}: valid file", lint.returncode == 0, lint.stdout.strip())
        add(checks, "Localization", f"{lproj.stem}: all used keys translated", not missing, ", ".join(missing[:15]))
        add(checks, "Localization", f"{lproj.stem}: no duplicate keys", not duplicates, ", ".join(duplicates[:10]))
        add(checks, "Localization", f"{lproj.stem}: same keys as English", entries.keys() == english.keys(),
            ", ".join(sorted(entries.keys() ^ english.keys())[:10]))

    unused = sorted(english.keys() - used)
    checks.append(Check("Localization", "Unused English keys", "OK" if not unused else "INFO", f"{len(unused)}: " + ", ".join(unused[:20])))


# MARK: - App bundle and project


def bundle_checks(checks: list[Check]) -> None:
    info = plistlib.loads(INFO_PLIST.read_bytes())
    add(checks, "Info.plist", "Menu bar app (LSUIElement)", info.get("LSUIElement") is True)
    for key in ["NSAppleEventsUsageDescription", "NSScreenCaptureUsageDescription"]:
        add(checks, "Info.plist", f"{key} present", bool(info.get(key)))

    contents = APPICON / "Contents.json"
    images = json.loads(contents.read_text()).get("images", []) if contents.exists() else []
    missing_files = [i["filename"] for i in images if i.get("filename") and not (APPICON / i["filename"]).exists()]
    add(checks, "Assets", "App icon files exist", bool(images) and not missing_files, ", ".join(missing_files))

    project = PROJECT.read_text(encoding="utf-8")
    add(checks, "Project", "Swift 6 language mode", "SWIFT_VERSION = 5" not in project and "SWIFT_VERSION = 6.0;" in project)
    add(checks, "Project", "Deployment target macOS 15.0", re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([\d.]+);", project) and
        set(re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([\d.]+);", project)) == {"15.0"})
    add(checks, "Project", "Universal build (no hard-coded ARCHS)", "ARCHS = x86_64;" not in project)
    add(checks, "Project", "Swift Testing target present", "CronTests.xctest" in project)

    sources = "\n".join(p.read_text(encoding="utf-8") for p in swift_sources())
    add(checks, "Safety", "No pkill -f", "/usr/bin/pkill -f" not in sources)
    add(checks, "Safety", "No forced app termination", "forceTerminate" not in sources)
    add(checks, "Safety", "Scheduler timer in .common run loop mode", "forMode: .common" in sources)


def swift_tests(checks: list[Check]) -> None:
    result = subprocess.run(
        ["xcodebuild", "test", "-project", str(ROOT / "Cron.xcodeproj"), "-scheme", "Cron", "-destination", "platform=macOS",
         "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM="],
        cwd=ROOT, capture_output=True, text=True, timeout=900,
    )
    output = result.stdout + result.stderr
    failures = [line for line in output.splitlines() if "✘" in line]
    add(checks, "Swift tests", "xcodebuild test", result.returncode == 0 and "** TEST SUCCEEDED **" in output,
        "\n".join(failures[:20]) or output[-400:])


# MARK: - Report


def write_reports(checks: list[Check]) -> tuple[Path, Path]:
    REPORTS.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    json_path = REPORTS / f"static-{timestamp}.json"
    md_path = REPORTS / f"static-{timestamp}.md"
    summary = dict(Counter(c.status for c in checks))

    json_path.write_text(json.dumps({"generatedAt": timestamp, "summary": summary, "checks": [c.__dict__ for c in checks]},
                                    ensure_ascii=False, indent=2), encoding="utf-8")

    lines = [f"# Cron static checks", "", f"- Date: {timestamp}", f"- Results: {summary}", ""]
    for area in dict.fromkeys(c.area for c in checks):
        lines += [f"## {area}", "", "| Status | Check | Details |", "|---|---|---|"]
        for c in (c for c in checks if c.area == area):
            details = c.details.replace("|", "\\|").replace("\n", "<br>")
            lines.append(f"| {c.status} | {c.name} | {details} |")
        lines.append("")
    md_path.write_text("\n".join(lines), encoding="utf-8")
    return md_path, json_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--with-swift-tests", action="store_true", help="also run the Swift Testing target")
    args = parser.parse_args()

    checks: list[Check] = []
    catalog_checks(checks)
    localization_checks(checks)
    bundle_checks(checks)
    if args.with_swift_tests:
        swift_tests(checks)

    md_path, json_path = write_reports(checks)
    summary = Counter(c.status for c in checks)
    print(f"REPORT_MD={md_path}")
    print(f"REPORT_JSON={json_path}")
    print(f"SUMMARY={dict(summary)}")
    failures = [c for c in checks if c.status == "FAIL"]
    if failures:
        print("FAILURES:")
        for c in failures:
            print(f"- [{c.area}] {c.name}: {c.details}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
