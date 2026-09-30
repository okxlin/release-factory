#!/usr/bin/env python3
"""Keep file browsing covered across LinuxServer's Selkies route migration."""
import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("smoke", Path(__file__).with_name("smoke-gemini-browser.py"))
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class FileBrowserTests(unittest.TestCase):
    def run_smoke(self, route, *, listing="rf-smoke.txt", content="release-factory files smoke"):
        requested = []

        def docker(*args, **kwargs):
            output = ""
            if args[0] == "exec" and "curl" in args:
                url = args[-1]
                if url.endswith("/health"):
                    output = '{"service":"browser-daemon"}'
                elif url == "https://127.0.0.1:3001/":
                    output = "desktop"
                else:
                    requested.append(url)
                    if not url.startswith("https://127.0.0.1:3001" + route):
                        raise RuntimeError("curl: (22) The requested URL returned error: 404")
                    output = content if url.endswith("rf-smoke.txt") else listing
            elif args[0] == "exec" and "nginx" in args:
                output = "server { location " + ("/api" if route == "/api/files/" else "/files") + " { } }"
            return subprocess.CompletedProcess(args, 0, output, "")

        with patch.object(smoke, "docker", side_effect=docker):
            smoke.main("test-image", "linuxserver")
        return requested

    def test_selkies_v2_lists_and_downloads_through_api(self):
        self.assertEqual(self.run_smoke("/api/files/"), [
            "https://127.0.0.1:3001/api/files/",
            "https://127.0.0.1:3001/api/files/rf-smoke.txt",
        ] * 2)

    def test_older_base_images_keep_the_legacy_file_route(self):
        self.assertEqual(self.run_smoke("/files/"), [
            "https://127.0.0.1:3001/files/",
            "https://127.0.0.1:3001/files/rf-smoke.txt",
        ] * 2)

    def test_missing_file_still_fails(self):
        with self.assertRaisesRegex(AssertionError, "did not list"):
            self.run_smoke("/api/files/", listing="empty directory")

    def test_wrong_download_still_fails(self):
        with self.assertRaisesRegex(AssertionError, "content"):
            self.run_smoke("/api/files/", content="wrong file")


if __name__ == "__main__":
    unittest.main()
