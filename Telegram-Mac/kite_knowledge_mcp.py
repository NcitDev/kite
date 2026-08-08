#!/usr/bin/python3
"""Read-only MCP server for a Kite local Markdown integration."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Optional


MAX_FILE_BYTES = 1_048_576
MAX_SCANNED_FILES = 5_000


def write_message(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def text_result(text: str, is_error: bool = False) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


class KnowledgeServer:
    def __init__(self, root: Path) -> None:
        self.root = root.expanduser().resolve(strict=True)
        if not self.root.is_dir():
            raise ValueError("root must be a directory")
        self.instructions = os.environ.get("TELEGRAMWORK_INTEGRATION_INSTRUCTIONS", "").strip()

    def resolve_note(self, relative_path: str) -> Path:
        candidate = (self.root / relative_path).resolve(strict=True)
        try:
            candidate.relative_to(self.root)
        except ValueError as error:
            raise ValueError("path is outside the configured vault") from error
        if candidate.suffix.lower() != ".md" or not candidate.is_file():
            raise ValueError("path must identify a Markdown note")
        if candidate.stat().st_size > MAX_FILE_BYTES:
            raise ValueError("note is larger than the 1 MB read limit")
        return candidate

    def notes(self, prefix: str = ""):
        normalized_prefix = prefix.strip("/ ")
        start = self.root if not normalized_prefix else (self.root / normalized_prefix).resolve()
        try:
            start.relative_to(self.root)
        except ValueError:
            return
        if not start.exists() or not start.is_dir():
            return
        count = 0
        for path in start.rglob("*.md"):
            if count >= MAX_SCANNED_FILES:
                return
            try:
                relative = path.relative_to(self.root)
                if any(part.startswith(".") for part in relative.parts):
                    continue
                if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
                    continue
            except OSError:
                continue
            count += 1
            yield path, relative.as_posix()

    def list_notes(self, arguments: dict[str, Any]) -> dict[str, Any]:
        prefix = str(arguments.get("prefix", ""))
        limit = max(1, min(int(arguments.get("limit", 200)), 500))
        paths = [relative for _, relative in self.notes(prefix)]
        paths.sort(key=str.casefold)
        guidance = f"\n\nIntegration guidance: {self.instructions}" if self.instructions else ""
        return text_result("\n".join(paths[:limit]) + guidance)

    def read_note(self, arguments: dict[str, Any]) -> dict[str, Any]:
        relative_path = str(arguments.get("path", ""))
        max_chars = max(200, min(int(arguments.get("max_chars", 12_000)), 50_000))
        note = self.resolve_note(relative_path)
        content = note.read_text(encoding="utf-8", errors="replace")[:max_chars]
        return text_result(f"[{note.relative_to(self.root).as_posix()}]\n{content}")

    def search_notes(self, arguments: dict[str, Any]) -> dict[str, Any]:
        query = str(arguments.get("query", "")).strip()
        limit = max(1, min(int(arguments.get("limit", 8)), 20))
        tokens = list(dict.fromkeys(re.findall(r"[\w-]{3,}", query.casefold())))[:20]
        if not tokens:
            return text_result("Provide a more specific search query.", is_error=True)
        matches: list[tuple[int, str, str]] = []
        for path, relative in self.notes():
            try:
                content = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            folded_path = relative.casefold()
            folded_content = content.casefold()
            score = sum(6 for token in tokens if token in folded_path)
            positions = [folded_content.find(token) for token in tokens]
            positions = [position for position in positions if position >= 0]
            score += len(positions) * 2
            if query.casefold() in folded_content:
                score += 12
            if score == 0:
                continue
            position = min(positions) if positions else 0
            start = max(0, position - 400)
            excerpt = content[start : start + 1_400].strip()
            matches.append((score, relative, excerpt))
        matches.sort(key=lambda item: (-item[0], item[1].casefold()))
        if not matches:
            return text_result("No matching Markdown notes were found.")
        rendered = [f"[{relative}]\n{excerpt}" for _, relative, excerpt in matches[:limit]]
        guidance = f"Integration guidance: {self.instructions}\n\n" if self.instructions else ""
        return text_result(guidance + "\n\n".join(rendered))

    def tools(self) -> list[dict[str, Any]]:
        return [
            {
                "name": "search_notes",
                "description": "Search the configured Obsidian vault's Markdown notes. Read-only. Returns relative source paths and excerpts.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "limit": {"type": "integer", "minimum": 1, "maximum": 20},
                    },
                    "required": ["query"],
                    "additionalProperties": False,
                },
                "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
            },
            {
                "name": "read_note",
                "description": "Read one Markdown note by its relative vault path. Read-only and limited to the configured vault.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "max_chars": {"type": "integer", "minimum": 200, "maximum": 50000},
                    },
                    "required": ["path"],
                    "additionalProperties": False,
                },
                "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
            },
            {
                "name": "list_notes",
                "description": "List Markdown note paths, optionally below a relative folder prefix. Read-only.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "prefix": {"type": "string"},
                        "limit": {"type": "integer", "minimum": 1, "maximum": 500},
                    },
                    "additionalProperties": False,
                },
                "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
            },
        ]

    def handle(self, method: str, params: dict[str, Any]) -> Optional[dict[str, Any]]:
        if method == "initialize":
            return {
                "protocolVersion": params.get("protocolVersion", "2025-03-26"),
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "kite-knowledge", "version": "1.0.0"},
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": self.tools()}
        if method == "tools/call":
            name = str(params.get("name", ""))
            arguments = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
            try:
                if name == "search_notes":
                    return self.search_notes(arguments)
                if name == "read_note":
                    return self.read_note(arguments)
                if name == "list_notes":
                    return self.list_notes(arguments)
                return text_result(f"Unknown tool: {name}", is_error=True)
            except (OSError, UnicodeError, ValueError) as error:
                return text_result(str(error), is_error=True)
        if method.startswith("notifications/"):
            return None
        raise ValueError(f"Method not supported: {method}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    server = KnowledgeServer(Path(args.root))
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if not isinstance(request, dict) or "method" not in request:
                continue
            request_id = request.get("id")
            result = server.handle(str(request["method"]), request.get("params") or {})
            if request_id is not None and result is not None:
                write_message({"jsonrpc": "2.0", "id": request_id, "result": result})
        except Exception as error:  # Keep the MCP process alive after a malformed request.
            request_id = request.get("id") if isinstance(locals().get("request"), dict) else None
            if request_id is not None:
                write_message({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(error)}})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
