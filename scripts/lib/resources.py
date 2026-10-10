"""Small dependency-free YAML subset parser shared by build tooling."""
from __future__ import annotations
import re

_LIST_ITEM = re.compile(r"^(?P<indent>[ ]*)-(?P<rest>.*)$")
_MAPPING_ITEM = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*:")

class ResourceYamlError(ValueError):
    """Raised when a resource/rule YAML file is malformed."""

def _strip_comment(line: str) -> str:
    quote = ""
    for index, character in enumerate(line):
        if quote:
            if character == quote:
                quote = ""
            continue
        if character in ("'", '"'):
            quote = character
        elif character == "#" and (index == 0 or line[index - 1].isspace()):
            return line[:index]
    return line

def _scalar(text: str):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        return text[1:-1]
    if text == "true": return True
    if text == "false": return False
    if re.fullmatch(r"-?[0-9]+", text): return int(text)
    return text

def _normalize(text: str) -> list[tuple[int, str]]:
    """Split into (indent, token) pairs, expanding '- key: value' items."""
    lines: list[tuple[int, str]] = []
    for raw in text.splitlines():
        stripped = _strip_comment(raw)
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        token = stripped.strip()
        match = _LIST_ITEM.match(stripped)
        if match and _MAPPING_ITEM.match(match.group("rest").strip()):
            body_indent = indent + 2
            lines.append((indent, "-"))
            lines.append((body_indent, match.group("rest").strip()))
        else:
            lines.append((indent, token))
    return lines


def _parse_block(lines: list[tuple[int, str]], index: int):
    if index >= len(lines):
        return None, index
    indent, token = lines[index]
    if token == "-" or token.startswith("- "):
        return _parse_list(lines, index, indent)
    return _parse_map(lines, index, indent)


def _parse_map(lines: list[tuple[int, str]], index: int, indent: int):
    result: dict = {}
    while index < len(lines):
        current_indent, token = lines[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            index += 1
            continue
        if token == "-" or token.startswith("- "):
            break
        key, separator, value = token.partition(":")
        if not separator:
            index += 1
            continue
        key = key.strip()
        value = value.strip()
        index += 1
        if value:
            result[key] = _scalar(value)
            continue
        if index < len(lines) and lines[index][0] > indent:
            child, index = _parse_block(lines, index)
            result[key] = child
        else:
            result[key] = {}
    return result, index


def _parse_list(lines: list[tuple[int, str]], index: int, indent: int):
    items: list = []
    while index < len(lines):
        current_indent, token = lines[index]
        if current_indent != indent or not (token == "-" or token.startswith("- ")):
            break
        rest = token[1:].strip()
        index += 1
        if rest:
            items.append(_scalar(rest))
            continue
        if index < len(lines) and lines[index][0] > indent:
            child, index = _parse_block(lines, index)
            items.append(child)
        else:
            items.append(None)
    return items, index



def load_yaml(text: str) -> dict:
    lines = _normalize(text)
    value, _ = _parse_block(lines, 0)
    if not isinstance(value, dict):
        raise ResourceYamlError("top level of a YAML file must be a mapping")
    return value
