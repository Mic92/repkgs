#!/usr/bin/env python3
"""Graphs from `bench/eval.nu --save eval.json`: eval-plot.py eval.json [outdir].

nix-shell -p 'python3.withPackages (p: [ p.matplotlib ])' --run 'bench/eval-plot.py …'
Writes eval-set, eval-packages and eval-scaling as .png and .svg.
"""

import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt

SIDES = {"ours": ("repkgs", "#2b8a3e"), "theirs": ("nixpkgs", "#7e7e7e")}
plt.rcParams.update(
    {"font.size": 11, "axes.spines.top": False, "axes.spines.right": False}
)


def human(v: float) -> str:
    if v >= 1e6:
        return f"{v / 1e6:.2g}M"
    if v >= 1e4:
        return f"{v / 1e3:.0f}k"
    return f"{v:g}"


def save(fig: plt.Figure, out: Path, name: str) -> None:
    fig.tight_layout()
    for ext in ("png", "svg"):
        fig.savefig(out / f"{name}.{ext}", dpi=160, bbox_inches="tight")
    plt.close(fig)


def plot_set(rows: list[dict], out: Path) -> None:
    by = {r["side"]: r for r in rows if r["case"] == "set"}
    metrics = [
        ("wall (s)", "wall_s"),
        ("cpu (s)", "cpu_s"),
        ("peak RSS (MB)", "rss_MB"),
        ("thunks", "thunks"),
        ("attr elements", "attrs"),
        ("function calls", "calls"),
    ]
    fig, axs = plt.subplots(1, len(metrics), figsize=(14, 3.6))
    for ax, (title, key) in zip(axs, metrics):
        vals = [by[s][key] for s in SIDES]
        bars = ax.bar(
            [SIDES[s][0] for s in SIDES], vals, color=[SIDES[s][1] for s in SIDES]
        )
        ax.set_yscale("log")
        ax.set_ylim(vals[0] / 3, vals[1] * 4)
        ax.set_title(title)
        ax.tick_params(axis="x", labelsize=9)
        for bar, v in zip(bars, vals):
            x = bar.get_x() + bar.get_width() / 2
            ax.text(x, v * 1.15, human(v), ha="center", fontsize=9)
        ax.text(
            0.5,
            -0.22,
            f"×{vals[1] / vals[0]:.0f}",
            transform=ax.transAxes,
            ha="center",
            fontsize=12,
            fontweight="bold",
        )
    fig.suptitle("Instantiating every shared package, log scale", y=1.02)
    save(fig, out, "eval-set")


def plot_series(
    rows: list[dict], prefix: str, out: Path, name: str, xlabel: str
) -> None:
    cases = [
        r["case"] for r in rows if r["side"] == "ours" and r["case"].startswith(prefix)
    ]
    labels = [c[len(prefix) :] for c in cases]
    numeric = all(label.isdigit() for label in labels)
    fig, axs = plt.subplots(1, 2, figsize=(11, 3.8))
    for ax, (title, key) in zip(
        axs, [("wall time (s)", "wall_s"), ("peak RSS (MB)", "rss_MB")]
    ):
        for i, (side, (label, color)) in enumerate(SIDES.items()):
            ys = [
                next(r[key] for r in rows if r["side"] == side and r["case"] == c)
                for c in cases
            ]
            if numeric:
                ax.plot([int(x) for x in labels], ys, "o-", label=label, color=color)
            else:
                xs = [x + (i - 0.5) * 0.38 for x in range(len(labels))]
                ax.bar(xs, ys, 0.38, label=label, color=color)
        if not numeric:
            ax.set_xticks(range(len(labels)), labels, rotation=20)
        ax.set_xlabel(xlabel)
        ax.set_title(title)
        ax.set_ylim(bottom=0)
    axs[0].legend(frameon=False)
    save(fig, out, name)


def main() -> None:
    rows = json.loads(Path(sys.argv[1]).read_text())
    out = Path(sys.argv[2] if len(sys.argv) > 2 else ".")
    out.mkdir(parents=True, exist_ok=True)
    plot_set(rows, out)
    plot_series(rows, "pkg:", out, "eval-packages", "one package, fresh process")
    plot_series(rows, "first:", out, "eval-scaling", "packages in one call")
    print(*sorted(str(p) for p in out.glob("eval-*.??g")), sep="\n")


if __name__ == "__main__":
    main()
