import json
import glob
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt


# ---- CONFIG ----
# Adjust this pattern to match your filenames if needed
GLOB_PATTERN = "run_metrics/metrics-*.json"  # e.g. metrics-PG0001202-BLD.Genotyping.json


def load_single_run(path: Path) -> dict:
    """Load one metrics JSON file and extract the relevant fields."""
    with open(path, "r") as f:
        data = json.load(f)

    # Use run_id as label; you can customize this if you want shorter names
    run_id = data.get("run_id", path.stem)

    artifacts = data["artifacts"]
    java_timing = data["java_timing"]
    gzip = data["gzip"]
    hdt = data["hdt_conversion"]
    brotli = data["brotli"]

    row = {
        "run_id": run_id,
        # Data size (MB)
        "input_vcf_MB": artifacts["input_tsv_size_bytes"] / 1e6,
        "nq_MB": artifacts["combined_nq_size_bytes"] / 1e6,
        "gzip_MB": artifacts["gzip_size_bytes"] / 1e6,
        "hdt_MB": artifacts["hdt_size_bytes"] / 1e6,
        "brotli_MB": brotli["output_brotli_size_bytes"] / 1e6,
        # Triples
        "triples_M": artifacts["output_triples"]["TOTAL"] / 1e6,
        # Time wall (seconds)
        "java_wall_s": java_timing["wall_seconds"],
        "gzip_wall_s": gzip["timing"]["wall_seconds"],
        "hdt_wall_s": hdt["timing"]["wall_seconds"],
        "brotli_wall_s": brotli["timing"]["wall_seconds"],
        # Time user (seconds)
        "java_user_s": java_timing["user_seconds"],
        "gzip_user_s": gzip["timing"]["user_seconds"],
        "hdt_user_s": hdt["timing"]["user_seconds"],
        "brotli_user_s": brotli["timing"]["user_seconds"],
        # Time system (seconds)
        "java_system_s": java_timing["sys_seconds"],
        "gzip_system_s": gzip["timing"]["sys_seconds"],
        "hdt_system_s": hdt["timing"]["sys_seconds"],
        "brotli_system_s": brotli["timing"]["sys_seconds"],
        # Peak RSS (GB)
        "java_max_rss_GB": java_timing["max_rss_kb"] / (1024 ** 2),
        "gzip_max_rss_GB": gzip["timing"]["max_rss_kb"] / (1024 ** 2),
        "hdt_max_rss_GB": hdt["timing"]["max_rss_kb"] / (1024 ** 2),
        "brotli_max_rss_GB": brotli["timing"]["max_rss_kb"] / (1024 ** 2),
    }
    return row


def build_dataframe(pattern: str) -> pd.DataFrame:
    paths = sorted(Path(".").glob(pattern))
    if not paths:
        raise FileNotFoundError(f"No files matching pattern {pattern!r}")

    rows = [load_single_run(p) for p in paths]
    df = pd.DataFrame(rows).set_index("run_id")
    return df


def make_table(df: pd.DataFrame):
    """Print a nice text table in the terminal and optionally save as CSV."""
    print("\n=== Summary table (rounded) ===\n")
    print(df.round(3).to_markdown())

    # Optional: save to CSV or Excel
    df.round(3).to_csv("conversion_summary.csv")
    # df.round(3).to_excel("conversion_summary.xlsx")


def make_plots(df: pd.DataFrame):
    """Create a multi-panel figure to compare sizes, time, and memory."""
    # Order of runs on x-axis
    run_labels = df.index.to_list()
    # Strip anything after the first '.' for cleaner x-axis labels
    truncated_labels = [label.split(".", 1)[0] for label in run_labels]
    x = range(len(run_labels))

    # ---- Figure layout ----
    fig, axes = plt.subplots(3, 1, figsize=(11, 13), sharex=True)
    fig.suptitle("Conversion Comparison: Size, Time, and Memory", fontsize=16)

    # ---- 1) Sizes per format ----
    size_cols = ["input_vcf_MB", "nq_MB", "gzip_MB", "hdt_MB", "brotli_MB"]
    size_labels = ["VCF", "N-Quads", "NQ (gz)", "HDT", "Brotli"]

    width = 0.18
    offsets = [i * width - (1.5 * width) for i in range(len(size_cols))]

    for offset, col, label in zip(offsets, size_cols, size_labels):
        axes[0].bar(
            [xi + offset for xi in x],
            df[col],
            width=width,
            label=label,
        )

    axes[0].set_ylabel("Size (MB)")
    axes[0].set_title("Output Size per Format")
    axes[0].legend()
    axes[0].grid(axis="y", linestyle="--", alpha=0.4)

    # ---- 2) Wall-clock time per step ----
    time_cols = ["java_wall_s", "gzip_wall_s", "hdt_wall_s", "brotli_wall_s"]
    time_labels = ["RMLStreamer", "Gzip", "HDT conversion", "Brotli"]
    width_time = 0.22
    offsets_time = [i * width_time - width_time for i in range(len(time_cols))]

    for offset, col, label in zip(offsets_time, time_cols, time_labels):
        axes[1].bar(
            [xi + offset for xi in x],
            df[col],
            width=width_time,
            label=label,
        )

    axes[1].set_ylabel("Wall time (s)")
    axes[1].set_title("Computation Cost (Wall-clock Time)")
    axes[1].legend()
    axes[1].grid(axis="y", linestyle="--", alpha=0.4)

    # ---- 3) Peak memory per step ----
    mem_cols = ["java_max_rss_GB", "hdt_max_rss_GB"]
    mem_labels = ["RMLStreamer", "HDT conversion"]
    width_mem = 0.22
    offsets_mem = [i * width_mem - width_mem for i in range(len(mem_cols))]

    for offset, col, label in zip(offsets_mem, mem_cols, mem_labels):
        axes[2].bar(
            [xi + offset for xi in x],
            df[col],
            width=width_mem,
            label=label,
        )

    axes[2].set_ylabel("Peak RSS (GB)")
    axes[2].set_title("Memory Cost (Peak RSS)")
    axes[2].legend()
    axes[2].grid(axis="y", linestyle="--", alpha=0.4)

    # ---- Shared x-axis formatting ----
    axes[2].set_xticks(list(x))
    axes[2].set_xticklabels(truncated_labels, rotation=20, ha="right")

    plt.tight_layout(rect=[0, 0.03, 1, 0.96])
    plt.savefig("conversion_comparison.png", dpi=200)
    plt.show()


def main():
    df = build_dataframe(GLOB_PATTERN)

    # 1) Table
    make_table(df)

    # 2) Plots
    make_plots(df)


if __name__ == "__main__":
    main()
