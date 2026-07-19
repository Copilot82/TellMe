#!/usr/bin/env python3
"""Проверяет локальные ссылки в публикуемой Markdown-документации."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DOCUMENT_GLOBS = ("*.md", "docs/**/*.md", ".github/**/*.md")
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\((?P<target>[^)]+)\)")
IGNORED_SCHEMES = {"http", "https", "mailto"}


def markdown_files() -> list[Path]:
    """Возвращает набор документов без дубликатов и generated directories."""

    files = {
        path
        for pattern in DOCUMENT_GLOBS
        for path in REPOSITORY_ROOT.glob(pattern)
        if path.is_file()
    }
    return sorted(files)


def local_target(document: Path, raw_target: str) -> Path | None:
    """Разрешает file part ссылки относительно документа или корня репозитория."""

    target = raw_target.strip().strip("<>").split(maxsplit=1)[0]
    parsed = urlsplit(target)
    if parsed.scheme in IGNORED_SCHEMES or not parsed.path:
        return None

    decoded = unquote(parsed.path)
    if decoded.startswith("/"):
        return REPOSITORY_ROOT / decoded.lstrip("/")
    return document.parent / decoded


def main() -> int:
    failures: list[str] = []
    for document in markdown_files():
        text = document.read_text(encoding="utf-8")
        for match in MARKDOWN_LINK.finditer(text):
            target = local_target(document, match.group("target"))
            if target is None:
                continue
            try:
                resolved = target.resolve(strict=True)
                resolved.relative_to(REPOSITORY_ROOT)
            except (FileNotFoundError, ValueError):
                line = text.count("\n", 0, match.start()) + 1
                shown = match.group("target")
                failures.append(f"{document.relative_to(REPOSITORY_ROOT)}:{line}: {shown}")

    if failures:
        print("Обнаружены недоступные локальные ссылки:", file=sys.stderr)
        print("\n".join(f"- {failure}" for failure in failures), file=sys.stderr)
        return 1

    print(f"Проверено Markdown-файлов: {len(markdown_files())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
