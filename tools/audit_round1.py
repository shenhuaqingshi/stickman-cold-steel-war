#!/usr/bin/env python3
"""
冷兵器数值平衡、兵种克制数学模型与 40 城关大地图拓扑/开局经济公平性审计脚本（可复现扫描）
用法：
  python3 tools/audit_round1.py
"""
import math
import os
import re
import sys
from collections import defaultdict, deque

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def main() -> int:
    failures = []

    print("=== 1. PARSING UNIT CONFIGS & RUNNING COMBAT MATH AUDIT ===")
    unit_cfg_path = os.path.join(ROOT, "entry", "src", "main", "ets", "config", "UnitConfig.ets")
    with open(unit_cfg_path, "r", encoding="utf-8") as f:
        unit_src = f.read()

    units = []
    pos = 0
    while True:
        idx = unit_src.find("id: UnitTypeId.", pos)
        if idx == -1:
            break
        start = unit_src.rfind("{", 0, idx)
        depth = 0
        end = start
        for i in range(start, len(unit_src)):
            if unit_src[i] == "{":
                depth += 1
            elif unit_src[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        block = unit_src[start:end]
        pos = end

        def grab(pattern, cast=float, default=None):
            m = re.search(pattern, block)
            return cast(m.group(1)) if m else default

        u = {
            "id": grab(r"id:\s*UnitTypeId\.(\w+)", str),
            "name": grab(r"name:\s*'([^']+)'", str),
            "category": grab(r"category:\s*UnitCategory\.(\w+)", str),
            "faction": grab(r"exclusiveFaction:\s*(null|FactionId\.\w+)", str),
            "hp": grab(r"hp:\s*([\d.]+)"),
            "atk": grab(r"attack:\s*([\d.]+)"),
            "pen": grab(r"armorPenetration:\s*([\d.]+)"),
            "armor": grab(r"armor:\s*([\d.]+)"),
            "shield": grab(r"shieldRangedBlock:\s*([\d.]+)"),
            "range": grab(r"attackRange:\s*([\d.]+)"),
            "minRange": grab(r"minRange:\s*([\d.]+)"),
            "interval": grab(r"attackIntervalSec:\s*([\d.]+)"),
            "speed": grab(r"moveSpeed:\s*([\d.]+)"),
            "charge": grab(r"chargeMultiplier:\s*([\d.]+)"),
            "antiCav": grab(r"antiCavalryMultiplier:\s*([\d.]+)"),
            "gold": grab(r"gold:\s*([\d.]+)"),
            "wood": grab(r"wood:\s*([\d.]+)"),
            "grain": grab(r"grain:\s*([\d.]+)"),
            "pop": grab(r"popCap:\s*([\d.]+)"),
            "upkeep": grab(r"grainUpkeepPerSec:\s*([\d.]+)"),
        }
        u["total_cost"] = u["gold"] + u["wood"] + u["grain"]
        u["dps"] = u["atk"] / u["interval"]
        u["melee_ehp"] = u["hp"] * (1.0 + u["armor"] / 50.0)
        u["ranged_ehp"] = u["hp"] * (1.0 + u["armor"] * 0.85 / 50.0) / max(0.1, (1.0 - u["shield"]))
        eff_arm30 = 30.0 * (1.0 - u["pen"])
        dps_vs30 = u["dps"] * (50.0 / (50.0 + eff_arm30))
        u["dps_vs30"] = dps_vs30
        u["duel_power"] = math.sqrt(u["melee_ehp"] * dps_vs30)
        u["power_per_pop"] = u["duel_power"] / u["pop"]
        u["power_per_100cost"] = u["duel_power"] / (u["total_cost"] / 100.0)
        units.append(u)

    if len(units) != 16:
        failures.append(f"Expected 16 units in UnitConfig.ets, found {len(units)}")

    print(f"Parsed {len(units)} units:")
    print(
        f"{'Name':<10} {'Pop':>3} {'Cost':>5} {'HP':>4} {'DPS':>5} {'DPS@30A':>7} "
        f"{'M-EHP':>6} {'R-EHP':>6} {'Pwr/Pop':>7} {'Pwr/100C':>8} {'Upk/Pop':>7}"
    )
    for u in units:
        print(
            f"{u['name']:<10} {int(u['pop']):>3} {int(u['total_cost']):>5} {int(u['hp']):>4} "
            f"{u['dps']:>5.1f} {u['dps_vs30']:>7.1f} {u['melee_ehp']:>6.0f} {u['ranged_ehp']:>6.0f} "
            f"{u['power_per_pop']:>7.1f} {u['power_per_100cost']:>8.1f} {u['upkeep']/u['pop']:>7.3f}"
        )

    print("\n=== 2. KEY COUNTER MATCHUP CHECKS (EQUAL COST = 1000 RESOURCES) ===")
    by_id = {u["id"]: u for u in units}

    def dmg_once(att, dfn, is_ranged=False, is_charge=False, is_anticav=False):
        pen = min(1.0, att["pen"] + (0.30 if is_anticav else 0.0))
        eff_a = dfn["armor"] * (1.0 - pen)
        mit = eff_a / (eff_a + 50.0)
        sh = (1.0 - dfn["shield"]) if is_ranged else 1.0
        ch = att["charge"] if is_charge else 1.0
        ac = att["antiCav"] if is_anticav else 1.0
        return max(2.0, att["atk"] * ch * ac * sh * (1.0 - mit))

    arch = by_id["COMPOSITE_ARCHER"]
    for target_id in ["SHIELD_SWORDSMAN", "PIKEMAN", "GREAT_AXEMAN", "XUEYUE_WARDRUM_BERSERKER"]:
        t = by_id[target_id]
        close_dist = arch["range"] - t["range"]
        close_sec = close_dist / t["speed"]
        volleys = math.floor(close_sec / arch["interval"]) + 1
        d = dmg_once(arch, t, is_ranged=True)
        pct_hp_lost_1v1 = (volleys * d) / t["hp"] * 100.0
        print(
            f"Archer vs {t['name']}: close_sec={close_sec:.1f}s, volleys={volleys}, "
            f"dmg/shot={d:.1f}, 1-on-1 HP lost closing={pct_hp_lost_1v1:.1f}%"
        )

    pike = by_id["PIKEMAN"]
    for cav_id in ["LIGHT_CAVALRY", "XUANJIA_CATAPHRACT"]:
        cav = by_id[cav_id]
        pike_counter = dmg_once(pike, cav, is_anticav=True)
        cav_charge = dmg_once(cav, pike, is_charge=True)
        n_pike = 1000.0 / pike["total_cost"]
        n_cav = 1000.0 / cav["total_cost"]
        print(
            f"1000-cost Pike ({n_pike:.1f} units) vs {cav['name']} ({n_cav:.1f} units): "
            f"Pike front strike total={n_pike*pike_counter:.0f} vs Cav total HP={n_cav*cav['hp']:.0f}; "
            f"Cav charge total={n_cav*cav_charge:.0f} vs Pike total HP={n_pike*pike['hp']:.0f}"
        )

    print("\n=== 3. PARSING 40-NODE CAMPAIGN GRAPH & FACTION ECONOMY AUDIT ===")
    map_cfg_path = os.path.join(ROOT, "entry", "src", "main", "ets", "config", "CampaignMapConfig.ets")
    with open(map_cfg_path, "r", encoding="utf-8") as f:
        map_src = f.read()

    nodes = []
    pos = 0
    while True:
        idx = map_src.find("id: '", pos)
        if idx == -1:
            break
        start = map_src.rfind("{", 0, idx)
        depth = 0
        end = start
        for i in range(start, len(map_src)):
            if map_src[i] == "{":
                depth += 1
            elif map_src[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        block = map_src[start:end]
        pos = end
        nid = re.search(r"id:\s*'([^']+)'", block).group(1)
        name = re.search(r"name:\s*'([^']+)'", block).group(1)
        reg = int(re.search(r"regionIndex:\s*(\d+)", block).group(1))
        owner = re.search(r"initialOwner:\s*FactionId\.(\w+)", block).group(1)
        x = int(re.search(r"\bx:\s*(\d+)", block).group(1))
        y = int(re.search(r"\by:\s*(\d+)", block).group(1))
        gold = int(re.search(r"goldYield:\s*(\d+)", block).group(1))
        wood = int(re.search(r"woodYield:\s*(\d+)", block).group(1))
        grain = int(re.search(r"grainYield:\s*(\d+)", block).group(1))
        depot = re.search(r"isSupplyDepot:\s*(true|false)", block).group(1) == "true"
        nbr_raw = re.search(r"neighbors:\s*\[([^\]]*)\]", block).group(1)
        nbrs = re.findall(r"'([^']+)'", nbr_raw)
        nodes.append(
            {
                "id": nid,
                "name": name,
                "reg": reg,
                "owner": owner,
                "x": x,
                "y": y,
                "gold": gold,
                "wood": wood,
                "grain": grain,
                "depot": depot,
                "neighbors": nbrs,
            }
        )

    node_map = {n["id"]: n for n in nodes}
    print(f"Total campaign nodes: {len(nodes)}")
    if len(nodes) != 40:
        failures.append(f"Expected 40 campaign nodes, found {len(nodes)}")

    asym = []
    self_loops = []
    missing_nbr = []
    undirected_edges = set()
    for n in nodes:
        for nb in n["neighbors"]:
            if nb == n["id"]:
                self_loops.append(n["id"])
            if nb not in node_map:
                missing_nbr.append((n["id"], nb))
            else:
                undirected_edges.add(tuple(sorted((n["id"], nb))))
                if n["id"] not in node_map[nb]["neighbors"]:
                    asym.append((n["id"], nb))

    def ccw(ax, ay, bx, by, cx, cy):
        return (cy - ay) * (bx - ax) - (by - ay) * (cx - ax)

    edge_list = sorted(undirected_edges)
    crossings = []
    for i in range(len(edge_list)):
        u1, v1 = edge_list[i]
        for j in range(i + 1, len(edge_list)):
            u2, v2 = edge_list[j]
            if len({u1, v1, u2, v2}) < 4:
                continue
            a, b = node_map[u1], node_map[v1]
            c, d = node_map[u2], node_map[v2]
            d1 = ccw(a["x"], a["y"], b["x"], b["y"], c["x"], c["y"])
            d2 = ccw(a["x"], a["y"], b["x"], b["y"], d["x"], d["y"])
            d3 = ccw(c["x"], c["y"], d["x"], d["y"], a["x"], a["y"])
            d4 = ccw(c["x"], c["y"], d["x"], d["y"], b["x"], b["y"])
            if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)):
                crossings.append(((u1, v1), (u2, v2)))

    visited = {nodes[0]["id"]}
    q = deque([nodes[0]["id"]])
    while q:
        cur = q.popleft()
        for nb in node_map[cur]["neighbors"]:
            if nb in node_map and nb not in visited:
                visited.add(nb)
                q.append(nb)

    print(
        f"Undirected roads: {len(undirected_edges)}, Crossings: {len(crossings)}, "
        f"Asymmetric edges: {asym}, Missing neighbors: {missing_nbr}, "
        f"Self-loops: {self_loops}, Connected: {len(visited)}/{len(nodes)}"
    )
    if len(undirected_edges) != 78:
        failures.append(f"Expected exactly 78 undirected roads, found {len(undirected_edges)}")
    if crossings:
        failures.append(f"Expected 0 road crossings (planar map), found {len(crossings)}: {crossings}")
    if asym or missing_nbr or self_loops or len(visited) != len(nodes):
        failures.append("Campaign graph topology invariant failed (asymmetry / self-loop / disconnected)")

    min_dist = 999999.0
    min_pair = None
    for i in range(len(nodes)):
        for j in range(i + 1, len(nodes)):
            d = math.hypot(nodes[i]["x"] - nodes[j]["x"], nodes[i]["y"] - nodes[j]["y"])
            if d < min_dist:
                min_dist = d
                min_pair = (nodes[i]["name"], nodes[j]["name"])
    print(f"Min pairwise node distance: {min_dist:.1f}px between {min_pair}")

    fac_econ = defaultdict(
        lambda: {"nodes": 0, "gold": 0, "wood": 0, "grain": 0, "depots": 0, "border_factions": set()}
    )
    for n in nodes:
        fe = fac_econ[n["owner"]]
        fe["nodes"] += 1
        fe["gold"] += n["gold"]
        fe["wood"] += n["wood"]
        fe["grain"] += n["grain"]
        fe["depots"] += 1 if n["depot"] else 0
        for nb in n["neighbors"]:
            if node_map[nb]["owner"] != n["owner"]:
                fe["border_factions"].add(node_map[nb]["owner"])

    totals = []
    print(f"\n{'Faction':<12} {'Nodes':>5} {'Gold':>5} {'Wood':>5} {'Grain':>6} {'Total':>6} {'Depots':>6} {'Rivals':>6}")
    for fac, st in sorted(fac_econ.items()):
        tot = st["gold"] + st["wood"] + st["grain"]
        totals.append(tot)
        if st["nodes"] != 5:
            failures.append(f"Faction {fac} owns {st['nodes']} starting cities (expected 5)")
        if st["depots"] < 1:
            failures.append(f"Faction {fac} has 0 supply depots")
        print(
            f"{fac:<12} {st['nodes']:>5} {st['gold']:>5} {st['wood']:>5} {st['grain']:>6} "
            f"{tot:>6} {st['depots']:>6} {len(st['border_factions']):>6} {sorted(st['border_factions'])}"
        )

    spread_pct = (max(totals) - min(totals)) / max(1.0, min(totals)) * 100.0
    print(f"\n8-Faction Economy Spread: min={min(totals)}, max={max(totals)}, spread={spread_pct:.2f}%")
    if spread_pct > 6.0:
        failures.append(f"Economy spread {spread_pct:.2f}% exceeds 6% fairness band")

    if failures:
        print("\n[AUDIT FAILED]")
        for f_msg in failures:
            print(" -", f_msg)
        return 1

    print("\n=== ALL NUMERICAL BALANCE & 40-NODE TOPOLOGY AUDITS PASSED (0 ERRORS) ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
