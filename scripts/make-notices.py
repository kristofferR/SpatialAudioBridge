"""Writes the plain-text notices that SpatialAudioBridge ships for app acknowledgements.

Usage: cargo tree … --format '{p}|{l}' | python3 -I make-notices.py OUTPUT LICENSE LICENSES_DIR STD_HTML RUSTC_VERSION

Reads the runtime crates from standard input, takes their license texts from LICENSES_DIR/<name>-<version>,
and converts the Rust standard library's HTML notices to text. Each distinct license text appears once.
"""
import html
import pathlib
import re
import sys

RULE = "=" * 72


def crates(lines):
    found = {}
    for line in lines:
        package, _, license = line.strip().removesuffix(" (*)").partition("|")
        match = re.match(r"(\S+) v(\S+)", package)
        if match and match[1] != "spatial-audio-core":
            found[(match[1], match[2])] = license
    return sorted(found.items())


def html_to_text(fragment):
    def link(match):
        url, label = match[1], re.sub(r"<[^>]+>", "", match[2])
        return label if label == url or url.startswith("#") else f"{label} ({url})"

    text = re.sub(r'<a [^>]*href="([^"]+)"[^>]*>(.*?)</a>', link, fragment, flags=re.S)
    text = re.sub(r"<h[1-4][^>]*>(.*?)</h[1-4]>", lambda m: f"\n\n{m[1].replace('📦', '').strip()}\n", text, flags=re.S)
    text = re.sub(r"<li[^>]*>", "\n- ", text)
    text = re.sub(r"</?(p|ul|ol|div|br|body|html|head)[^>]*>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    return html.unescape(text)


def standard_library(path):
    source = pathlib.Path(path).read_text()
    source = re.sub(r"<head>.*?</head>", "", source, flags=re.S)
    parts, seen, heading = [], {}, "the Rust Standard Library"
    for prose, block in re.findall(r"(.*?)(?:<pre>(.*?)</pre>|$)", source, flags=re.S):
        headings = re.findall(r"<h[1-4][^>]*>(.*?)</h[1-4]>", prose, flags=re.S)
        heading = html_to_text(headings[-1]).replace("📦", "").strip() if headings else heading
        parts.append(html_to_text(prose))
        if block:
            if block in seen:
                parts.append(f"\n[Same text as for {seen[block]} above.]\n")
            else:
                seen[block] = heading
                parts.append("\n" + html.unescape(block).strip("\n") + "\n")
    return "".join(parts)


def main():
    output, license_path, licenses_dir, std_html, rustc_version = sys.argv[1:]
    runtime = crates(sys.stdin)
    texts = {}  # license text -> sources it applies to
    texts.setdefault(pathlib.Path(license_path).read_text(), []).append("SpatialAudioBridge (LICENSE)")
    for (name, version), _ in runtime:
        folder = pathlib.Path(licenses_dir) / f"{name}-{version}"
        files = sorted(folder.iterdir()) if folder.is_dir() else []
        if not files:
            sys.exit(f"make-notices: no license texts in {folder}; add them for {name} {version}")
        for file in files:
            texts.setdefault(file.read_text(), []).append(f"{name} {version} ({file.name})")

    lines = [
        "SpatialAudioBridge notices",
        "",
        "SpatialAudioBridge is licensed under the Apache License, Version 2.0. Its Rust core contains the",
        f"components below and the Rust standard library, built with rustc {rustc_version}. Their notices",
        "follow; each license text appears once, with the components it applies to.",
        "",
        "Components:",
        *(f"- {name} {version}, {license}" for (name, version), license in runtime),
    ]
    for text, sources in texts.items():
        lines += ["", RULE, "Applies to: " + ", ".join(sources), RULE, "", text.strip("\n")]
    lines += ["", RULE, f"The Rust Standard Library, rustc {rustc_version}", RULE, standard_library(std_html)]
    body = "\n".join(lines)
    body = "\n".join(line.rstrip() for line in body.splitlines())
    body = re.sub(r"\n{3,}", "\n\n", body).strip() + "\n"
    pathlib.Path(output).write_text(body)


main()
