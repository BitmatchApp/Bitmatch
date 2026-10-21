#!/usr/bin/env python3
"""Validate a focused physical large-file app-host test and its receipt."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


SMOKE_SIZES = [size * 1024 * 1024 for size in (1, 2, 3, 4, 5, 7, 20, 22)]
LARGE_SIZES = [2_000_000_000, 3_000_000_000, 4_000_000_000, 5_000_000_000,
               7_000_000_000, 8_800_000_000, 44_500_000_000, 45_300_000_000]
WORKLOADS = {
    "smoke": ("smoke64MiB", sum(SMOKE_SIZES), SMOKE_SIZES),
    "large": ("physical119_6GB", sum(LARGE_SIZES), LARGE_SIZES),
}
TEST_NAME = "testOptInLargeFilePhysicalAppMemory"
TEST_CLASS = "PhysicalLargeFileAppMemoryTests"
TEST_CASE_LINE = f"Test Case '-[BitMatchTests.{TEST_CLASS} {TEST_NAME}]'"
SUCCESS_BANNERS = {"** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **"}
FAILURE_BANNERS = {"** TEST FAILED **", "** TEST EXECUTE FAILED **"}
MAX_LOG_BYTES = 64 * 1024 * 1024
MAX_RECEIPT_BYTES = 8 * 1024 * 1024


class ValidationError(ValueError):
    pass


def validate_receipt(receipt: object, workload: str) -> None:
    if workload not in WORKLOADS:
        raise ValidationError("Unknown workload")
    label, expected_bytes, expected_sizes = WORKLOADS[workload]
    if not isinstance(receipt, dict):
        raise ValidationError("Receipt must be a JSON object")

    required = {
        "complete": True,
        "outcome": "passed",
        "cleanup": "passed-owned-children-removed",
        "workload": label,
        "expectedWorkloadBytes": expected_bytes,
        "generatedPayloadBytes": expected_bytes,
        "selectedFiles": 8,
        "selectedBytes": expected_bytes,
        "verifiedRows": 8,
        "savedCheckFiles": 8,
        "automaticReports": ["pdf", "csv", "json"],
        "sdUsedForTransfer": False,
        "sdOwnerMetadataValidated": True,
        "pipelinedVerification": True,
        "verificationWorkers": 2,
    }
    for key, expected in required.items():
        actual = receipt.get(key)
        if key == "automaticReports":
            if not isinstance(actual, list) or set(actual) != set(expected):
                raise ValidationError(f"Receipt field {key} is inconsistent")
        elif actual != expected:
            raise ValidationError(f"Receipt field {key} is inconsistent")

    generated = receipt.get("generatedFiles")
    if not isinstance(generated, list) or len(generated) != 8:
        raise ValidationError("Receipt must list exactly eight generated files")
    if any(not isinstance(item, dict) for item in generated):
        raise ValidationError("Generated-file entries must be objects")
    generated_names: set[str] = set()
    for item in generated:
        name, size, digest = item.get("name"), item.get("size"), item.get("sha256")
        if not isinstance(name, str) or not name or name in generated_names:
            raise ValidationError("Generated-file names must be unique")
        if not isinstance(size, int) or size <= 0:
            raise ValidationError("Generated-file sizes must be positive integers")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-fA-F]{64}", digest) is None:
            raise ValidationError("Generated-file SHA-256 values must be complete")
        generated_names.add(name)
    if sum(item["size"] for item in generated) != expected_bytes:
        raise ValidationError("Generated-file sizes do not match the workload")
    expected_files = [(f"clip-{index:02d}.mov", size)
                      for index, size in enumerate(expected_sizes, start=1)]
    if [(item["name"], item["size"]) for item in generated] != expected_files:
        raise ValidationError("Generated-file shape does not match the selected workload")

    inventory_files = receipt.get("sourceInventoryFiles")
    result_rows = receipt.get("resultRows")
    source_bytes = receipt.get("sourceBytes")
    if not isinstance(inventory_files, int) or inventory_files < 8 or result_rows != inventory_files:
        raise ValidationError("Source inventory and durable result-row counts disagree")
    exclusions = receipt.get("excludedAppleDoubleFiles")
    if (not isinstance(exclusions, list) or len(exclusions) != inventory_files - 8
            or len(set(exclusions)) != len(exclusions)):
        raise ValidationError("AppleDouble exclusion count does not match the source inventory")
    if not isinstance(source_bytes, int) or source_bytes < expected_bytes:
        raise ValidationError("Source inventory byte count is too small")
    if receipt.get("selectedFiles") != len(generated):
        raise ValidationError("Selected-file count differs from generated-file count")

    source_rehash_count = receipt.get("sourceRehashFiles")
    destination_rehash_count = receipt.get("destinationRehashFiles")
    source_hashes = receipt.get("independentlyHashedSource")
    destination_hashes = receipt.get("independentlyHashedDestination")
    if (source_rehash_count != inventory_files or not isinstance(source_hashes, list)
            or len(source_hashes) != source_rehash_count):
        raise ValidationError("Independent source rehash does not cover the inventory")
    if (not isinstance(destination_rehash_count, int) or destination_rehash_count < 8
            or not isinstance(destination_hashes, list) or len(destination_hashes) != destination_rehash_count):
        raise ValidationError("Independent destination rehash is incomplete")
    if receipt.get("verifiedSourceAndDestinationFiles") != source_rehash_count + destination_rehash_count:
        raise ValidationError("Independent hash coverage total is inconsistent")

    def hashes_by_name(items: list[object]) -> dict[str, tuple[int, str]]:
        result: dict[str, tuple[int, str]] = {}
        for item in items:
            if not isinstance(item, dict):
                raise ValidationError("Independent hash entries must be objects")
            name, size, digest = item.get("name"), item.get("size"), item.get("sha256")
            if (not isinstance(name, str) or not isinstance(size, int) or size < 0
                    or not isinstance(digest, str) or re.fullmatch(r"[0-9a-fA-F]{64}", digest) is None
                    or name in result):
                raise ValidationError("Independent hash entry is invalid or duplicated")
            result[name] = (size, digest.lower())
        return result

    source_by_name = hashes_by_name(source_hashes)
    destination_by_name = hashes_by_name(destination_hashes)
    generated_by_name = {item["name"]: (item["size"], item["sha256"].lower()) for item in generated}
    if sum(size for size, _ in source_by_name.values()) != source_bytes:
        raise ValidationError("Independent source hash sizes do not match sourceBytes")
    if any(source_by_name.get(name) != item or destination_by_name.get(name) != item
           for name, item in generated_by_name.items()):
        raise ValidationError("Generated payload hashes differ from source or destination rehash")

    memory = receipt.get("memory")
    if not isinstance(memory, dict):
        raise ValidationError("Memory measurements are missing")
    if (not isinstance(memory.get("sampleCount"), int) or memory["sampleCount"] <= 0
            or memory.get("missingSample") is not False
            or memory.get("runtimeLimitHit") is not False
            or not isinstance(memory.get("peakMiB"), int)
            or not 0 < memory["peakMiB"] < 1024):
        raise ValidationError("Memory measurements are incomplete or exceeded the guard")
    if not isinstance(receipt.get("transferSeconds"), (int, float)) or receipt["transferSeconds"] <= 0:
        raise ValidationError("Transfer duration is missing")


def validate_run(log_text: str, receipt_paths: list[Path], workload: str, xcode_status: int) -> dict:
    if xcode_status != 0:
        raise ValidationError(f"xcodebuild exited with status {xcode_status}")
    matching = [line for line in log_text.splitlines() if line.startswith(TEST_CASE_LINE)]
    started_pattern = re.compile(r"^" + re.escape(TEST_CASE_LINE) + r"\s+started\.?\s*$", re.IGNORECASE)
    terminal_pattern = re.compile(r"^" + re.escape(TEST_CASE_LINE) + r"\s+(passed|failed|skipped)\b", re.IGNORECASE)
    started = [line for line in matching if started_pattern.match(line)]
    terminals = [terminal_pattern.match(line) for line in matching]
    terminal_statuses = [match.group(1).lower() for match in terminals if match]
    if (len(started) > 1 or len(started) + len(terminal_statuses) != len(matching)
            or terminal_statuses != ["passed"]):
        raise ValidationError("Focused XCTest was skipped, missing, or did not pass exactly once")
    banners = [line.strip() for line in log_text.splitlines()
               if line.strip() in SUCCESS_BANNERS | FAILURE_BANNERS]
    successes = [banner for banner in banners if banner in SUCCESS_BANNERS]
    failures = [banner for banner in banners if banner in FAILURE_BANNERS]
    if len(successes) != 1 or failures:
        raise ValidationError("Xcode must report exactly one successful test banner and no failure banner")
    if len(receipt_paths) != 1:
        raise ValidationError("Expected exactly one physical app-memory receipt")
    try:
        receipt = json.loads(receipt_paths[0].read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"Receipt is missing or unreadable: {error}") from error
    validate_receipt(receipt, workload)
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--workload", choices=WORKLOADS, required=True)
    parser.add_argument("--xcode-status", required=True, type=int)
    args = parser.parse_args()
    try:
        if args.log.stat().st_size > MAX_LOG_BYTES:
            raise ValidationError("Test log exceeds the 64 MiB validation limit")
        log_text = args.log.read_text(errors="replace")
        receipts = list(args.evidence_root.rglob("large-file-app-memory.json"))
        for path in receipts:
            if path.stat().st_size > MAX_RECEIPT_BYTES:
                raise ValidationError("Receipt exceeds the 8 MiB validation limit")
        receipt = validate_run(log_text, receipts, args.workload, args.xcode_status)
    except (OSError, ValidationError) as error:
        print(f"Physical app-memory probe validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "Physical app-memory probe passed: "
        f"workload={receipt['workload']} bytes={receipt['generatedPayloadBytes']} "
        f"files={receipt['selectedFiles']} peakMiB={receipt['memory']['peakMiB']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
