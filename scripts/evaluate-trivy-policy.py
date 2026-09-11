#!/usr/bin/env python3
"""Apply explicit image profiles and exact, expiring exceptions to a raw scan."""

import argparse
from collections import Counter
import datetime
import json
import os
from pathlib import Path, PurePosixPath
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def path_key(value):
    require(isinstance(value, str) and value.strip(), "path must be nonempty")
    require(not any(c in value for c in "*?[]\\\n\r"), "paths cannot contain wildcards or escapes")
    require(".." not in PurePosixPath(value).parts, "paths cannot traverse directories")
    return str(PurePosixPath(value)).lstrip("/")


def load_policy(path, profile):
    policy = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(policy, dict) and set(policy) == {
        "schema_version", "profiles", "protected_paths", "exceptions",
    }, "invalid policy fields")
    require(policy["schema_version"] == 1, "unsupported policy schema")
    require(isinstance(policy["profiles"], dict) and profile in policy["profiles"], "unknown profile")
    thresholds = policy["profiles"][profile]
    require(isinstance(thresholds, dict) and set(thresholds) == {
        "max_fixable_critical", "max_fixable_high",
    }, "invalid profile thresholds")
    for value in thresholds.values():
        require(value is None or (type(value) is int and value >= 0), "invalid threshold")
    require(isinstance(policy["protected_paths"], list) and policy["protected_paths"], "missing protected paths")
    for value in policy["protected_paths"]:
        require(path_key(value) not in {"", "."}, "invalid protected path")
    require(isinstance(policy["exceptions"], list), "exceptions must be a list")
    for exception in policy["exceptions"]:
        require(isinstance(exception, dict) and set(exception) == {
            "id", "package", "installed_version", "path", "type", "profiles",
            "reason", "reference", "expires",
        }, "invalid exception fields")
        for key, value in exception.items():
            if key != "profiles":
                require(isinstance(value, str) and value.strip(), f"exception {key} must be nonempty")
        require(path_key(exception["path"]) not in {"", "."} and not exception["path"].endswith("/"),
                "exception must name an exact file")
        require(isinstance(exception["profiles"], list) and exception["profiles"] and
                all(p in policy["profiles"] for p in exception["profiles"]), "invalid exception profiles")
        require(exception["reference"].startswith("https://"), "exception needs an HTTPS reference")
        datetime.date.fromisoformat(exception["expires"])
    return policy, thresholds


def findings(data):
    require(isinstance(data, dict) and data.get("SchemaVersion") == 2 and
            isinstance(data.get("Results"), list) and data["Results"], "invalid or empty Trivy report")
    for result in data["Results"]:
        require(isinstance(result, dict) and isinstance(result.get("Target"), str) and
                isinstance(result.get("Type"), str), "invalid Trivy result")
        vulnerabilities = result.get("Vulnerabilities")
        require(vulnerabilities is None or isinstance(vulnerabilities, list), "invalid vulnerabilities")
        for vuln in vulnerabilities or []:
            require(isinstance(vuln, dict) and vuln.get("Severity") in {
                "UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL",
            }, "invalid vulnerability severity")
            if vuln["Severity"] not in {"HIGH", "CRITICAL"}:
                continue
            for field in ("VulnerabilityID", "PkgName", "InstalledVersion"):
                require(isinstance(vuln.get(field), str) and vuln[field], f"missing {field}")
            require(isinstance(vuln.get("FixedVersion", ""), str), "invalid fixed version")
            path = path_key(vuln.get("PkgPath") or result["Target"])
            if result["Type"] == "node-pkg":
                require("/" in path and path.endswith("package.json"), "cannot classify Node.js package path")
            yield result, vuln, path


def evaluate(data, policy, thresholds, profile):
    counts = Counter()
    fixable = Counter()
    records = []
    today = datetime.datetime.now(datetime.UTC).date()
    for result, vuln, path in findings(data):
        severity = vuln["Severity"]
        counts[severity] += 1
        protected = any(
            path == path_key(root) or (root.endswith("/") and path.startswith(path_key(root) + "/"))
            for root in policy["protected_paths"]
        )
        exception = next((entry for entry in policy["exceptions"] if
            profile in entry["profiles"] and
            (entry["id"], entry["package"], entry["installed_version"], path_key(entry["path"]), entry["type"]) ==
            (vuln["VulnerabilityID"], vuln["PkgName"], vuln["InstalledVersion"], path, result["Type"]) and
            today < datetime.date.fromisoformat(entry["expires"])
        ), None)
        if not exception:
            if vuln.get("FixedVersion"):
                fixable[severity] += 1
            if protected:
                counts["protected"] += 1
        else:
            counts["excepted"] += 1
        records.append((vuln, path, protected, exception))
    exceeded = {
        severity for severity in ("CRITICAL", "HIGH")
        if thresholds[f"max_fixable_{severity.lower()}"] is not None and
        fixable[severity] > thresholds[f"max_fixable_{severity.lower()}"]
    }
    print(f"Trivy profile={profile}: critical={counts['CRITICAL']} high={counts['HIGH']} "
          f"fixable_critical={fixable['CRITICAL']} fixable_high={fixable['HIGH']} "
          f"protected={counts['protected']} excepted={counts['excepted']}")
    for vuln, path, protected, exception in records:
        decision = "EXCEPTED" if exception else (
            "BLOCK" if protected or (vuln.get("FixedVersion") and vuln["Severity"] in exceeded) else "WARN"
        )
        detail = (f"{vuln['Severity']} {vuln['VulnerabilityID']}: {vuln['PkgName']} "
                  f"{vuln['InstalledVersion']} -> {vuln.get('FixedVersion') or '(no fix)'} ({path})")
        if exception:
            detail += f"; expires={exception['expires']}; {exception['reason']}; {exception['reference']}"
        print(f"- {decision}: {' '.join(detail.split())}")
    blocked = bool(exceeded or counts["protected"])
    if records and not blocked and os.environ.get("GITHUB_ACTIONS") == "true":
        print("::warning title=Image vulnerabilities require review::See Trivy findings and scoped exceptions in the gate log")
    return int(blocked)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        policy, thresholds = load_policy(args.policy, args.profile)
        return evaluate(json.loads(args.report.read_text(encoding="utf-8")), policy, thresholds, args.profile)
    except (OSError, ValueError, TypeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
