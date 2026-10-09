#!/usr/bin/env python3
"""Maintain one component PR and merge only the exact candidate verified by this run."""

import argparse
import base64
import json
import os
import re
import subprocess
from pathlib import Path

BRANCH = "automation/deepseek-harness-components"
FILES = ["deepseek-harness-builder/image/components.lock.json", "deepseek-harness-builder/image/dsh-source.json"]
BOT = {"name": "github-actions[bot]", "email": "41898282+github-actions[bot]@users.noreply.github.com"}
RELEASED = "<!-- dsh-component-releases-dispatched -->"
WORKFLOWS = ["build-deepseek-harness.yml", "build-deepseek-harness-workstation.yml"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(route, method="GET", data=None, missing_ok=False):
    command = ["gh", "api", route, "--method", method]
    if data is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True)
    if missing_ok and result.returncode and "(HTTP 404)" in result.stderr:
        return None
    require(result.returncode == 0, f"GitHub {method} failed: {result.stderr.strip()}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def validate_pr(pr, repo, allow_merged=False):
    require((pr["state"] == "open" or (allow_merged and pr.get("merged"))) and pr["base"]["ref"] == "main"
            and pr["head"]["ref"] == BRANCH and pr["head"]["repo"]["full_name"] == repo
            and pr["user"]["login"] == "github-actions[bot]", "unexpected component PR ownership or target")


def validate_diff(comparison):
    files = comparison.get("files", [])
    require(files and all(f["filename"] in FILES and f["status"] == "modified" for f in files),
            "component candidate may only modify the two pin files")
    commits = comparison.get("commits", [])
    require(len(commits) == comparison.get("total_commits"), "incomplete component commit history")
    require(all((c.get("committer") or {}).get("login") == "github-actions[bot]" for c in commits),
            "component branch contains a human or unrelated commit; refusing to replace it")


def compare(route, base, head):
    comparison = api(route + f"/compare/{base}...{head}?per_page=100&page=1")
    page = 2
    while len(comparison["commits"]) < comparison["total_commits"]:
        more = api(route + f"/compare/{base}...{head}?per_page=100&page={page}")["commits"]
        require(more, "incomplete component commit history")
        comparison["commits"].extend(more)
        page += 1
    return comparison


def prepare(repo, summary, output):
    route = "repos/" + repo
    base = api(route + "/git/ref/heads/main")["object"]["sha"]
    local = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    require(base == local == os.environ["GITHUB_SHA"], "main advanced; rerun the updater from current main")
    pulls = api(route + f"/pulls?state=open&head={repo.split('/')[0]}:{BRANCH}&per_page=100")
    require(len(pulls) <= 1, "ambiguous component PR")
    if pulls:
        validate_pr(pulls[0], repo)
    ref = api(route + "/git/ref/heads/" + BRANCH, missing_ok=True)
    previous = ref["object"]["sha"] if ref else None
    if previous:
        comparison = compare(route, base, previous)
        # A previously merged branch has no unique commits and can be reused.
        if comparison["ahead_by"]:
            validate_diff(comparison)
    base_tree = api(route + "/git/commits/" + base)["tree"]["sha"]
    entries = []
    for filename in FILES:
        path = Path(filename)
        require(path.is_file() and not path.is_symlink(), "invalid generated pin file")
        entries.append({"path": filename, "mode": "100644", "type": "blob", "content": path.read_text()})
    tree = api(route + "/git/trees", "POST", {"base_tree": base_tree, "tree": entries})["sha"]
    require(tree != base_tree, "no component changes to submit")
    prior_commit = api(route + "/git/commits/" + previous) if previous else None
    if prior_commit and prior_commit["tree"]["sha"] == tree:
        head = previous
    else:
        # Append history, including current main. Never force-push or rebase the bot branch.
        parents = list(dict.fromkeys([previous, base] if previous else [base]))
        head = api(route + "/git/commits", "POST", {
            "message": "chore(deepseek-harness): refresh component pins", "tree": tree,
            "parents": parents, "author": BOT, "committer": BOT,
        })["sha"]
        if previous:
            # Detect a concurrent writer before a non-forced ref update.
            require(api(route + "/git/ref/heads/" + BRANCH)["object"]["sha"] == previous,
                    "component branch advanced concurrently")
            api(route + "/git/refs/heads/" + BRANCH, "PATCH", {"sha": head, "force": False})
        else:
            api(route + "/git/refs", "POST", {"ref": "refs/heads/" + BRANCH, "sha": head})
    run_url = f"https://github.com/{repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    body = summary + ("\nAutomated component update. Checksums and both architecture image indexes were resolved "
                      "from official sources. License digests remain unchanged.\n\n"
                      f"[Verification run]({run_url}) builds and tests runtime and workstation on amd64 and arm64, "
                      "then applies the existing vulnerability gates. Only a successful candidate is squash-merged "
                      "and sent to the existing release workflows. A failed candidate remains open.\n")
    if pulls:
        number = pulls[0]["number"]
        api(route + f"/pulls/{number}", "PATCH", {"body": body})
    else:
        number = api(route + "/pulls", "POST", {
            "title": "chore(deepseek-harness): update components", "head": BRANCH, "base": "main", "body": body,
        })["number"]
    check = api(route + "/check-runs", "POST", {
        "name": "DeepSeek Harness component update", "head_sha": head,
        "status": "in_progress", "details_url": run_url,
    })["id"]
    with output.open("a") as target:
        for key, value in {"head": head, "base": base, "pr": number, "check": check}.items():
            target.write(f"{key}={value}\n")
    print(f"Component PR #{number}: {head}")


def dispatch_releases(repo, pr, revision):
    route = "repos/" + repo
    if RELEASED in (pr.get("body") or ""):
        return
    source = api(route + f"/contents/{FILES[1]}?ref={revision}")
    version = json.loads(base64.b64decode(source["content"]))["version"]
    require(re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", version), "invalid release version")
    correlation = f"{pr['number']}-{revision}"
    dispatched = set()
    page = 1
    while True:
        runs = api(route + f"/actions/runs?head_sha={revision}&event=workflow_dispatch&per_page=100&page={page}")["workflow_runs"]
        for run in runs:
            if (run["head_sha"] == revision and run["event"] == "workflow_dispatch"
                    and run["display_title"] == "Component update " + correlation
                    and run["actor"]["login"] == "github-actions[bot]"):
                dispatched.add(run["path"])
        if len(runs) < 100:
            break
        page += 1
    # Dispatch is an explicit GITHUB_TOKEN event; bot pushes may not start workflows.
    # https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow
    for workflow in WORKFLOWS:
        if ".github/workflows/" + workflow in dispatched:
            continue
        require(api(route + "/git/ref/heads/main")["object"]["sha"] == revision, "main advanced before release dispatch")
        api(route + f"/actions/workflows/{workflow}/dispatches", "POST", {
            "ref": "main", "inputs": {"dsh_version": version, "component_update": correlation,
                                       "push_latest": "true", "refresh_system_packages": "true"},
        })
    body = api(route + f"/pulls/{pr['number']}").get("body") or ""
    if RELEASED not in body:
        api(route + f"/pulls/{pr['number']}", "PATCH", {"body": body + "\n\n" + RELEASED})
    print(f"Both release dispatches confirmed for component PR #{pr['number']}: {version}")


def recover(repo):
    """Retry a post-merge API interruption even when today's resolver finds no updates."""
    route = "repos/" + repo
    pulls = api(route + f"/pulls?state=closed&head={repo.split('/')[0]}:{BRANCH}&per_page=100&sort=updated&direction=desc")
    for listed in pulls:
        if not listed.get("merged_at") or RELEASED in (listed.get("body") or ""):
            continue
        pr = api(route + f"/pulls/{listed['number']}")
        validate_pr(pr, repo, allow_merged=True)
        revision = api(route + "/git/ref/heads/main")["object"]["sha"]
        same_pins = all(api(route + f"/contents/{file}?ref={revision}")["sha"] ==
                        api(route + f"/contents/{file}?ref={pr['merge_commit_sha']}")["sha"] for file in FILES)
        if same_pins:
            dispatch_releases(repo, pr, revision)
        else:
            print(f"Component PR #{pr['number']} was superseded by different pins; no older release dispatched")
        return


def finish(repo, number, head, base, check, result):
    route = "repos/" + repo
    api(route + f"/check-runs/{check}", "PATCH", {
        "status": "completed", "conclusion": "success" if result == "success" else "failure",
    })
    require(result == "success", "candidate verification failed; PR remains open and no release was dispatched")
    pr = api(route + f"/pulls/{number}")
    validate_pr(pr, repo, allow_merged=True)
    require(pr["head"]["sha"] == head, "component PR head changed after verification")
    if pr.get("merged"):
        dispatch_releases(repo, pr, pr["merge_commit_sha"])
        return
    require(api(route + "/git/ref/heads/main")["object"]["sha"] == base,
            "main advanced after verification; rerun before merging")
    validate_diff(compare(route, base, head))
    merged = api(route + f"/pulls/{number}/merge", "PUT", {
        "sha": head, "merge_method": "squash", "commit_title": f"chore(deepseek-harness): update components (#{number})",
    })
    require(merged["merged"], "component PR was not merged")
    require(api(route + "/git/ref/heads/main")["object"]["sha"] == merged["sha"], "main advanced before release dispatch")
    dispatch_releases(repo, dict(pr, number=number), merged["sha"])
    print(f"Squash-merged #{number} as {merged['sha']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["prepare", "finish", "recover"])
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = os.environ["GITHUB_REPOSITORY"]
    require(repo == "okxlin/release-factory" and os.environ["GITHUB_REF"] == "refs/heads/main",
            "component automation only writes to the owner repository from main")
    if args.operation == "recover":
        recover(repo)
    elif args.operation == "prepare":
        prepare(repo, args.summary.read_text(), args.output)
    else:
        head, base = os.environ["CANDIDATE_HEAD"], os.environ["CANDIDATE_BASE"]
        require(re.fullmatch(r"[a-f0-9]{40}", head) and re.fullmatch(r"[a-f0-9]{40}", base), "invalid candidate commit")
        finish(repo, int(os.environ["CANDIDATE_PR"]), head, base,
               int(os.environ["CANDIDATE_CHECK"]), os.environ["VERIFY_RESULT"])


if __name__ == "__main__":
    main()
