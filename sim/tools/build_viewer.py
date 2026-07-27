#!/usr/bin/env python3
"""
Combines a trace.csv (from sim/tb/gen_trace.v) and the viewer template into
a single self-contained HTML file, ready to open in a browser or publish.

Usage: python build_viewer.py trace.csv -o pipeline-viewer.html
"""
import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        trace_json_path = tmp.name
    try:
        subprocess.run(
            [sys.executable, os.path.join(HERE, "gen_trace.py"), args.csv_path, "-o", trace_json_path],
            check=True,
        )
        with open(trace_json_path, encoding="utf-8") as f:
            trace_json = f.read()
    finally:
        os.remove(trace_json_path)

    with open(os.path.join(HERE, "viewer_template.html"), encoding="utf-8") as f:
        html = f.read()
    html = html.replace("__TRACE_JSON__", trace_json)

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"-> {args.output} ({len(html)} bytes)")


if __name__ == "__main__":
    main()
