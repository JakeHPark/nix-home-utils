import os
import stat
import sys
import tempfile


def skip_string(text: str, index: int) -> int:
    index += 1
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == '"':
            return index + 1
        index += 1
    return index


def skip_indented_string(text: str, index: int) -> int:
    index += 2
    while index < len(text):
        if text.startswith("''", index):
            return index + 2
        index += 1
    return index


def skip_line_comment(text: str, index: int) -> int:
    newline = text.find("\n", index)
    return len(text) if newline == -1 else newline + 1


def skip_block_comment(text: str, index: int) -> int:
    end = text.find("*/", index + 2)
    return len(text) if end == -1 else end + 2


def skip_ignored(text: str, index: int) -> int:
    while index < len(text):
        if text[index].isspace():
            index += 1
        elif text.startswith("#", index):
            index = skip_line_comment(text, index)
        elif text.startswith("/*", index):
            index = skip_block_comment(text, index)
        else:
            return index
    return index


def skip_nix_expression(text: str, index: int) -> int:
    depth = 0
    while index < len(text):
        if text.startswith("''", index):
            index = skip_indented_string(text, index)
            continue
        if text[index] == '"':
            index = skip_string(text, index)
            continue
        if text.startswith("#", index):
            index = skip_line_comment(text, index)
            continue
        if text.startswith("/*", index):
            index = skip_block_comment(text, index)
            continue

        char = text[index]
        if char in "{[(":
            depth += 1
        elif char in "}])":
            if depth > 0:
                depth -= 1
        elif char == ";" and depth == 0:
            return index
        index += 1
    return index


def find_top_level_attrset(text: str) -> tuple[int, int]:
    start = skip_ignored(text, 0)
    if start >= len(text) or text[start] != "{":
        raise ValueError("config.nix must start with a Nix attribute set")

    depth = 0
    index = start
    while index < len(text):
        if text.startswith("''", index):
            index = skip_indented_string(text, index)
            continue
        if text[index] == '"':
            index = skip_string(text, index)
            continue
        if text.startswith("#", index):
            index = skip_line_comment(text, index)
            continue
        if text.startswith("/*", index):
            index = skip_block_comment(text, index)
            continue

        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return start, index
        index += 1

    raise ValueError("config.nix has an unterminated top-level attribute set")


def is_attr_boundary(text: str, start: int, end: int) -> bool:
    before_ok = start == 0 or not (text[start - 1].isalnum() or text[start - 1] in "_-'")
    after_ok = end >= len(text) or not (text[end].isalnum() or text[end] in "_-'")
    return before_ok and after_ok


def find_allow_unfree_assignment(text: str, start: int, end: int) -> tuple[int, int] | None:
    depth = 0
    index = start + 1
    attr = "allowUnfree"

    while index < end:
        if text.startswith("''", index):
            index = skip_indented_string(text, index)
            continue
        if text[index] == '"':
            index = skip_string(text, index)
            continue
        if text.startswith("#", index):
            index = skip_line_comment(text, index)
            continue
        if text.startswith("/*", index):
            index = skip_block_comment(text, index)
            continue

        char = text[index]
        if char in "{[(":
            depth += 1
            index += 1
            continue
        if char in "}])":
            if depth > 0:
                depth -= 1
            index += 1
            continue

        if depth == 0 and text.startswith(attr, index) and is_attr_boundary(text, index, index + len(attr)):
            after_attr = skip_ignored(text, index + len(attr))
            if after_attr < end and text[after_attr] == "=":
                value_start = skip_ignored(text, after_attr + 1)
                value_end = skip_nix_expression(text, value_start)
                if value_end < len(text) and text[value_end] == ";":
                    return value_start, value_end
        index += 1

    return None


def patch_allow_unfree(text: str) -> str:
    if text.strip() == "":
        return "{\n  allowUnfree = true;\n}\n"

    start, end = find_top_level_attrset(text)
    existing = find_allow_unfree_assignment(text, start, end)
    if existing is not None:
        value_start, value_end = existing
        return text[:value_start] + "true" + text[value_end:]

    if text[end - 1] == "\n":
        insertion = "  allowUnfree = true;\n"
    else:
        insertion = "\n  allowUnfree = true;\n"
    return text[:end] + insertion + text[end:]


def atomic_write(path: str, text: str) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)

    fd, temp_path = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.tmp.", dir=directory, text=True)
    try:
        if os.path.exists(path):
            mode = stat.S_IMODE(os.stat(path).st_mode)
            os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temp_path, path)
    except Exception:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_nix_config.py PATH")

    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        text = ""

    atomic_write(path, patch_allow_unfree(text))


if __name__ == "__main__":
    main()
