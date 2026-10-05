import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class SetupEntryPointTest(unittest.TestCase):
    def run_script(self, argument):
        with tempfile.TemporaryDirectory() as directory:
            docker = pathlib.Path(directory) / "docker"
            docker.write_text("#!/bin/sh\necho DOCKER_WAS_CALLED >&2\nexit 99\n")
            docker.chmod(0o755)
            environment = dict(os.environ, PATH=directory + ":" + os.environ["PATH"])
            return subprocess.run(
                ["bash", str(ROOT / "setup.sh"), argument],
                env=environment, capture_output=True, text=True, timeout=10,
            )

    def test_help_does_not_start_or_check_docker(self):
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)
        self.assertNotIn("DOCKER_WAS_CALLED", result.stderr)

    def test_unknown_option_fails_before_touching_docker(self):
        result = self.run_script("--wrong-option")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown option", result.stderr)
        self.assertNotIn("DOCKER_WAS_CALLED", result.stderr)


if __name__ == "__main__":
    unittest.main()
