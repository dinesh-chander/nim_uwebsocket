import platform
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ITERATIONS = 10
COMMON_PATHS = [
    f"--path:{ROOT / 'nim_utils/src'}",
    f"--path:{ROOT / 'nim_usockets/src'}",
    f"--path:{ROOT / 'nim_fasthttpclient/src'}",
    f"--path:{ROOT / 'nim_express/src'}",
    f"--path:{ROOT / 'vendor/zippy/src'}",
    f"--path:{ROOT / 'vendor/brotli/src'}",
    f"--path:{ROOT / 'vendor/nim_zstd'}",
    f"--path:{ROOT / 'vendor/nim_libdeflate_gzip/src'}",
    f"--path:{ROOT / 'vendor/malebolgia/src'}",
    f"--path:{ROOT / 'vendor/jsony/src'}",
    f"--path:{ROOT / 'vendor/checksums'}",
]


def platform_link_flags() -> str:
    system = platform.system()
    flags = str(ROOT / "nim_usockets/usockets/uSockets.a")
    if system == "Darwin":
        flags += " -framework CoreFoundation"
    elif system == "Linux":
        flags += " -lpthread -ldl"
    return flags


def run(cmd: list[str], cwd: Path) -> None:
    print(f"$ ({cwd}) {' '.join(cmd)}", flush=True)
    subprocess.run(cmd, cwd=str(cwd), check=True)


def main() -> int:
    express_compile = [
        "nim",
        "c",
        "-r",
        *COMMON_PATHS,
        "--passL:" + platform_link_flags(),
    ]
    run(express_compile + ["nim_express/tests/test_http_surface_compliance.nim"], ROOT)
    run(express_compile + ["nim_express/tests/test_http_surface_compliance_extended.nim"], ROOT)

    uws_compile = [
        "nim",
        "c",
        "-r",
        "-d:nimUwebsocketsTest",
        *COMMON_PATHS,
        "--passL:" + platform_link_flags(),
    ]
    uws_root = ROOT / "nim_usockets"
    run(uws_compile + ["tests/test_http_parser_framing_compliance.nim"], uws_root)
    run(uws_compile + ["tests/test_http_parser_rfc_extended.nim"], uws_root)
    run(uws_compile + ["tests/test_http_parser_property_fuzz_compliance.nim"], uws_root)

    binaries = [
        ROOT / "nim_express/tests/test_http_surface_compliance",
        ROOT / "nim_express/tests/test_http_surface_compliance_extended",
        ROOT / "nim_usockets/tests/test_http_parser_framing_compliance",
        ROOT / "nim_usockets/tests/test_http_parser_rfc_extended",
        ROOT / "nim_usockets/tests/test_http_parser_property_fuzz_compliance",
    ]

    for i in range(1, ITERATIONS + 1):
        print(f"\n=== HTTP compliance iteration {i}/{ITERATIONS} ===", flush=True)
        for binary in binaries:
            run([str(binary)], ROOT)

    print(f"\nAll HTTP compliance suites passed for {ITERATIONS}/{ITERATIONS} iterations.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(f"\nFAILED: command exited with {exc.returncode}", file=sys.stderr)
        raise
