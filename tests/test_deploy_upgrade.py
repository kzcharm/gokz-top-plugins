"""Linux deployment regression: replacing a loaded shared library must preserve its mapping."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/deploy-upgrade.sh"


@unittest.skipUnless(sys.platform == "linux", "requires Linux shared-library semantics")
class DeployUpgradeTest(unittest.TestCase):
    def test_loaded_extension_survives_upgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            game = root / "game"
            relative = Path("addons/sourcemod/extensions/gokz_top_replay_fs.ext.so")
            source = package / relative
            installed = game / relative
            source.parent.mkdir(parents=True)
            installed.parent.mkdir(parents=True)
            (package / "materials").mkdir()
            (game / "cfg").mkdir()
            config = game / "cfg/server.cfg"
            config.write_text("existing configuration")
            unrelated = installed.parent / "unrelated.ext.so"
            unrelated.write_bytes(b"keep")
            c_file = root / "fixture.c"
            for value, target in [(1, installed), (2, source)]:
                c_file.write_text(
                    '#include <stdio.h>\n'
                    f'int value(void) {{ puts("loaded extension"); return {value}; }}\n'
                )
                subprocess.run(
                    ["gcc", "-shared", "-fPIC", str(c_file), "-o", str(target)],
                    check=True,
                )
            # Exercise same-size/same-timestamp binaries too: checksum comparison must detect them.
            shutil.copystat(installed, source)
            child = """
import ctypes, resource, sys
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
library = ctypes.CDLL(sys.argv[1])
assert library.value() == 1
print('READY', flush=True)
input()
assert library.value() == 1
"""
            with subprocess.Popen(
                [sys.executable, "-u", "-c", child, str(installed)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True,
            ) as consumer:
                try:
                    self.assertEqual(consumer.stdout.readline().strip(), "loaded extension")
                    self.assertEqual(consumer.stdout.readline().strip(), "READY")
                    inode = installed.stat().st_ino
                    subprocess.run(["bash", str(SCRIPT), str(package), str(game)], check=True)
                    output, error = consumer.communicate("\n", timeout=5)
                    self.assertEqual(consumer.returncode, 0, output + error)
                    self.assertNotEqual(installed.stat().st_ino, inode)
                finally:
                    if consumer.poll() is None:
                        consumer.kill()
                        consumer.communicate()
            subprocess.run(
                [sys.executable, "-c", "import ctypes,sys; assert ctypes.CDLL(sys.argv[1]).value() == 2", str(installed)],
                check=True,
            )
            self.assertEqual(config.read_text(), "existing configuration")
            self.assertEqual(unrelated.read_bytes(), b"keep")
            self.assertEqual(installed.read_bytes(), source.read_bytes())

    def test_missing_extension_leaves_destination_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "game"
            package = root / "package"
            game.mkdir()
            (package / "addons").mkdir(parents=True)
            (package / "materials").mkdir()
            result = subprocess.run(["bash", str(SCRIPT), str(package), str(game)])
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(game.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
