"""Shared Swift naming helpers for schema generation tools."""

from __future__ import annotations

import re


ACRONYMS = {
    "api": "API",
    "chatgpt": "ChatGPT",
    "db": "DB",
    "fs": "FS",
    "gpt": "GPT",
    "id": "ID",
    "ids": "IDs",
    "mcp": "MCP",
    "oauth": "OAuth",
    "openai": "OpenAI",
    "pty": "PTY",
    "rpc": "RPC",
}

SWIFT_KEYWORDS = {
    "as", "break", "case", "catch", "class", "continue", "default", "defer",
    "do", "else", "enum", "extension", "fallthrough", "false", "for", "func",
    "guard", "if", "import", "in", "init", "internal", "is", "let", "nil",
    "operator", "private", "protocol", "public", "repeat", "return", "self",
    "static", "struct", "subscript", "super", "switch", "throw", "true", "try",
    "var", "where", "while",
}


def split_identifier(value: str) -> list[str]:
    pieces: list[str] = []
    for part in re.split(r"[^A-Za-z0-9]+", value):
        if not part:
            continue
        pieces.extend(re.findall(r"[A-Z]?\d+|[A-Z]+(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+", part))
    return pieces


def swift_word(part: str) -> str:
    return ACRONYMS.get(part.lower(), part[:1].upper() + part[1:])


def swift_type_suffix(name: str) -> str:
    parts = split_identifier(name)
    if not parts:
        return "Unnamed"
    suffix = "".join(swift_word(part) for part in parts)
    if suffix[:1].isdigit():
        suffix = "_" + suffix
    return suffix


def swift_member_name(value: str) -> str:
    parts = split_identifier(value)
    if not parts:
        return "value"
    first = parts[0]
    name = first[:1].lower() + first[1:] + "".join(swift_word(part) for part in parts[1:])
    if name[:1].isdigit():
        name = "_" + name
    if name in SWIFT_KEYWORDS:
        name = f"`{name}`"
    return name
