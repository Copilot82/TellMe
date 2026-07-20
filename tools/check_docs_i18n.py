#!/usr/bin/env python3
"""Validate the completeness and structural parity of translated documentation."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DOCUMENTATION_ROOT = REPOSITORY_ROOT / "docs"
ENGLISH_SUFFIX = ".en.md"
CYRILLIC = re.compile(r"[А-Яа-яЁё]")
HEADING = re.compile(r"^(#{1,6})\s+")
FENCE = re.compile(r"^\s*(?P<marker>`{3,}|~{3,})(?P<info>.*)$")
ROOT_PAIRS = (
    (REPOSITORY_ROOT / "README.md", REPOSITORY_ROOT / "README.en.md"),
    (REPOSITORY_ROOT / "SECURITY.md", REPOSITORY_ROOT / "SECURITY.en.md"),
    (REPOSITORY_ROOT / "CHANGELOG.md", REPOSITORY_ROOT / "CHANGELOG.en.md"),
)


def translated_path(source: Path) -> Path:
    """Return the suffix-based English path used by mkdocs-static-i18n."""

    return source.with_name(f"{source.stem}.en.md")


def document_structure(path: Path) -> tuple[list[int], list[str]]:
    """Extract heading levels and fenced-code languages outside fenced blocks."""

    headings: list[int] = []
    code_languages: list[str] = []
    active_marker: str | None = None

    for line in path.read_text(encoding="utf-8").splitlines():
        fence = FENCE.match(line)
        if fence:
            marker = fence.group("marker")
            if active_marker is None:
                active_marker = marker[0]
                code_languages.append(fence.group("info").strip())
            elif marker[0] == active_marker:
                active_marker = None
            continue

        if active_marker is None and (heading := HEADING.match(line)):
            headings.append(len(heading.group(1)))

    return headings, code_languages


def cyrillic_lines(path: Path) -> list[int]:
    """Return lines containing untranslated Cyrillic text."""

    return [
        number
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1)
        if CYRILLIC.search(line)
    ]


def source_documents() -> list[Path]:
    """Return default-locale documents that require an English counterpart."""

    return sorted(
        path
        for path in DOCUMENTATION_ROOT.rglob("*.md")
        if path.is_file() and not path.name.endswith(ENGLISH_SUFFIX)
    )


def main() -> int:
    failures: list[str] = []
    pairs = [(source, translated_path(source)) for source in source_documents()]
    pairs.extend(ROOT_PAIRS)
    expected_translations = {translation.resolve() for _, translation in pairs}

    for source, translation in pairs:
        relative_translation = translation.relative_to(REPOSITORY_ROOT)
        if not translation.is_file():
            failures.append(f"missing translation: {relative_translation}")
            continue

        if not translation.read_text(encoding="utf-8").strip():
            failures.append(f"empty translation: {relative_translation}")
            continue

        source_headings, source_fences = document_structure(source)
        translated_headings, translated_fences = document_structure(translation)
        if source_headings != translated_headings:
            failures.append(f"heading structure differs: {relative_translation}")
        if source_fences != translated_fences:
            failures.append(f"fenced-code structure differs: {relative_translation}")

        for line in cyrillic_lines(translation):
            failures.append(f"untranslated Cyrillic text: {relative_translation}:{line}")

    for translation in DOCUMENTATION_ROOT.rglob(f"*{ENGLISH_SUFFIX}"):
        if translation.resolve() not in expected_translations:
            failures.append(
                f"translation has no default-locale source: "
                f"{translation.relative_to(REPOSITORY_ROOT)}"
            )

    if failures:
        print("Documentation translation validation failed:", file=sys.stderr)
        print("\n".join(f"- {failure}" for failure in failures), file=sys.stderr)
        return 1

    print(f"Validated documentation translation pairs: {len(pairs)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
