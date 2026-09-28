import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from typing import Any


def unescape_kconfig(value: str) -> str:
    result: list[str] = []
    i = 0
    while i < len(value):
        char = value[i]
        if char != "\\":
            result.append(char)
            i += 1
            continue

        i += 1
        if i >= len(value):
            result.append("\\")
            break

        marker = value[i]
        i += 1
        if marker == "s":
            result.append(" ")
        elif marker == "t":
            result.append("\t")
        elif marker == "n":
            result.append("\n")
        elif marker == "r":
            result.append("\r")
        elif marker == "\\":
            result.append("\\")
        elif marker == ";":
            result.append("\\;")
        elif marker == ",":
            result.append("\\,")
        elif marker == "x" and i + 1 < len(value):
            digits = value[i : i + 2]
            try:
                result.append(chr(int(digits, 16)))
                i += 2
            except ValueError:
                result.append("\\x")
        else:
            result.append("\\" + marker)

    return "".join(result)


def escape_byte(char: str) -> str:
    return "".join(f"\\x{byte:02x}" for byte in char.encode("utf-8"))


def escape_kconfig(value: str) -> str:
    if value == "":
        return value

    chars: list[str] = []
    for char in value:
        if char == "\n":
            chars.append("\\n")
        elif char == "\t":
            chars.append("\\t")
        elif char == "\r":
            chars.append("\\r")
        elif char == "\\":
            chars.append("\\\\")
        elif char in "=[]":
            chars.append(escape_byte(char))
        elif ord(char) < 32:
            chars.append(escape_byte(char))
        else:
            chars.append(char)

    if chars[0] == " ":
        chars[0] = "\\s"
    if chars[-1] == " ":
        chars[-1] = "\\s"

    return "".join(chars)


def format_ini_value(value: Any) -> str:
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


KEY_CONFIG_FIELDS = {
    "value",
    "immutable",
    "shellExpand",
    "persistent",
    "escapeValue",
}


def is_ini_atom(value: Any) -> bool:
    return value is None or isinstance(value, (bool, int, float, str))


def is_key_config(value: Any) -> bool:
    return isinstance(value, dict) and any(key in KEY_CONFIG_FIELDS for key in value)


def normalize_key_config(key: str, value: Any) -> dict[str, Any]:
    if is_ini_atom(value):
        return {
            "value": value,
            "immutable": False,
            "shellExpand": False,
            "persistent": False,
            "escapeValue": True,
        }

    if not is_key_config(value):
        raise TypeError(f"INI key {key!r} must be null, bool, int, float, string, or a key config")

    unknown_keys = set(value) - KEY_CONFIG_FIELDS
    if unknown_keys:
        unknown = ", ".join(sorted(unknown_keys))
        raise TypeError(f"INI key {key!r} has unsupported config fields: {unknown}")

    normalized = {
        "value": value.get("value"),
        "immutable": value.get("immutable", False),
        "shellExpand": value.get("shellExpand", False),
        "persistent": value.get("persistent", False),
        "escapeValue": value.get("escapeValue", True),
    }

    if not is_ini_atom(normalized["value"]):
        raise TypeError(f"INI key {key!r} value must be null, bool, int, float, or string")

    for flag in ["immutable", "shellExpand", "persistent", "escapeValue"]:
        if not isinstance(normalized[flag], bool):
            raise TypeError(f"INI key {key!r} field {flag!r} must be a boolean")

    return normalized


def flatten_patch(
    node: dict[str, Any],
    group: tuple[str, ...] = (),
    flattened: dict[tuple[str, ...], dict[str, dict[str, Any]]] | None = None,
) -> dict[tuple[str, ...], dict[str, dict[str, Any]]]:
    if flattened is None:
        flattened = {}

    for name, value in node.items():
        if is_ini_atom(value) or is_key_config(value):
            flattened.setdefault(group, {})[name] = normalize_key_config(name, value)
            continue

        if isinstance(value, dict):
            flatten_patch(value, group + (name,), flattened)
            continue

        raise TypeError(f"INI group or key {name!r} must be an attribute set or INI atom")

    return flattened


@dataclass
class IniValue:
    value: str | None
    immutable: bool = False
    shell_expand: bool = False

    @classmethod
    def from_line(cls, line: str) -> tuple[str, "IniValue"]:
        key_part, separator, value_part = line.partition("=")
        key = key_part.strip()
        flags = ""

        match = re.search(r"\[\$([ei]+)\]$", key)
        if match is not None:
            flags = match.group(1)
            key = key[: match.start()]

        value = value_part.strip() if separator else None
        return (
            unescape_kconfig(key),
            cls(
                value=value,
                immutable="i" in flags,
                shell_expand="e" in flags,
            ),
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "IniValue":
        value = format_ini_value(data["value"])
        if data["escapeValue"]:
            value = escape_kconfig(value)
        return cls(
            value=value,
            immutable=data["immutable"],
            shell_expand=data["shellExpand"],
        )

    def suffix(self) -> str:
        if self.immutable and self.shell_expand:
            return "[$ei]"
        if self.immutable:
            return "[$i]"
        if self.shell_expand:
            return "[$e]"
        return ""

    def to_line(self, key: str) -> str:
        rendered_key = escape_kconfig(key) + self.suffix()
        if self.value is None:
            return rendered_key
        return f"{rendered_key}={self.value}"


class IniPatch:
    def __init__(self, path: str, patch: dict[str, Any]):
        self.path = path
        self.data: dict[tuple[str, ...], dict[str, IniValue]] = {}
        self.patch = flatten_patch(patch)
        self.validate()

    def validate(self) -> None:
        for group, keys in self.patch.items():
            for key, data in keys.items():
                if data["persistent"]:
                    if data["value"] is not None:
                        raise ValueError(
                            f"Persistent INI key {key!r} in group {'/'.join(group)!r} cannot also set a value"
                        )
                    if data["immutable"]:
                        raise ValueError(
                            f"Persistent INI key {key!r} in group {'/'.join(group)!r} cannot be immutable"
                        )
                    if data["shellExpand"]:
                        raise ValueError(
                            f"Persistent INI key {key!r} in group {'/'.join(group)!r} cannot enable shell expansion"
                        )

    def read(self) -> None:
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                current_group: tuple[str, ...] = ()
                for line in handle:
                    stripped = line.strip()
                    if stripped == "":
                        continue
                    if re.match(r"^\[.*\]\s*$", line):
                        group_text = line.rstrip()[1:-1]
                        current_group = tuple(
                            unescape_kconfig(part)
                            for part in group_text.split("][")
                        )
                        self.data.setdefault(current_group, {})
                        continue

                    key, value = IniValue.from_line(line)
                    self.data.setdefault(current_group, {})[key] = value
        except FileNotFoundError:
            pass

    def apply(self) -> None:
        self.read()
        for group, keys in self.patch.items():
            for key, data in keys.items():
                if data["persistent"]:
                    continue
                if data["value"] is None:
                    if group in self.data:
                        self.data[group].pop(key, None)
                    continue
                self.data.setdefault(group, {})[key] = IniValue.from_json(data)

    def save(self) -> None:
        directory = os.path.dirname(self.path)
        if directory:
            os.makedirs(directory, exist_ok=True)

        fd, temp_path = tempfile.mkstemp(
            prefix=f".{os.path.basename(self.path)}.tmp.",
            dir=directory or ".",
            text=True,
        )

        try:
            if os.path.exists(self.path):
                stat_result = os.stat(self.path)
                os.fchmod(fd, stat_result.st_mode)

            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                first_group = True
                for group in sorted(self.data):
                    keys = self.data[group]
                    if not keys:
                        continue

                    if first_group:
                        first_group = False
                    else:
                        handle.write("\n")

                    if group:
                        group_name = "][".join(escape_kconfig(part) for part in group)
                        handle.write(f"[{group_name}]\n")

                    for key, value in keys.items():
                        handle.write(value.to_line(key) + "\n")

            os.replace(temp_path, self.path)
        except Exception:
            try:
                os.unlink(temp_path)
            except FileNotFoundError:
                pass
            raise


def main() -> None:
    if len(sys.argv) != 3:
        raise ValueError(f"Expected path and patch JSON, got {len(sys.argv) - 1} arguments")

    patch = IniPatch(sys.argv[1], json.loads(sys.argv[2]))
    patch.apply()
    patch.save()


if __name__ == "__main__":
    main()
