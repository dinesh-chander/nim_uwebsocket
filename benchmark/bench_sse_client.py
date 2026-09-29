#!/usr/bin/env python3
"""SSE benchmark client - measures events/sec and connection time."""

import time
import threading
import socket
import argparse
import statistics
import re

class SSEBenchResult:
    def __init__(self):
        self.events_received = 0
        self.connect_time_ms = 0.0
        self.total_time_ms = 0.0
        self.bytes_received = 0
        self.error = None

def decode_chunked(raw_body):
    decoded = b""
    pos = 0
    while pos < len(raw_body):
        end_of_size = raw_body.find(b"\r\n", pos)
        if end_of_size < 0:
            break
        size_str = raw_body[pos:end_of_size].strip()
        if not size_str:
            pos = end_of_size + 2
            continue
        try:
            chunk_size = int(size_str, 16)
        except ValueError:
            break
        if chunk_size == 0:
            break
        data_start = end_of_size + 2
        data_end = data_start + chunk_size
        if data_end > len(raw_body):
            decoded += raw_body[data_start:]
            break
        decoded += raw_body[data_start:data_end]
        pos = data_end + 2
    return decoded

def run_sse_connection(host, port, path, result):
    try:
        t0 = time.monotonic()
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)
        sock.connect((host, port))
        t_connected = time.monotonic()
        result.connect_time_ms = (t_connected - t0) * 1000.0

        request = f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n"
        sock.sendall(request.encode())

        buf = b""
        while True:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk

        t_done = time.monotonic()
        result.total_time_ms = (t_done - t0) * 1000.0
        result.bytes_received = len(buf)
        sock.close()

        header_end = buf.find(b"\r\n\r\n")
        if header_end < 0:
            return

        headers = buf[:header_end].decode("utf-8", errors="replace").lower()
        raw_body = buf[header_end + 4:]

        if "transfer-encoding: chunked" in headers:
            body = decode_chunked(raw_body).decode("utf-8", errors="replace")
        else:
            body = raw_body.decode("utf-8", errors="replace")

        for block in body.split("\n\n"):
            lines = block.strip().split("\n")
            if any(line.startswith("data:") for line in lines):
                result.events_received += 1
    except Exception as e:
        result.error = str(e)

def run_benchmark(host, port, path, concurrency, iterations, label):
    all_events = 0
    all_connect_times = []
    all_total_times = []
    all_bytes = 0
    errors = 0

    for iteration in range(iterations):
        results = [SSEBenchResult() for _ in range(concurrency)]
        threads = []

        for i in range(concurrency):
            t = threading.Thread(target=run_sse_connection, args=(host, port, path, results[i]))
            threads.append(t)
            t.start()

        for t in threads:
            t.join(timeout=30)

        for r in results:
            if r.error:
                errors += 1
            else:
                all_events += r.events_received
                all_connect_times.append(r.connect_time_ms)
                all_total_times.append(r.total_time_ms)
                all_bytes += r.bytes_received

    avg_wall_sec = (sum(all_total_times) / len(all_total_times) / 1000.0) if all_total_times else 1.0
    events_per_sec = all_events / avg_wall_sec if avg_wall_sec > 0 else 0
    total_connections = concurrency * iterations
    successful = total_connections - errors

    print(f"\n{'='*60}")
    print(f"  SSE Benchmark: {label}")
    print(f"{'='*60}")
    print(f"  Concurrency:        {concurrency}")
    print(f"  Iterations:         {iterations}")
    print(f"  Total connections:  {total_connections}")
    print(f"  Successful:         {successful}")
    print(f"  Errors:             {errors}")
    print(f"  Total events:       {all_events}")
    print(f"  Events/sec:         {events_per_sec:,.0f}")
    if successful > 0:
        print(f"  Events/connection:  {all_events / successful:.1f}")

    if all_connect_times:
        print(f"\n  Connect time (ms):")
        print(f"    avg:  {statistics.mean(all_connect_times):.2f}")
        print(f"    p50:  {sorted(all_connect_times)[len(all_connect_times)//2]:.2f}")
        print(f"    p99:  {sorted(all_connect_times)[int(len(all_connect_times)*0.99)]:.2f}")

    if all_total_times:
        print(f"\n  Total time (ms):")
        print(f"    avg:  {statistics.mean(all_total_times):.2f}")
        print(f"    p50:  {sorted(all_total_times)[len(all_total_times)//2]:.2f}")
        print(f"    p99:  {sorted(all_total_times)[int(len(all_total_times)*0.99)]:.2f}")

    print(f"{'='*60}")
    return events_per_sec

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="SSE Benchmark Client")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3005)
    parser.add_argument("--path", default=None)
    parser.add_argument("--concurrency", type=int, default=100)
    parser.add_argument("--iterations", type=int, default=5)
    args = parser.parse_args()

    if args.path:
        run_benchmark(args.host, args.port, args.path, args.concurrency, args.iterations, f"GET {args.path} x{args.concurrency}")
    else:
        run_benchmark(args.host, args.port, "/sse", args.concurrency, args.iterations, f"GET /sse (batched 100 events) x{args.concurrency}")
        run_benchmark(args.host, args.port, "/sse/large", args.concurrency, args.iterations, f"GET /sse/large (batched 10 large) x{args.concurrency}")
