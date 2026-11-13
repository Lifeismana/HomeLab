#!/usr/bin/env python3
import sys

# Keys whose relative order should be preserved as written
PRESERVE_ORDER_KEYS = {"environment", "label", "podmanargs"}

def logical_lines(text: str):
    """Yield logical lines, joining backslash-continued lines into a list."""
    buf = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped:
            continue
        # Comments inside or before a block are never joined with backslash continuations
        if not buf and stripped.startswith(("#", ";")):
            yield [stripped]
            continue
        buf.append(stripped)
        if not stripped.endswith("\\"):
            yield buf
            buf = []
    if buf:
        yield buf

def format_quadlet(text: str) -> str:
    sections = []
    current_header = None
    current_items = []
    pending_comments = []

    for group in logical_lines(text):
        first = group[0]
        if len(group) == 1 and first.startswith(("#", ";")):
            pending_comments.append(first)
        elif len(group) == 1 and first.startswith("[") and first.endswith("]"):
            if current_header is not None or current_items or pending_comments:
                sections.append((current_header, current_items, pending_comments))
                pending_comments = []
            current_header = first
            current_items = []
        elif "=" in first:
            key, val = first.split("=", 1)
            key_clean = key.strip()
            first_norm = f"{key_clean}={val.strip()}"
            # Indent continuation lines by 2 spaces
            rest_norm = [f"  {line}" for line in group[1:]]
            full_directive = "\n".join([first_norm] + rest_norm)

            if key_clean.lower() in PRESERVE_ORDER_KEYS:
                sort_key = (key_clean.lower(), "")
            else:
                sort_key = (key_clean.lower(), full_directive.lower())

            current_items.append((sort_key, pending_comments, full_directive))
            pending_comments = []
        else:
            full_directive = "\n".join(group)
            current_items.append(((first.lower(), ""), pending_comments, full_directive))
            pending_comments = []

    if current_header is not None or current_items or pending_comments:
        sections.append((current_header, current_items, pending_comments))

    out = []
    for header, items, trailing_comments in sections:
        block = []
        if header:
            block.append(header)
        for _, comments, directive in sorted(items, key=lambda x: x[0]):
            block.extend(comments)
            block.append(directive)
        block.extend(trailing_comments)
        out.append("\n".join(block))

    return "\n\n".join(out) + "\n"

if __name__ == "__main__":
    if "--check" in sys.argv:
        failed = False
        for path in [a for a in sys.argv[1:] if a != "--check"]:
            with open(path, "r", encoding="utf-8") as f:
                original = f.read()
            if original != format_quadlet(original):
                print(f"Formatting mismatch: {path}", file=sys.stderr)
                failed = True
        sys.exit(1 if failed else 0)
    else:
        sys.stdout.write(format_quadlet(sys.stdin.read()))
