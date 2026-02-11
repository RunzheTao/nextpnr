#!/usr/bin/env python3
#
# Export nextpnr pre-pack netlist to OpenPARF-readable Bookshelf files.
#
# Recommended invocation:
#   nextpnr-ice40 --json <design.json> --run python/export_bookshelf_prepack.py
#
# Runtime overrides (args and env, env has fallback support):
#   --out-dir / NEXTPNR_BOOKSHELF_OUT_DIR / BOOKSHELF_OUT_DIR
#   --design-name / NEXTPNR_BOOKSHELF_DESIGN_NAME / BOOKSHELF_DESIGN_NAME
#   --family / NEXTPNR_BOOKSHELF_FAMILY / BOOKSHELF_FAMILY
#   --device / NEXTPNR_BOOKSHELF_DEVICE / BOOKSHELF_DEVICE
#   --package / NEXTPNR_BOOKSHELF_PACKAGE / BOOKSHELF_PACKAGE
#

import argparse
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict, OrderedDict


SAFE_TOKEN_RE = re.compile(r"[^A-Za-z0-9_]")
LEADING_TOKEN_RE = re.compile(r"^[A-Za-z_]")


def _first_env(names, default=None):
    for name in names:
        value = os.getenv(name)
        if value:
            return value
    return default


def _pair_key(item):
    if hasattr(item, "first"):
        return str(item.first)
    if isinstance(item, tuple):
        if len(item) >= 1:
            return str(item[0])
        return ""
    return str(item)


def _iter_sorted_pairs(mapping):
    for item in sorted(mapping, key=_pair_key):
        if hasattr(item, "first"):
            yield str(item.first), item.second
        elif isinstance(item, tuple) and len(item) == 2:
            yield str(item[0]), item[1]
        else:
            # Python dict-like mappings may iterate keys only.
            yield str(item), mapping[item]


def _sanitize_token(raw, default="x"):
    token = SAFE_TOKEN_RE.sub("_", str(raw).strip())
    token = re.sub(r"_+", "_", token).strip("_")
    if not token:
        token = default
    if not LEADING_TOKEN_RE.match(token):
        token = "x_" + token
    return token


def _sanitize_design_name(raw):
    name = _sanitize_token(raw, default="design")
    # AUX first token is STRING in scanner, keep alpha/underscore leading.
    if not LEADING_TOKEN_RE.match(name):
        name = "design_" + name
    return name


class NameMapper(object):
    PREFIX = {
        "cell": "c",
        "net": "n",
        "model": "m",
        "pin": "p",
    }

    def __init__(self):
        self._used = set()
        self._maps = OrderedDict()
        for kind in ("cell", "net", "model", "pin"):
            self._maps[kind] = {
                "orig_to_safe": OrderedDict(),
                "safe_to_orig": OrderedDict(),
            }

    def map(self, kind, original):
        if kind not in self._maps:
            raise RuntimeError("Unknown name-map kind: %s" % kind)
        original = str(original)
        bucket = self._maps[kind]["orig_to_safe"]
        if original in bucket:
            return bucket[original]

        base = "%s_%s" % (self.PREFIX[kind], _sanitize_token(original, default="x"))
        candidate = base
        if candidate in self._used:
            digest = hashlib.sha1(("%s::%s" % (kind, original)).encode("utf-8")).hexdigest()[:8]
            candidate = "%s_%s" % (base, digest)
            idx = 0
            while candidate in self._used:
                idx += 1
                candidate = "%s_%s_%d" % (base, digest, idx)

        self._used.add(candidate)
        self._maps[kind]["orig_to_safe"][original] = candidate
        self._maps[kind]["safe_to_orig"][candidate] = original
        return candidate

    def as_json(self, requested_design_name, safe_design_name):
        global_orig_to_safe = OrderedDict()
        global_safe_to_orig = OrderedDict()
        for kind, entry in self._maps.items():
            for orig, safe in entry["orig_to_safe"].items():
                scoped = "%s::%s" % (kind, orig)
                global_orig_to_safe[scoped] = safe
                global_safe_to_orig[safe] = scoped

        payload = OrderedDict()
        payload["meta"] = {
            "scheme": "prefix + sanitized token + deterministic hash on conflict",
            "requested_design_name": str(requested_design_name),
            "safe_design_name": str(safe_design_name),
        }
        payload["orig_to_safe"] = global_orig_to_safe
        payload["safe_to_orig"] = global_safe_to_orig
        for kind, entry in self._maps.items():
            payload[kind] = entry
        return payload


def _runtime_options(context):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--out-dir")
    parser.add_argument("--design-name")
    parser.add_argument("--family")
    parser.add_argument("--device")
    parser.add_argument("--package")
    args, _ = parser.parse_known_args(sys.argv[1:])

    top_module = getattr(context, "top_module", "")
    chip_name = context.getChipName()

    out_dir = args.out_dir or _first_env(
        ["NEXTPNR_BOOKSHELF_OUT_DIR", "BOOKSHELF_OUT_DIR"],
        default=os.getcwd(),
    )
    requested_design_name = args.design_name or _first_env(
        ["NEXTPNR_BOOKSHELF_DESIGN_NAME", "BOOKSHELF_DESIGN_NAME"],
        default=top_module if top_module else "design",
    )
    family = args.family or _first_env(
        ["NEXTPNR_BOOKSHELF_FAMILY", "BOOKSHELF_FAMILY"],
        default=_default_family(context),
    )
    device = args.device or _first_env(
        ["NEXTPNR_BOOKSHELF_DEVICE", "BOOKSHELF_DEVICE"],
        default=chip_name,
    )
    package = args.package or _first_env(
        ["NEXTPNR_BOOKSHELF_PACKAGE", "BOOKSHELF_PACKAGE"],
        default="",
    )

    return {
        "out_dir": os.path.abspath(out_dir),
        "requested_design_name": str(requested_design_name),
        "safe_design_name": _sanitize_design_name(requested_design_name),
        "family": str(family),
        "device": str(device),
        "package": str(package),
    }


def _default_family(context):
    arch_id = str(context.archId()).strip().lower()
    if "ice40" in arch_id:
        return "ice40"
    if "ecp5" in arch_id:
        return "ecp5"
    if arch_id:
        return arch_id
    return "fpga"


def _classify_pin_tag(pin_name):
    pu = pin_name.upper()

    # Minimal clock/control semantics for OpenPARF parser.
    if pu in ("C", "CLK", "CLOCK", "WCLK", "RCLK") or pu.endswith("CLK") or "_CLK" in pu:
        return "CLOCK"
    if pu in ("CE", "CEN", "EN", "ENABLE", "CLOCK_ENABLE"):
        return "CTRL"
    if "RESET" in pu or pu.startswith("RST") or pu in ("SR", "SET", "CLR", "PRE", "S", "R"):
        return "CTRL"
    return None


def _resources_from_bel_type(bel_type):
    bu = bel_type.upper()
    if bel_type == "ICESTORM_LC":
        return OrderedDict([("LUT", 1), ("FF", 1)])
    if bel_type == "SB_IO":
        return OrderedDict([("IO", 1)])
    if bel_type == "SB_GB":
        return OrderedDict([("GB", 1)])
    if bu == "TRELLIS_COMB":
        return OrderedDict([("LUT", 1)])
    if bu == "TRELLIS_FF":
        return OrderedDict([("FF", 1)])
    if bu in ("TRELLIS_IO", "IOLOGIC", "SIOLOGIC"):
        return OrderedDict([("IO", 1)])
    if bu in ("DP16KD", "TRELLIS_RAMW"):
        return OrderedDict([("RAM", 1)])
    if bu in ("DCCA", "TRELLIS_ECLKBUF", "ECLKSYNCB", "ECLKBRIDGECS", "DCSC", "CLKDIVF", "PCSCLKDIV", "EHXPLLL"):
        return OrderedDict([("GB", 1)])
    if "RAM" in bu:
        return OrderedDict([("RAM", 1)])
    # Fallback resource for uncommon bel types.
    return OrderedDict([("BEL_%s" % _sanitize_token(bel_type).upper(), 1)])


def _resources_from_model_on_bel(model_name, bel_type):
    mu = model_name.upper()
    if bel_type == "ICESTORM_LC":
        if mu.startswith("SB_DFF"):
            return ["FF"]
        if mu.startswith("SB_LUT"):
            return ["LUT"]
        return ["LUT", "FF"]
    return list(_resources_from_bel_type(bel_type).keys())


def _fallback_resources_for_model(model_name):
    mu = model_name.upper()
    if "IBUF" in mu or "OBUF" in mu:
        return ["IO"]
    if mu in ("GND", "VCC", "$PACKER_GND", "$PACKER_VCC"):
        return ["LUT"]
    if "CARRY" in mu:
        return ["LUT"]
    if mu.startswith("SB_LUT"):
        return ["LUT"]
    if mu.startswith("SB_DFF"):
        return ["FF"]
    if mu.startswith("SB_GB"):
        return ["GB"]
    if "RAM" in mu:
        return ["RAM"]
    if "IO" in mu:
        return ["IO"]
    if "LUT" in mu or "COMB" in mu:
        return ["LUT"]
    if "DFF" in mu or "FF" in mu or "REG" in mu:
        return ["FF"]
    if "TRELLIS_IO" in mu:
        return ["IO"]
    return []


def _default_resource_from_arch(bel_type_representative):
    resources = set()
    for bel_type in bel_type_representative.keys():
        resources.update(_resources_from_bel_type(bel_type).keys())

    priority = ["LUT", "FF", "IO", "RAM", "GB"]
    for resource in priority:
        if resource in resources:
            return resource

    if resources:
        return sorted(resources)[0]
    return None


def _site_type_name(capacity_map, resource_order):
    keys = {k for k, v in capacity_map.items() if v > 0}
    if keys == {"LUT", "FF"}:
        return "LC"
    if keys == {"IO"}:
        return "IO"
    if keys == {"GB"}:
        return "GB"
    if keys == {"RAM"}:
        return "RAM"
    parts = []
    for resource in resource_order:
        value = int(capacity_map.get(resource, 0))
        if value > 0:
            parts.append("%s%d" % (resource, value))
    if not parts:
        return "EMPTY"
    return "SITE_" + "_".join(parts)


def _collect_design(context, mapper):
    cells = []
    cell_name_to_model = {}
    model_ports = defaultdict(dict)

    for cell_name, cell in _iter_sorted_pairs(context.cells):
        model_name = str(cell.type)
        safe_cell_name = mapper.map("cell", cell_name)
        safe_model_name = mapper.map("model", model_name)

        fixed = None
        if cell.bel is not None:
            try:
                loc = context.getBelLocation(cell.bel)
                fixed = (int(loc.x), int(loc.y), int(loc.z))
            except Exception:
                fixed = None

        cells.append(
            {
                "orig_name": cell_name,
                "safe_name": safe_cell_name,
                "model_orig": model_name,
                "model_safe": safe_model_name,
                "fixed_loc": fixed,
            }
        )
        cell_name_to_model[cell_name] = model_name

        for pin_name, pin in _iter_sorted_pairs(cell.ports):
            entry = model_ports[model_name].setdefault(
                pin_name,
                {
                    "type_values": set(),
                    "is_driver": False,
                },
            )
            entry["type_values"].add(int(pin.type))

    nets = []
    total_pin_refs = 0
    for net_name, net in _iter_sorted_pairs(context.nets):
        safe_net_name = mapper.map("net", net_name)
        seen = set()
        pin_rows = []
        driver_row = None

        def add_pin(port_ref, is_driver):
            nonlocal driver_row
            if port_ref is None or port_ref.cell is None:
                return
            cell_name = str(port_ref.cell.name)
            pin_name = str(port_ref.port)
            if cell_name not in cell_name_to_model:
                return

            model_name = cell_name_to_model[cell_name]
            if pin_name not in model_ports[model_name]:
                model_ports[model_name][pin_name] = {"type_values": {0}, "is_driver": False}

            model_ports[model_name][pin_name]["is_driver"] = model_ports[model_name][pin_name]["is_driver"] or is_driver

            row_key = (cell_name, pin_name)
            if row_key in seen:
                return
            seen.add(row_key)

            row = (
                mapper.map("cell", cell_name),
                mapper.map("pin", pin_name),
                cell_name,
                pin_name,
            )
            if is_driver:
                driver_row = row
            else:
                pin_rows.append(row)

        add_pin(net.driver, True)
        for user in net.users:
            add_pin(user, False)

        if driver_row is not None:
            ordered_rows = [driver_row] + sorted(pin_rows, key=lambda r: (r[0], r[1], r[2], r[3]))
        else:
            ordered_rows = sorted(pin_rows, key=lambda r: (r[0], r[1], r[2], r[3]))

        if not ordered_rows:
            continue

        nets.append(
            {
                "orig_name": net_name,
                "safe_name": safe_net_name,
                "degree": len(ordered_rows),
                "pins": ordered_rows,
            }
        )
        total_pin_refs += len(ordered_rows)

    models = OrderedDict()
    for model_name in sorted(model_ports.keys()):
        safe_model_name = mapper.map("model", model_name)
        pins = []
        for pin_name in sorted(model_ports[model_name].keys()):
            info = model_ports[model_name][pin_name]
            safe_pin_name = mapper.map("pin", pin_name)

            direction = "INPUT"
            if 1 in info["type_values"] or info["is_driver"]:
                direction = "OUTPUT"

            pin_tag = None
            if direction == "INPUT":
                pin_tag = _classify_pin_tag(pin_name)

            pins.append(
                {
                    "orig_name": pin_name,
                    "safe_name": safe_pin_name,
                    "direction": direction,
                    "tag": pin_tag,
                }
            )

        if not pins:
            raise RuntimeError("Model '%s' has no pins; cannot emit valid .lib cell block." % model_name)

        models[model_name] = {
            "safe_name": safe_model_name,
            "pins": pins,
        }

    return {
        "cells": cells,
        "nets": nets,
        "models": models,
        "cell_name_to_model": cell_name_to_model,
        "total_pin_refs": total_pin_refs,
    }


def _collect_arch(context):
    bel_type_representative = OrderedDict()
    bel_type_counts = Counter()
    bel_types_by_xy = defaultdict(Counter)
    max_x = -1
    max_y = -1

    for bel in context.getBels():
        bel_type = str(context.getBelType(bel))
        if bel_type not in bel_type_representative:
            bel_type_representative[bel_type] = bel
        bel_type_counts[bel_type] += 1

        loc = context.getBelLocation(bel)
        x = int(loc.x)
        y = int(loc.y)
        max_x = max(max_x, x)
        max_y = max(max_y, y)
        bel_types_by_xy[(x, y)][bel_type] += 1

    if max_x < 0 or max_y < 0:
        raise RuntimeError("Architecture has no BELs; cannot derive placement layout.")

    return {
        "bel_type_representative": bel_type_representative,
        "bel_type_counts": bel_type_counts,
        "bel_types_by_xy": bel_types_by_xy,
        "max_x": max_x,
        "max_y": max_y,
    }


def _model_resource_map(context, models, bel_type_representative):
    default_resource = _default_resource_from_arch(bel_type_representative)
    model_to_resources = OrderedDict()
    for model_name in sorted(models.keys()):
        resources = []
        seen_resources = set()

        compatible_bel_types = []
        for bel_type in sorted(bel_type_representative.keys()):
            bel = bel_type_representative[bel_type]
            try:
                if context.isValidBelForCellType(model_name, bel):
                    compatible_bel_types.append(bel_type)
            except Exception:
                continue

        def add_resource(resource):
            if resource not in seen_resources:
                seen_resources.add(resource)
                resources.append(resource)

        for bel_type in compatible_bel_types:
            for resource in _resources_from_model_on_bel(model_name, bel_type):
                add_resource(resource)

        if not resources:
            for resource in _fallback_resources_for_model(model_name):
                add_resource(resource)

        if not resources:
            if default_resource is None:
                raise RuntimeError("Cannot map model '%s' to any resource type." % model_name)
            # Keep exporter robust for architectures where model/BEL matching is incomplete.
            add_resource(default_resource)

        model_to_resources[model_name] = resources

    return model_to_resources


def _build_layout(arch_data, active_resources):
    site_entries = []
    site_defs = OrderedDict()
    resource_site_counts = Counter()

    resource_order = ["LUT", "FF", "IO", "GB", "RAM"]
    for resource in sorted(active_resources):
        if resource not in resource_order:
            resource_order.append(resource)

    for (x, y), bel_counter in sorted(arch_data["bel_types_by_xy"].items(), key=lambda kv: (kv[0][0], kv[0][1])):
        cap = Counter()
        for bel_type, bel_count in bel_counter.items():
            for resource, amount in _resources_from_bel_type(bel_type).items():
                if resource in active_resources:
                    cap[resource] += bel_count * int(amount)

        cap = {resource: int(value) for resource, value in cap.items() if int(value) > 0}
        if not cap:
            continue

        site_type = _site_type_name(cap, resource_order)
        if site_type in site_defs and site_defs[site_type] != cap:
            # Keep deterministic unique naming if a collision happened.
            digest = hashlib.sha1(json.dumps(cap, sort_keys=True).encode("utf-8")).hexdigest()[:8]
            site_type = "%s_%s" % (site_type, digest)

        if site_type not in site_defs:
            site_defs[site_type] = cap

        site_entries.append((x, y, site_type))
        for resource, value in cap.items():
            if value > 0:
                resource_site_counts[resource] += 1

    return {
        "site_defs": site_defs,
        "site_entries": site_entries,
        "resource_site_counts": resource_site_counts,
        "resource_order": resource_order,
        "width": arch_data["max_x"] + 1,
        "height": arch_data["max_y"] + 1,
    }


def _check_unique(values, what):
    seen = set()
    for value in values:
        if value in seen:
            raise RuntimeError("Duplicate %s '%s'." % (what, value))
        seen.add(value)


def _check_consistency(design_data):
    nodes = design_data["cells"]
    nets = design_data["nets"]
    models = design_data["models"]
    _check_unique((node["safe_name"] for node in nodes), "node safe name")
    _check_unique((net["safe_name"] for net in nets), "net safe name")
    _check_unique((model["safe_name"] for model in models.values()), "model safe name")

    inst_to_model = {}
    for node in nodes:
        inst_to_model[node["safe_name"]] = node["model_safe"]

    model_to_pins = {}
    for model_info in models.values():
        model_safe = model_info["safe_name"]
        pin_safes = [pin["safe_name"] for pin in model_info["pins"]]
        _check_unique(pin_safes, "pin safe name in model '%s'" % model_safe)
        model_to_pins[model_safe] = set(pin_safes)

    for node in nodes:
        model_safe = node["model_safe"]
        if model_safe not in model_to_pins:
            raise RuntimeError("Node '%s' references unknown model '%s'." % (node["safe_name"], model_safe))

    pin_ref_count = 0
    for net in nets:
        if int(net["degree"]) != len(net["pins"]):
            raise RuntimeError("Net degree mismatch for net '%s'." % net["safe_name"])
        net_pairs = set()
        for pin_row in net["pins"]:
            inst_safe = pin_row[0]
            pin_safe = pin_row[1]
            row_key = (inst_safe, pin_safe)
            if row_key in net_pairs:
                raise RuntimeError(
                    "Net '%s' has duplicated pin row %s.%s." % (net["safe_name"], inst_safe, pin_safe)
                )
            net_pairs.add(row_key)
            if inst_safe not in inst_to_model:
                raise RuntimeError("Net references unknown node instance '%s'." % inst_safe)
            model_safe = inst_to_model[inst_safe]
            if model_safe not in model_to_pins:
                raise RuntimeError("Net references unknown model '%s'." % model_safe)
            if pin_safe not in model_to_pins[model_safe]:
                raise RuntimeError(
                    "Net pin '%s' is not declared in model '%s'." % (pin_safe, model_safe)
                )
        pin_ref_count += len(net["pins"])

    if pin_ref_count != int(design_data["total_pin_refs"]):
        raise RuntimeError(
            "Total net pin references mismatch: %d vs %d."
            % (pin_ref_count, int(design_data["total_pin_refs"]))
        )


def _render_aux(design):
    return "%s : %s.nodes %s.nets %s.wts %s.pl %s.scl %s.lib\n" % (
        design,
        design,
        design,
        design,
        design,
        design,
        design,
    )


def _render_lib(models):
    lines = []
    for model_name in sorted(models.keys(), key=lambda k: models[k]["safe_name"]):
        model = models[model_name]
        lines.append("CELL %s" % model["safe_name"])
        for pin in model["pins"]:
            if pin["direction"] == "OUTPUT":
                lines.append("  PIN %s OUTPUT" % pin["safe_name"])
            else:
                if pin["tag"] == "CLOCK":
                    lines.append("  PIN %s INPUT CLOCK" % pin["safe_name"])
                elif pin["tag"] == "CTRL":
                    lines.append("  PIN %s INPUT CTRL" % pin["safe_name"])
                else:
                    lines.append("  PIN %s INPUT" % pin["safe_name"])
        lines.append("END CELL")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _render_nodes(cells):
    lines = []
    for cell in sorted(cells, key=lambda c: c["safe_name"]):
        lines.append("%s %s" % (cell["safe_name"], cell["model_safe"]))
    return "\n".join(lines) + ("\n" if lines else "")


def _render_nets(nets):
    lines = []
    for net in sorted(nets, key=lambda n: n["safe_name"]):
        pins = net["pins"]
        lines.append("net %s %d" % (net["safe_name"], int(net["degree"])))
        for row in pins:
            lines.append("  %s %s" % (row[0], row[1]))
        lines.append("endnet")
    return "\n".join(lines) + ("\n" if lines else "")


def _render_pl(cells):
    lines = []
    for cell in sorted(cells, key=lambda c: c["safe_name"]):
        if cell["fixed_loc"] is None:
            continue
        x, y, z = cell["fixed_loc"]
        lines.append("%s %d %d %d FIXED" % (cell["safe_name"], x, y, z))
    # Keep minimal legal content; empty file is accepted by parser fallback.
    return ("\n".join(lines) + "\n") if lines else "\n"


def _render_wts():
    return "\n"


def _render_scl(layout, model_to_resources, models, family, device, package):
    lines = []
    lines.append("# family: %s" % family)
    lines.append("# device: %s" % device)
    lines.append("# package: %s" % package)
    lines.append("")

    for site_type, cap in sorted(layout["site_defs"].items(), key=lambda kv: kv[0]):
        lines.append("SITE %s" % site_type)
        for resource in sorted(cap.keys()):
            lines.append("  %s %d" % (resource, int(cap[resource])))
        lines.append("END SITE")
        lines.append("")

    resource_to_models = OrderedDict()
    for model_name in sorted(model_to_resources.keys()):
        safe_model = models[model_name]["safe_name"]
        for resource in model_to_resources[model_name]:
            resource_to_models.setdefault(resource, [])
            resource_to_models[resource].append(safe_model)

    lines.append("RESOURCES")
    for resource in sorted(resource_to_models.keys()):
        model_list = sorted(set(resource_to_models[resource]))
        lines.append("  %s %s" % (resource, " ".join(model_list)))
    lines.append("END RESOURCES")
    lines.append("")

    lines.append("SITEMAP %d %d" % (layout["width"], layout["height"]))
    for x, y, site_type in layout["site_entries"]:
        lines.append("%d %d %s" % (x, y, site_type))
    lines.append("END SITEMAP")
    lines.append("")

    # Conservative placeholder: emit one clock region that spans the full layout.
    ymid = max(0, layout["height"] // 2)
    xhi = max(0, layout["width"] - 1)
    yhi = max(0, layout["height"] - 1)
    lines.append("CLOCKREGIONS 1 1")
    lines.append("CLOCKREGION X0Y0 : 0 0 %d %d %d 0" % (xhi, yhi, ymid))
    lines.append("END CLOCKREGIONS")
    lines.append("")

    return "\n".join(lines)


def _resource_category(resource):
    if resource == "LUT":
        return "LUTL"
    if resource == "FF":
        return "FF"
    if resource == "IO":
        return "SSMIR"
    return "SSSIR"


def _lut_size_from_model(model_name):
    m = re.search(r"SB_LUT(\d+)", model_name.upper())
    if m:
        return int(m.group(1))
    return 0


def _build_openparf_template(options, model_to_resources, models, aux_path, layout):
    gp_model2area_types_map = OrderedDict()
    gp_resource2area_types_map = OrderedDict()
    resource_categories = OrderedDict()

    active_resources = sorted({resource for values in model_to_resources.values() for resource in values})
    for resource in active_resources:
        gp_resource2area_types_map[resource] = [resource]
        resource_categories[resource] = _resource_category(resource)

    for model_name in sorted(model_to_resources.keys()):
        model_safe = models[model_name]["safe_name"]
        resources = model_to_resources[model_name]
        entry = OrderedDict()
        for resource in resources:
            entry[resource] = [1.0, 1.0]
        entry["isLUT"] = _lut_size_from_model(model_name) if "LUT" in resources else 0
        entry["isFF"] = 1 if "FF" in resources else 0
        if "GB" in resources or model_name.upper().startswith("SB_GB"):
            entry["isClockSource"] = 1
        gp_model2area_types_map[model_safe] = entry

    clb_capacity = 1
    for cap in layout["site_defs"].values():
        if "LUT" in cap:
            clb_capacity = max(clb_capacity, int(cap["LUT"]))

    return OrderedDict(
        [
            ("benchmark_name", options["safe_design_name"]),
            ("benchmark_format", "bookshelf"),
            ("architecture_name", options["family"]),
            ("aux_input", aux_path),
            ("family", options["family"]),
            ("device", options["device"]),
            ("package", options["package"]),
            ("gp_model2area_types_map", gp_model2area_types_map),
            ("gp_resource2area_types_map", gp_resource2area_types_map),
            ("resource_categories", resource_categories),
            ("CLB_capacity", clb_capacity),
            ("BLE_capacity", 1),
            ("num_ControlSets_per_CLB", 1),
            (
                "notes",
                [
                    "Generated by nextpnr pre-pack exporter.",
                    "Model/resource area sizes are conservative placeholders and may need calibration.",
                ],
            ),
        ]
    )


def _write_file(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def main(context):
    if len(context.cells) == 0:
        raise RuntimeError("No design loaded (ctx.cells is empty).")

    arch_data = _collect_arch(context)

    options = _runtime_options(context)
    os.makedirs(options["out_dir"], exist_ok=True)

    mapper = NameMapper()
    design_data = _collect_design(context, mapper)
    model_to_resources = _model_resource_map(context, design_data["models"], arch_data["bel_type_representative"])

    active_resources = {resource for values in model_to_resources.values() for resource in values}
    layout = _build_layout(arch_data, active_resources)
    if not layout["site_entries"]:
        raise RuntimeError("Derived empty SITEMAP; no legal placement sites were found.")

    for resource in sorted(active_resources):
        if layout["resource_site_counts"].get(resource, 0) == 0:
            raise RuntimeError(
                "Resource '%s' is required by models but has zero sites in SITEMAP." % resource
            )

    _check_consistency(design_data)

    design = options["safe_design_name"]
    out_dir = options["out_dir"]
    aux_path = os.path.join(out_dir, "%s.aux" % design)
    lib_path = os.path.join(out_dir, "%s.lib" % design)
    nodes_path = os.path.join(out_dir, "%s.nodes" % design)
    nets_path = os.path.join(out_dir, "%s.nets" % design)
    pl_path = os.path.join(out_dir, "%s.pl" % design)
    scl_path = os.path.join(out_dir, "%s.scl" % design)
    wts_path = os.path.join(out_dir, "%s.wts" % design)
    name_map_path = os.path.join(out_dir, "%s.name_map.json" % design)
    openparf_json_path = os.path.join(out_dir, "%s_openparf.json" % design)

    _write_file(aux_path, _render_aux(design))
    _write_file(lib_path, _render_lib(design_data["models"]))
    _write_file(nodes_path, _render_nodes(design_data["cells"]))
    _write_file(nets_path, _render_nets(design_data["nets"]))
    _write_file(pl_path, _render_pl(design_data["cells"]))
    _write_file(
        scl_path,
        _render_scl(
            layout,
            model_to_resources,
            design_data["models"],
            options["family"],
            options["device"],
            options["package"],
        ),
    )
    _write_file(wts_path, _render_wts())

    with open(name_map_path, "w", encoding="utf-8") as f:
        json.dump(
            mapper.as_json(options["requested_design_name"], options["safe_design_name"]),
            f,
            indent=2,
            sort_keys=False,
            ensure_ascii=True,
        )
        f.write("\n")

    openparf_template = _build_openparf_template(
        options,
        model_to_resources,
        design_data["models"],
        os.path.abspath(aux_path),
        layout,
    )
    with open(openparf_json_path, "w", encoding="utf-8") as f:
        json.dump(openparf_template, f, indent=2, sort_keys=False, ensure_ascii=True)
        f.write("\n")

    print("[bookshelf-export] out_dir=%s" % out_dir)
    print("[bookshelf-export] design=%s" % design)
    print("[bookshelf-export] instances=%d" % len(design_data["cells"]))
    print("[bookshelf-export] nets=%d" % len(design_data["nets"]))
    print("[bookshelf-export] pin_refs=%d" % design_data["total_pin_refs"])
    print(
        "[bookshelf-export] files=%s"
        % ", ".join(
            [
                os.path.basename(aux_path),
                os.path.basename(lib_path),
                os.path.basename(nodes_path),
                os.path.basename(nets_path),
                os.path.basename(pl_path),
                os.path.basename(scl_path),
                os.path.basename(wts_path),
                os.path.basename(openparf_json_path),
                os.path.basename(name_map_path),
            ]
        )
    )


if "ctx" in globals():
    main(ctx)
