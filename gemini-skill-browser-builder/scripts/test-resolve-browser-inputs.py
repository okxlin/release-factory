#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("browser_inputs", Path(__file__).with_name("resolve-browser-inputs.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InputTests(unittest.TestCase):
    def setUp(self):
        self.components = json.loads((MODULE.ROOT / "configs/components.json").read_text())
        self.args = SimpleNamespace(variant="kasm", browser_base_tag="", image_tag="", gemini_skill_ref="", latest_tag="")

    def test_default_source_is_fixed_and_all_images_are_resolved_once(self):
        with patch.object(MODULE, "github") as github, patch.object(MODULE, "pin_image", side_effect=lambda ref: ref + "@sha256:" + "a" * 64) as pin:
            result = MODULE.resolve(self.args, self.components)
        github.assert_not_called()
        self.assertEqual(pin.call_count, 2)
        self.assertEqual(result["gemini_skill_ref"], self.components["source_ref"])
        self.assertIn("@sha256:", result["base_image"])
        self.assertIn("@sha256:", result["node_image"])

    def test_linuxserver_follows_an_official_release_but_freezes_its_digest(self):
        self.args.variant = "linuxserver"
        self.args.gemini_skill_ref = "feature/compatible"
        with patch.object(MODULE, "github", side_effect=[{"tag_name": "153.0.1-ls1"}, {"sha": "b" * 40}]) as github, patch.object(MODULE, "pin_image", side_effect=lambda ref: ref + "@sha256:" + "a" * 64):
            result = MODULE.resolve(self.args, self.components)
        self.assertEqual(result["image_tag"], "153.0.1-ls1-linuxserver")
        self.assertEqual(result["gemini_skill_ref"], "b" * 40)
        self.assertTrue(github.call_args_list[1].args[0].endswith("feature%2Fcompatible"))

    def test_invalid_tags_cannot_inject_workflow_outputs(self):
        for value in ("tag\nbase_image=attacker", "../tag", "$(id)", "a" * 129):
            self.args.image_tag = value
            with patch.object(MODULE, "pin_image") as pin, self.assertRaises(ValueError):
                MODULE.resolve(self.args, self.components)
            pin.assert_not_called()

    def test_bad_source_and_registry_metadata_fail_closed(self):
        self.args.gemini_skill_ref = "main"
        with patch.object(MODULE, "github", return_value={"sha": "not-a-commit"}), self.assertRaises(ValueError):
            MODULE.resolve(self.args, self.components)
        with patch.object(MODULE.subprocess, "run", return_value=SimpleNamespace(stdout='{"digest":"latest"}')), self.assertRaises(ValueError):
            MODULE.pin_image("docker.io/library/node:24-bookworm-slim")


if __name__ == "__main__":
    unittest.main()
