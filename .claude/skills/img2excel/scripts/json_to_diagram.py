# -*- coding: utf-8 -*-
"""img2excel skill: render a JSON file (produced by xlsx_to_json.py) as a flow-diagram image.

Usage: python -I json_to_diagram.py <input.json> [output.jpg|.png]
  - Layered auto-layout from graphs.*.nodes (upstream fuzzy-matched to edges).
  - T[...] tensor shapes are annotated along the outgoing dataflow edge.
  - W[...] weight shapes are annotated beside the operator with an orange arrow.
  - Writes <output>.html (vector) too; screenshots via headless Edge/Chrome at 2x.
"""
import json
import re
import html as _html
import subprocess
import sys
import tempfile
from pathlib import Path

PAGE, SURFACE = "#f9f9f7", "#fcfcfb"
INK, INK2, MUTED = "#0b0b0b", "#52514e", "#898781"
BORDER = "rgba(11,11,11,0.10)"
ORANGE, ORANGE_T, ORANGE_D = "#eb6834", "#fdebe3", "#b14e21"
GRAY, GRAY_T = "#8a8880", "#f0efec"
BLUE, BLUE_T = "#2a78d6", "#e4eefa"
YELLOW, YELLOW_T = "#b57f00", "#fdf3d9"
VIOLET, VIOLET_T = "#6250d6", "#eae7f9"
MONO = "Cascadia Code, Consolas, monospace"
SANS = "'Segoe UI', 'Microsoft YaHei', system-ui, sans-serif"

BROWSERS = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
]


def norm(s):
    return re.sub(r"[\s()()/&→·\-_⊕]+", "", str(s)).lower()


def twidth(s, size):
    return sum(size if ord(c) > 0x2E7F else size * 0.56 for c in str(s))


def wrap(s, limit=34):
    if len(s) <= limit:
        return [s]
    cut = -1
    for m in re.finditer(r",\s*", s):
        if cut < 0 or abs(m.end() - len(s) / 2) < abs(cut - len(s) / 2):
            cut = m.end()
    return [s[:cut].rstrip(), s[cut:]] if 0 < cut < len(s) else [s]


def style(node):
    t, name = node.get("type", ""), node.get("name", "")
    if node.get("stub"):
        return (VIOLET_T, VIOLET) if node.get("cross") else (YELLOW_T, YELLOW)
    if "缓存" in t:
        return YELLOW_T, YELLOW
    if "Linear" in t or "Linear" in name:
        return ORANGE_T, ORANGE
    if t.startswith("张量"):
        return BLUE_T, BLUE
    return GRAY_T, GRAY


def match(f, nodes, self_id, other_names):
    fn = norm(f)
    if "缓存" in f or "cache" in f.lower():
        return None, "cache"
    pool = [n for n in nodes if norm(n["name"]) == fn and n["id"] != self_id]
    if not pool and len(fn) >= 3:
        pool = [n for n in nodes if n["id"] != self_id and
                (fn in norm(n["name"]) or norm(n["name"]) in fn) and len(norm(n["name"])) >= 2]
    if not pool and len(fn) < 3:
        pool = [n for n in nodes if n["id"] != self_id and
                (norm(n["name"]).startswith(fn) or norm(n["name"]).endswith(fn))]
    if pool:
        prev = [n for n in pool if n["id"] < self_id]
        return (max(prev, key=lambda n: n["id"]) if prev else min(pool, key=lambda n: n["id"])), None
    for on in other_names:
        if fn == norm(on) or (len(fn) >= 3 and len(norm(on)) >= 3 and
                              (fn in norm(on) or norm(on) in fn)):
            return None, "cross"
    return None, "fallback"


def build_panels(doc):
    graphs = list(doc["graphs"].items())
    panels = []
    for gi, (gname, body) in enumerate(graphs):
        nodes = [dict(n) for n in body["nodes"]]
        other = [n["name"] for j, (_, b) in enumerate(graphs) if j != gi for n in b["nodes"]]
        byid = {n["id"]: n for n in nodes}
        edges, stubs = [], {}
        for n in nodes:
            ups = []
            for f in n.get("upstream", []):
                m, kind = match(f, nodes, n["id"], other)
                if m:
                    ups.append(m); edges.append((m["id"], n["id"], False))
                elif kind in ("cross", "cache"):
                    key = norm(f)
                    if key not in stubs:
                        stubs[key] = {"id": f"s{len(stubs)}", "name": f, "stub": True,
                                      "cross": kind == "cross", "shape": "", "shape_example": "",
                                      "_tgt": n["id"]}
                    edges.append((stubs[key]["id"], n["id"], True))
                elif kind == "fallback":
                    for s in ([n["id"] - 1, n["id"] - 2] if "两路" in f else [n["id"] - 1]):
                        if s in byid:
                            ups.append(byid[s]); edges.append((s, n["id"], False))
            n["_ups"] = ups
        for n in nodes:
            n["_d"] = (max((u["_d"] for u in n["_ups"]), default=-1) + 1) if n["_ups"] else \
                      (1 if n.get("upstream") else 0)
        for _ in range(6):  # ALAP:尽量下沉到消费者上一层,消除跨层长边(asap 节点除外)
            changed = False
            for n in sorted(nodes, key=lambda n: -n["id"]):
                if n.get("asap"):
                    continue
                cons = [byid[t]["_d"] for f, t, _ in edges if f == n["id"] and t in byid]
                if cons and min(cons) - 1 > n["_d"]:
                    n["_d"] = min(cons) - 1
                    changed = True
            if not changed:
                break
        allmap = {n["id"]: n for n in nodes}
        for s in stubs.values():
            tgts = [allmap[t]["_d"] for f, t, _ in edges if f == s["id"]]
            s["_d"] = min(tgts)  # 与目标同层,贴边水平接入
            allmap[s["id"]] = s
        layers = [[] for _ in range(max(n["_d"] for n in allmap.values()) + 1)]
        for n in allmap.values():
            layers[n["_d"]].append(n)
        ups_of = {}
        for f, t, _ in edges:
            ups_of.setdefault(t, []).append(f)
        for n in allmap.values():
            s = str(n.get("shape", "") or "")
            ex = str(n.get("shape_example", "") or "")
            n["_flow"], n["_side"], inner = [], [], []
            if s.startswith("T["):
                n["_flow"] = wrap(s) + ([ex] if ex else [])
            elif s.startswith("W["):
                n["_side"] = wrap(s) + ([ex] if ex else [])
            else:
                inner = [x for x in (s, ex) if x]
            n["_inner"] = inner
            nm = ("↫ " if n.get("cross") else "") + n["name"]
            bw = max([twidth(nm, 12.5)] + [twidth(l, 10.5) for l in inner]) + 26
            n["_w"], n["_h"] = bw, 32 + 15 * len(inner)
            flw = max([twidth(l, 10) for l in n["_flow"]], default=0)
            sdw = max([twidth(l, 10) for l in n["_side"]], default=0)
            n["_le"] = bw / 2 + ((sdw + 40) if n["_side"] else 0)
            n["_re"] = max(bw / 2, (10 + flw) if n["_flow"] else 0)
        panels.append({"name": gname, "layers": layers, "edges": edges, "all": allmap,
                       "ups_of": ups_of, "n_nodes": len(nodes), "n_edges": len(edges)})
    return panels


def render(doc, src_name, out_html):
    panels = build_panels(doc)
    TOP, PITCH, GAPX, PGAP, MARG = 152, 96, 30, 46, 36
    pw = [max(max(sum(n["_le"] + n["_re"] for n in L) + GAPX * (len(L) - 1)
              for L in p["layers"] if L) + 70, 420) for p in panels]
    pheights = [24 + (len(p["layers"]) - 1) * PITCH + 76 for p in panels]
    H = TOP + max(pheights) + 44
    W = MARG * 2 + sum(pw) + PGAP * (len(panels) - 1)
    EDGE = "#b3b1a8"
    S = []

    def esc(s): return _html.escape(str(s), quote=True)

    def text(x, y, s, size=12, fill=INK, anchor="middle", weight=400, family=SANS):
        S.append(f'<text x="{x:.0f}" y="{y:.0f}" font-size="{size}" fill="{fill}" '
                 f'text-anchor="{anchor}" font-weight="{weight}" font-family="{family}">{esc(s)}</text>')

    px = MARG
    for p, wpx, ph in zip(panels, pw, pheights):
        p["cx"], p["px"], p["wpx"], p["ph"] = px + wpx / 2, px, wpx, ph
        px += wpx + PGAP

    for p in panels:  # 布点:上→下→上 三轮重心扫动,减少交叉
        downs_of = {}
        for f, t, _ in p["edges"]:
            downs_of.setdefault(f, []).append(t)

        def place(L, p=p):
            tot = sum(n["_le"] + n["_re"] for n in L) + GAPX * (len(L) - 1)
            cur = p["cx"] - tot / 2
            for n in L:
                cur += n["_le"]
                n["_x"] = cur
                cur += n["_re"] + GAPX

        for d, L in enumerate(p["layers"]):
            for n in L:
                n["_y"], n["_x"] = TOP + 24 + d * PITCH, p["cx"]
            place(L) if L else None
        for seq, nbr, alt in [(p["layers"], p["ups_of"], downs_of),
                              (p["layers"][::-1], downs_of, p["ups_of"]),
                              (p["layers"], p["ups_of"], downs_of)]:
            for L in seq:
                if not L:
                    continue
                real = [n for n in L if not n.get("stub")]
                for n in real:
                    xs = [p["all"][o]["_x"] for o in nbr.get(n["id"], []) if o in p["all"]] or \
                         [p["all"][o]["_x"] for o in alt.get(n["id"], []) if o in p["all"]]
                    n["_bc"] = sum(xs) / len(xs) if xs else n["_x"]
                    if n.get("pin") == "left":
                        n["_bc"] -= 1e6
                    elif n.get("pin") == "right":
                        n["_bc"] += 1e6
                real.sort(key=lambda n: n["_bc"])
                order = []
                for n in real:  # 角标硬性粘在目标左侧
                    order += [s for s in L if s.get("stub") and s.get("_tgt") == n["id"]]
                    order.append(n)
                order += [s for s in L if s not in order]
                L[:] = order
                place(L)

    for p in panels:
        S.append(f'<rect x="{p["px"]}" y="{TOP - 46}" width="{p["wpx"]}" height="{p["ph"] + 46}" '
                 f'rx="14" fill="{SURFACE}" stroke="{BORDER}"/>')
        text(p["px"] + 20, TOP - 16, p["name"], size=16, anchor="start", weight=700)
        text(p["px"] + p["wpx"] - 20, TOP - 16, f'{p["n_nodes"]} nodes · {p["n_edges"]} edges',
             size=11, fill=MUTED, anchor="end")

    def lane_candidates(p, d1, d2, desired):
        """box-free x lanes through layers strictly between d1,d2: all gap boundaries + desired"""
        iv = sorted((n["_x"] - n["_le"] - 10, n["_x"] + n["_re"] + 10)
                    for d in range(d1 + 1, d2) for n in p["layers"][d])
        merged = []
        for a, b in iv:
            if merged and a <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], b)
            else:
                merged.append([a, b])
        lo, hi = p["px"] + 14, p["px"] + p["wpx"] - 14
        cands = {lo, hi, min(max(desired, lo), hi)}
        for a, b in merged:
            cands.update((a, b))
        return [c for c in cands if lo <= c <= hi and
                not any(a < c < b for a, b in merged)] or [lo]

    def rpath(way, r=7):
        """orthogonal polyline -> path with rounded corners"""
        pts = [way[0]]
        for q in way[1:]:
            if q != pts[-1]:
                pts.append(q)
        d = f"M {pts[0][0]:.1f} {pts[0][1]:.1f}"
        for i in range(1, len(pts) - 1):
            (x0, y0), (x1, y1), (x2, y2) = pts[i - 1], pts[i], pts[i + 1]
            l1 = abs(x1 - x0) + abs(y1 - y0)
            l2 = abs(x2 - x1) + abs(y2 - y1)
            if not l1 or not l2:
                continue
            r1, r2 = min(r, l1 / 2), min(r, l2 / 2)
            d += (f" L {x1 - (x1 - x0) / l1 * r1:.1f} {y1 - (y1 - y0) / l1 * r1:.1f}"
                  f" Q {x1:.1f} {y1:.1f} {x1 + (x2 - x1) / l2 * r2:.1f} {y1 + (y2 - y1) / l2 * r2:.1f}")
        return d + f" L {pts[-1][0]:.1f} {pts[-1][1]:.1f}"

    for p in panels:
        p["_top"] = {d: min(n["_y"] - n["_h"] / 2 for n in L)
                     for d, L in enumerate(p["layers"]) if L}
        # 第一遍:确定每条边的接入方向 x(短边=源 x,长边=车道 x)
        route = []
        for f, t, dashed in p["edges"]:
            u, v = p["all"][f], p["all"][t]
            if u["_d"] == v["_d"]:
                route.append((f, t, dashed, u, v, None, None))
                continue
            if v["_d"] - u["_d"] == 1:
                route.append((f, t, dashed, u, v, u["_x"], None))
                continue
            # 长边:车道按"与首/末通道斜线族的逆序数"计分,零逆序即零交叉
            desired = (u["_x"] + v["_x"]) / 2
            cands = lane_candidates(p, u["_d"], v["_d"], desired)

            def inversions(c, u=u, v=v, f=f, t=t):
                s = 0
                for f2, t2, _ in p["edges"]:
                    a, b = p["all"][f2], p["all"][t2]
                    if a.get("stub") or b.get("stub") or (f2, t2) == (f, t):
                        continue
                    if a["_d"] == v["_d"] - 1 and b["_d"] == v["_d"]:
                        s += (c - a["_x"]) * (v["_x"] - b["_x"]) < 0
                    if a["_d"] == u["_d"] and b["_d"] == u["_d"] + 1:
                        s += (u["_x"] - a["_x"]) * (c - b["_x"]) < 0
                return s

            lane = min(cands, key=lambda c: (inversions(c), abs(c - desired)))
            route.append((f, t, dashed, u, v, lane, lane))
        # 槽位按接入方向从左到右分配,同一目标的入边绝不互相交叉
        byt, slot, m_of = {}, {}, {}
        for i, r in enumerate(route):
            if r[5] is not None:
                byt.setdefault(r[1], []).append(i)
        for t, idxs in byt.items():
            idxs.sort(key=lambda i: route[i][5])
            for rank, i in enumerate(idxs):
                slot[i], m_of[i] = rank, len(idxs)
        # 第二遍:绘制
        for i, (f, t, dashed, u, v, ax, lane) in enumerate(route):
            col = VIOLET if (dashed and u.get("cross")) else (YELLOW if dashed else EDGE)
            dd = ' stroke-dasharray="5 4"' if dashed else ''
            if ax is None:  # 同层角标:水平箭头从侧面接入
                lr = 1 if u["_x"] < v["_x"] else -1
                x1 = u["_x"] + lr * u["_w"] / 2
                x2 = v["_x"] - lr * (v["_w"] / 2 + 2)
                S.append(f'<path d="M {x1:.1f} {u["_y"]:.1f} L {x2:.1f} {v["_y"]:.1f}" fill="none" '
                         f'stroke="{col}" stroke-width="1.4"{dd} marker-end="url(#arr)"/>')
                continue
            k, m = slot[i], m_of[i]
            tx = v["_x"] + (k - (m - 1) / 2) * min(18, v["_w"] / (m + 1))
            ay = v["_y"] - v["_h"] / 2
            uy = u["_y"] + u["_h"] / 2
            # 斜线终止于目标层最高框顶之上,再竖直落入,保证不与任何框重叠
            yT = max(p["_top"][v["_d"]] - 8, u["_y"] + 62)
            if lane is None:  # 相邻层:短竖柄避开标注区,再斜线直达(无逆序即无交叉)
                way = [(u["_x"], uy), (u["_x"], u["_y"] + 58), (tx, yT), (tx, ay)]
            else:  # 长边:竖柄 → 斜线入车道 → 车道垂直下行 → 斜线汇入目标通道
                way = [(u["_x"], uy), (u["_x"], u["_y"] + 58)]
                if abs(lane - u["_x"]) > 6:
                    way.append((lane, p["_top"].get(u["_d"] + 1, u["_y"] + PITCH - 16) - 8))
                way += [(lane, TOP + 24 + (v["_d"] - 1) * PITCH + 58), (tx, yT), (tx, ay)]
            S.append(f'<path d="{rpath(way, 10)}" fill="none" stroke="{col}" '
                     f'stroke-width="1.4"{dd} marker-end="url(#arr)"/>')

    for p in panels:
        for n in p["all"].values():
            fill, stroke = style(n)
            x, y = n["_x"] - n["_w"] / 2, n["_y"] - n["_h"] / 2
            dash = ' stroke-dasharray="5 4"' if n.get("stub") else ''
            S.append(f'<rect x="{x:.0f}" y="{y:.0f}" width="{n["_w"]:.0f}" height="{n["_h"]}" '
                     f'rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"{dash}/>')
            nm = ("↫ " if n.get("cross") else "") + n["name"]
            if n["_inner"]:
                text(n["_x"], y + 19, nm, size=12.5, weight=600)
                for j, l in enumerate(n["_inner"]):
                    text(n["_x"], y + 35 + 15 * j, l, size=10.5, fill=INK2, family=MONO)
            else:
                text(n["_x"], n["_y"] + 4.5, nm, size=12.5, weight=600)
            for j, l in enumerate(n["_flow"]):
                text(n["_x"] + 9, n["_y"] + n["_h"] / 2 + 15 + 12.5 * j, l,
                     size=10, fill=MUTED if l.startswith("(") else INK2,
                     anchor="start", family=MONO)
            if n["_side"]:
                ly0 = n["_y"] - (len(n["_side"]) - 1) * 12.5 / 2 + 3.5
                for j, l in enumerate(n["_side"]):
                    text(x - 36, ly0 + 12.5 * j, l, size=10, fill=ORANGE_D, anchor="end", family=MONO)
                S.append(f'<line x1="{x - 32:.0f}" y1="{n["_y"]}" x2="{x - 5:.0f}" y2="{n["_y"]}" '
                         f'stroke="{ORANGE}" stroke-width="1.4" marker-end="url(#arrO)"/>')

    meta = doc.get("meta", {})
    text(MARG, 44, meta.get("图片标题", Path(src_name).stem), size=24, anchor="start", weight=700)
    text(MARG, 72, f'由 {src_name} 自动布图渲染 · 原始出处:{meta.get("出处(图中标注)", "—")}',
         size=12, fill=INK2, anchor="start")
    text(MARG, 92, "标注约定:T[...] 张量形状沿数据流箭头标注;W[...] 权重形状以橙色箭头标注在算子侧",
         size=12, fill=MUTED, anchor="start")
    LEG = [(ORANGE_T, ORANGE, "Linear"), (GRAY_T, GRAY, "算子"), (BLUE_T, BLUE, "张量"),
           (YELLOW_T, YELLOW, "缓存(虚线=缓存输入)"), (VIOLET_T, VIOLET, "↫ 跨子图引用")]
    lx = W - MARG - sum(twidth(l, 11.5) + 62 for *_, l in LEG)
    for f_, s_, lab in LEG:
        S.append(f'<rect x="{lx:.0f}" y="62" width="14" height="14" rx="4" fill="{f_}" '
                 f'stroke="{s_}" stroke-width="1.5"/>')
        text(lx + 20, 73.5, lab, size=11.5, fill=INK2, anchor="start")
        lx += twidth(lab, 11.5) + 62
    text(W - MARG, H - 14, f'img2excel skill · {meta.get("提取日期", "")} · '
         f'连线由 upstream 字段模糊匹配生成,布局为自动拓扑分层', size=11, fill=MUTED, anchor="end")

    out_html.write_text(f"""<!doctype html><html><head><meta charset="utf-8">
<style>html,body{{margin:0;padding:0;background:{PAGE};}}</style></head><body>
<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H}" viewBox="0 0 {W:.0f} {H}">
<defs>
<marker id="arr" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5"
orient="auto-start-reverse"><path d="M 0 1 L 9 5 L 0 9 z" fill="{EDGE}"/></marker>
<marker id="arrO" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5"
orient="auto-start-reverse"><path d="M 0 1 L 9 5 L 0 9 z" fill="{ORANGE}"/></marker>
</defs>
<rect width="{W:.0f}" height="{H}" fill="{PAGE}"/>
{chr(10).join(S)}
</svg></body></html>""", encoding="utf-8")
    return int(W), int(H)


def screenshot(out_html, out_img, w, h):
    exe = next((b for b in BROWSERS if Path(b).exists()), None)
    if not exe:
        print(f"未找到 Edge/Chrome;矢量版已生成:{out_html}(SIZE {w}x{h},请手动截图)")
        return False
    png = out_img if out_img.suffix.lower() == ".png" else \
        Path(tempfile.gettempdir()) / (out_img.stem + "_shot.png")
    profile = Path(tempfile.gettempdir()) / "img2excel_headless_profile"
    subprocess.run([exe, "--headless=new", "--disable-gpu", "--no-first-run",
                    f"--user-data-dir={profile}", f"--screenshot={png}",
                    f"--window-size={w},{h}", "--force-device-scale-factor=2",
                    "--hide-scrollbars", out_html.as_uri()],
                   check=True, capture_output=True, timeout=120)
    if png != out_img:
        from PIL import Image
        Image.open(png).convert("RGB").save(out_img, quality=92)
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python -I json_to_diagram.py <input.json> [output.jpg|.png]")
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".jpg")
    out_html = out.with_suffix(".html")
    doc = json.loads(src.read_text(encoding="utf-8"))
    w, h = render(doc, src.name, out_html)
    ok = screenshot(out_html, out, w, h)
    print(f"html: {out_html}" + (f"\nimage: {out} ({w * 2}x{h * 2})" if ok else ""))
