#!/usr/bin/env python3

import argparse
import statistics
import subprocess
from pathlib import Path


def parse_run(text: str) -> dict[str, dict[str, float]]:
    result: dict[str, dict[str, float]] = {}
    current = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("Benchmark size") or line.startswith("Warming up") or line == "---":
            continue
        if not raw_line.startswith(" ") and ":" not in line:
            current = line
            result[current] = {}
            continue
        if current is None or ":" not in line or " ms" not in line:
            continue
        name, rest = line.split(":", 1)
        value = float(rest.strip().split(" ", 1)[0])
        result[current][name.strip()] = value
    return result


def run_binary(binary: Path, n: int, samples: int) -> dict[str, dict[str, list[float]]]:
    collected: dict[str, dict[str, list[float]]] = {}
    for _ in range(samples):
      proc = subprocess.run([str(binary), str(n)], check=True, capture_output=True, text=True)
      parsed = parse_run(proc.stdout)
      for impl, phases in parsed.items():
        impl_bucket = collected.setdefault(impl, {})
        for phase, value in phases.items():
          impl_bucket.setdefault(phase, []).append(value)
    return collected


def summarize(collected: dict[str, dict[str, list[float]]]) -> str:
    lines: list[str] = []
    for impl in sorted(collected):
      lines.append(impl)
      for phase in sorted(collected[impl]):
        values = collected[impl][phase]
        lines.append(
          f"  {phase}: median={statistics.median(values):.3f} ms "
          f"mean={statistics.fmean(values):.3f} min={min(values):.3f} max={max(values):.3f}"
        )
      lines.append("")
    return "\n".join(lines).rstrip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--n", type=int, default=50_000)
    parser.add_argument("--samples", type=int, default=30)
    args = parser.parse_args()

    collected = run_binary(args.binary, args.n, args.samples)
    print(summarize(collected))


if __name__ == "__main__":
    main()
