#!/usr/bin/env python3
"""Verify merge/publication boundaries with a fake GitHub API."""
import copy
import base64
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("automation", Path(__file__).with_name("component-update-pr.py"))
automation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(automation)
REPO = "okxlin/release-factory"
BASE, HEAD, MERGED = "a" * 40, "b" * 40, "c" * 40
PR = {"state": "open", "base": {"ref": "main"}, "head": {
    "ref": automation.BRANCH, "sha": HEAD, "repo": {"full_name": REPO}},
    "user": {"login": "github-actions[bot]"}}
DIFF = {"total_commits": 1, "files": [{"filename": automation.FILES[0], "status": "modified"}],
        "commits": [{"committer": {"login": "github-actions[bot]"}}]}


class MergeTests(unittest.TestCase):
    def run_finish(self, result="success", pr=None, base=BASE, diff=None):
        self.calls = []
        merged = False
        def api(route, method="GET", data=None):
            nonlocal merged
            self.calls.append((route, method, data))
            if route.endswith("/check-runs/9"): return {}
            if route.endswith("/pulls/5"): return pr or PR
            if "/contents/" in route: return {"content": base64.b64encode(b'{"version":"0.2.0-rc.2"}').decode()}
            if "/actions/runs?" in route: return {"workflow_runs": []}
            if route.endswith("/git/ref/heads/main"): return {"object": {"sha": MERGED if merged else base}}
            if "/compare/" in route: return diff or DIFF
            if route.endswith("/merge"):
                self.assertEqual(data["sha"], HEAD)
                self.assertEqual(data["merge_method"], "squash")
                merged = True
                return {"merged": True, "sha": MERGED}
            if route.endswith("/dispatches"):
                self.assertEqual(data["inputs"]["dsh_version"], "0.2.0-rc.2")
                self.assertEqual(data["inputs"]["component_update"], "5-" + MERGED)
                return None
            raise AssertionError(route)
        with patch.object(automation, "api", side_effect=api):
            automation.finish(REPO, 5, HEAD, BASE, 9, result)

    def test_success_squashes_exact_head_then_dispatches_both_variants(self):
        self.run_finish()
        writes = [route for route, method, _ in self.calls if method in {"POST", "PUT"}]
        self.assertTrue(writes[0].endswith("/merge"))
        self.assertEqual(len(writes), 3)
        self.assertIn("/build-deepseek-harness.yml/", writes[1])
        self.assertIn("/build-deepseek-harness-workstation.yml/", writes[2])

    def assert_no_release(self):
        self.assertFalse(any(route.endswith(("/merge", "/dispatches")) for route, _, _ in self.calls))

    def test_failed_or_cancelled_build_cannot_merge_or_publish(self):
        for status in ["failure", "cancelled", "skipped"]:
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "verification failed"):
                self.run_finish(status)
            self.assert_no_release()

    def test_incomplete_history_is_rejected(self):
        bad_diff = dict(DIFF, total_commits=251)
        with self.assertRaisesRegex(ValueError, "incomplete"):
            automation.validate_diff(bad_diff)

    def test_history_pagination_includes_newest_human_commit(self):
        first = dict(DIFF, total_commits=2, commits=copy.deepcopy(DIFF["commits"]))
        last = {"commits": [{"committer": {"login": "okxlin"}}]}
        with patch.object(automation, "api", side_effect=[first, last]) as api:
            complete = automation.compare("repos/" + REPO, BASE, HEAD)
        self.assertIn("page=2", api.call_args.args[0])
        with self.assertRaisesRegex(ValueError, "human"):
            automation.validate_diff(complete)


    def test_changed_head_or_base_cannot_reuse_verification(self):
        pr = copy.deepcopy(PR); pr["head"]["sha"] = "d" * 40
        for kwargs in [{"pr": pr}, {"base": "d" * 40}]:
            with self.assertRaises(ValueError): self.run_finish(**kwargs)
            self.assert_no_release()

    def test_foreign_author_or_workflow_edit_cannot_auto_merge(self):
        bad_pr = copy.deepcopy(PR); bad_pr["user"]["login"] = "someone"
        bad_diff = copy.deepcopy(DIFF); bad_diff["files"][0]["filename"] = ".github/workflows/release.yml"
        human_diff = copy.deepcopy(DIFF); human_diff["commits"][0]["committer"]["login"] = "okxlin"
        for kwargs in [{"pr": bad_pr}, {"diff": bad_diff}, {"diff": human_diff}]:
            with self.assertRaises(ValueError): self.run_finish(**kwargs)
            self.assert_no_release()


class PrepareTests(unittest.TestCase):
    def test_existing_pr_is_refreshed_by_appending_history(self):
        for same_tree in [False, True]:
            calls = []
            ref = HEAD
            def api(route, method="GET", data=None, missing_ok=False):
                nonlocal ref
                calls.append((route, method, data))
                if route.endswith("/git/ref/heads/main"): return {"object": {"sha": BASE}}
                if "/pulls?" in route: return [dict(PR, number=5)]
                if route.endswith("/git/ref/heads/" + automation.BRANCH): return {"object": {"sha": ref}}
                if "/compare/" in route: return dict(DIFF, ahead_by=1)
                if route.endswith("/git/commits/" + BASE): return {"tree": {"sha": "base-tree"}}
                if route.endswith("/git/commits/" + HEAD):
                    return {"tree": {"sha": "new-tree" if same_tree else "old-tree"}}
                if route.endswith("/git/trees"):
                    self.assertEqual(data["base_tree"], "base-tree")
                    self.assertEqual([x["path"] for x in data["tree"]], automation.FILES)
                    return {"sha": "new-tree"}
                if route.endswith("/git/commits"):
                    self.assertEqual(data["parents"], [HEAD, BASE])
                    return {"sha": MERGED}
                if route.endswith("/git/refs/heads/" + automation.BRANCH):
                    self.assertIs(data["force"], False)
                    ref = data["sha"]
                    return {}
                if route.endswith("/pulls/5"): return {}
                if route.endswith("/check-runs"): return {"id": 9}
                raise AssertionError(route)
            original_dir = Path.cwd()
            with tempfile.TemporaryDirectory() as temporary:
                try:
                    os.chdir(temporary)
                    for name in automation.FILES:
                        path = Path(name); path.parent.mkdir(parents=True, exist_ok=True); path.write_text("{}\n")
                    output = Path("output")
                    with patch.object(automation, "api", side_effect=api), \
                         patch.object(automation.subprocess, "check_output", return_value=BASE + "\n"), \
                         patch.dict(os.environ, {"GITHUB_SHA": BASE, "GITHUB_RUN_ID": "123"}):
                        automation.prepare(REPO, "Changes", output)
                    self.assertIn("pr=5\n", output.read_text())
                    self.assertIn("head=" + (HEAD if same_tree else MERGED), output.read_text())
                    self.assertFalse(any(r.endswith("/pulls") and m == "POST" for r, m, _ in calls))
                    self.assertEqual(sum(r.endswith("/git/commits") and m == "POST" for r, m, _ in calls), int(not same_tree))
                finally:
                    os.chdir(original_dir)


class RecoveryTests(unittest.TestCase):
    def test_partial_dispatch_after_merge_is_recovered_without_duplicate_or_new_version(self):
        pr = dict(copy.deepcopy(PR), number=5, state="closed", merged=True, merge_commit_sha=MERGED, body="Update")
        correlation = "5-" + MERGED
        runs, dispatched, merged_again = [], [], []
        interrupt = True
        def api(route, method="GET", data=None):
            nonlocal interrupt
            if route.endswith("/check-runs/9"): return {}
            if route.endswith("/pulls/5"):
                if method == "PATCH": pr.update(data)
                return pr
            if route.endswith("/git/ref/heads/main"): return {"object": {"sha": MERGED}}
            if "/contents/" in route: return {"content": base64.b64encode(b'{"version":"0.2.0-rc.2"}').decode()}
            if "/actions/runs?" in route: return {"workflow_runs": runs}
            if route.endswith("/merge"): merged_again.append(route); raise AssertionError("already merged")
            if route.endswith("/dispatches"):
                workflow = route.split("/workflows/")[1].split("/")[0]
                if "workstation" in workflow and interrupt:
                    interrupt = False
                    raise RuntimeError("temporary GitHub error")
                self.assertEqual(data["inputs"]["dsh_version"], "0.2.0-rc.2")
                dispatched.append(workflow)
                runs.append({"head_sha": MERGED, "event": "workflow_dispatch", "display_title": "Component update " + correlation,
                             "actor": {"login": "github-actions[bot]"}, "path": ".github/workflows/" + workflow})
                return None
            raise AssertionError(route)
        with patch.object(automation, "api", side_effect=api):
            with self.assertRaisesRegex(RuntimeError, "temporary"):
                automation.finish(REPO, 5, HEAD, BASE, 9, "success")
            automation.finish(REPO, 5, HEAD, BASE, 9, "success")
            automation.finish(REPO, 5, HEAD, BASE, 9, "success")
        self.assertEqual(dispatched, automation.WORKFLOWS)
        self.assertFalse(merged_again)
        self.assertIn(automation.RELEASED, pr["body"])

    def test_daily_no_change_recovery_requires_same_pin_blobs(self):
        pr = dict(copy.deepcopy(PR), number=5, state="closed", merged=True, merged_at="2026-10-09", merge_commit_sha=MERGED, body="Update")
        for same in [True, False]:
            def api(route):
                if "/pulls?" in route: return [pr]
                if route.endswith("/pulls/5"): return pr
                if route.endswith("/git/ref/heads/main"): return {"object": {"sha": HEAD}}
                if "/contents/" in route: return {"sha": "blob" if same or route.endswith(MERGED) else "different"}
                raise AssertionError(route)
            with patch.object(automation, "api", side_effect=api), patch.object(automation, "dispatch_releases") as dispatch:
                automation.recover(REPO)
                self.assertEqual(dispatch.call_count, int(same))



if __name__ == "__main__":
    unittest.main()
