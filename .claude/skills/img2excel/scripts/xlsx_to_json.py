# -*- coding: utf-8 -*-
"""img2excel skill: convert a workbook produced by this skill into JSON for diagram generation.

Usage: python -I xlsx_to_json.py <input.xlsx> [output.json]
"""
import json
import re
import sys
from pathlib import Path

from openpyxl import load_workbook

KEYMAP = {
    "序号": "id",
    "分组/阶段": "group",
    "节点名称": "name",
    "节点类型": "type",
    "形状(符号)": "shape",
    "形状(示例值)": "shape_example",
    "上游节点": "upstream",
    "备注": "note",
}
EMPTY = {None, "", "—", "-"}


def clean(v):
    return "" if v in EMPTY else str(v).strip()


def parse_upstream(v):
    v = clean(v)
    if not v:
        return []
    return [p.strip() for p in re.split(r"[,,、;;]", v) if p.strip()]


def convert(xlsx_path, json_path):
    wb = load_workbook(xlsx_path, data_only=True)
    doc = {"meta": {}, "graphs": {}}

    for name in wb.sheetnames:
        ws = wb[name]
        rows = [[c.value for c in row] for row in ws.iter_rows()]
        if not rows:
            continue
        if name == "说明":
            for row in rows[1:]:
                if row and clean(row[0]):
                    doc["meta"][clean(row[0])] = clean(row[1]) if len(row) > 1 else ""
            continue
        header = [clean(h) for h in rows[0]]
        keys = [KEYMAP.get(h, h) for h in header]
        nodes = []
        for row in rows[1:]:
            if all(v in EMPTY for v in row):
                continue
            node = {}
            for k, v in zip(keys, row):
                if k == "upstream":
                    node[k] = parse_upstream(v)
                elif k == "id":
                    node[k] = int(v) if clean(v).isdigit() else clean(v)
                else:
                    node[k] = clean(v)
            nodes.append(node)
        doc["graphs"][name] = {"nodes": nodes, "edges": [
            {"from": up, "to": n["name"]} for n in nodes for up in n.get("upstream", [])
        ]}

    Path(json_path).write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
    return doc


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python -I xlsx_to_json.py <input.xlsx> [output.json]")
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".json")
    doc = convert(src, dst)
    for g, body in doc["graphs"].items():
        print(f"{g}: {len(body['nodes'])} nodes, {len(body['edges'])} edges")
    print("meta keys:", len(doc["meta"]), "| saved:", dst)
