"""Machine readable build-error rules.

The rules live in scripts/data/build-errors/*.yaml.  They are parsed by a
small, dependency-free YAML subset parser on purpose: the build container does
not ship PyYAML, and a rules file that cannot be loaded would silently turn the
analyzer into a no-op -- exactly the failure mode this whole subsystem exists
to prevent.  load_rule_files() therefore raises on a malformed file instead of
skipping it.

Supported subset (everything the rule files use):

* comments (# to end of line, outside quotes) and blank lines
* "key: value" mappings nested by indentation
* "- item" lists, including "- key: value" mapping items
* single/double quoted scalars, true/false booleans, integers
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

CATEGORIES = (
    "EnvironmentError",
    "DependencyError",
    "SourceError",
    "PKGBuildError",
    "PatchError",
    "CompilerError",
    "LinkerError",
    "RuntimeDependencyError",
    "SONAMEError",
    "RepositoryError",
    "CacheError",
    "CIError",
    "InfrastructureError",
    "NetworkError",
    "TestFailure",
    "PackagingError",
    "BuildError",
)

STAGES = (
    "fetch",
    "prepare",
    "configure",
    "compile",
    "link",
    "check",
    "package",
    "verify",
    "publish",
    "dependencies",
    "build",
    "unknown",
)

CONFIDENCE_SCORE = {"high": 3, "medium": 2, "low": 1}

_LIST_ITEM = re.compile(r"^(?P<indent>[ ]*)-(?P<rest>.*)$")
_MAPPING_ITEM = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*:")


class RuleError(RuntimeError):
    """A rule file could not be parsed."""


def _strip_comment(line: str) -> str:
    """Remove a trailing comment without touching quoted text."""
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
    if text == "true":
        return True
    if text == "false":
        return False
    if re.fullmatch(r"-?[0-9]+", text):
        return int(text)
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
        raise RuleError("top level of a rule file must be a mapping")
    return value


@dataclass
class Rule:
    id: str
    category: str
    stage: str
    summary: str
    patterns: list[re.Pattern[str]] = field(default_factory=list)
    confidence: str = "medium"
    root_cause: str = ""
    extract: dict[str, re.Pattern[str]] = field(default_factory=dict)
    action: dict = field(default_factory=dict)
    source: str = ""

    @property
    def score(self) -> int:
        return CONFIDENCE_SCORE.get(self.confidence, 1)

    def match(self, line: str) -> bool:
        return any(pattern.search(line) for pattern in self.patterns)


def _compile_patterns(raw: object, source: str, rule_id: str) -> list[re.Pattern[str]]:
    if raw is None:
        return []
    values = raw if isinstance(raw, list) else [raw]
    compiled = []
    for value in values:
        if not isinstance(value, str):
            continue
        try:
            compiled.append(re.compile(value, re.IGNORECASE))
        except re.error as error:
            raise RuleError(f"{source}:{rule_id}: invalid pattern {value!r}: {error}") from error
    return compiled


def parse_rule(entry: dict, source: str) -> Rule:
    rule_id = str(entry.get("id", "")).strip()
    if not rule_id:
        raise RuleError(f"{source}: a rule is missing its id")
    category = str(entry.get("category", "BuildError")).strip()
    if category not in CATEGORIES:
        raise RuleError(f"{source}:{rule_id}: unknown category {category}")
    stage = str(entry.get("stage", "unknown")).strip()
    if stage not in STAGES:
        raise RuleError(f"{source}:{rule_id}: unknown stage {stage}")
    extract_raw = entry.get("extract") or {}
    if not isinstance(extract_raw, dict):
        raise RuleError(f"{source}:{rule_id}: extract must be a mapping")
    extract = {}
    for key, value in extract_raw.items():
        compiled = _compile_patterns(value, source, rule_id)
        if compiled:
            extract[str(key)] = compiled[0]
    action = entry.get("action") or {}
    if not isinstance(action, dict):
        raise RuleError(f"{source}:{rule_id}: action must be a mapping")
    return Rule(
        id=rule_id,
        category=category,
        stage=stage,
        summary=str(entry.get("summary", "")).strip(),
        patterns=_compile_patterns(entry.get("patterns"), source, rule_id),
        confidence=str(entry.get("confidence", "medium")).strip(),
        root_cause=str(entry.get("root_cause", "")).strip(),
        extract=extract,
        action=action,
        source=source,
    )


def load_rule_files(directory: Path) -> list[Rule]:
    """Load every rule file; a malformed file is fatal, never skipped."""
    if not directory.is_dir():
        raise RuleError(f"rule directory does not exist: {directory}")
    rules: list[Rule] = []
    seen: dict[str, str] = {}
    for path in sorted(directory.glob("*.yaml")):
        document = load_yaml(path.read_text(encoding="utf-8"))
        entries = document.get("rules")
        if entries is None:
            raise RuleError(f"{path.name}: missing top level 'rules' list")
        if not isinstance(entries, list):
            raise RuleError(f"{path.name}: 'rules' must be a list")
        if not entries:
            raise RuleError(f"{path.name}: 'rules' is empty")
        for entry in entries:
            if not isinstance(entry, dict):
                raise RuleError(f"{path.name}: every rule must be a mapping")
            rule = parse_rule(entry, path.name)
            if rule.id in seen:
                raise RuleError(
                    f"duplicate rule id {rule.id} in {path.name} and {seen[rule.id]}"
                )
            seen[rule.id] = path.name
            rules.append(rule)
    if not rules:
        raise RuleError(f"no rules found in {directory}")
    return rules
