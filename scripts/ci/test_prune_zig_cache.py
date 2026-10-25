import os
import tempfile
import unittest
from pathlib import Path

from prune_zig_cache import prune


class PruneCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.caches = [self.root / ".zig-cache", self.root / "zig-cache"]

    def file(self, relative, length, time=1):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * length)
        os.utime(path, (time, time))
        os.utime(path.parent, (time, time))
        return path

    def test_warm_cache_below_limit_is_preserved(self):
        file = self.file(".zig-cache/o/warm/test", 40)
        self.assertEqual(prune(self.caches, 100), (40, 40, 0))
        self.assertEqual(file.read_bytes(), b"x" * 40)

    def test_old_output_evicted_but_new_output_and_packages_retained(self):
        old = self.file(".zig-cache/o/old/test", 70, 1)
        new = self.file("zig-cache/o/new/test", 60, 2)
        package = self.file("zig-cache/p/protoc.tar.gz", 30)
        self.assertEqual(prune(self.caches, 100), (160, 90, 1))
        self.assertFalse(old.parent.exists())
        self.assertTrue(new.exists())
        self.assertTrue(package.exists())

    def test_output_eviction_invalidates_both_caches_manifests(self):
        old = self.file(".zig-cache/o/old/libanswer.a", 70, 1)
        new = self.file("zig-cache/o/new/test", 60, 2)
        package = self.file("zig-cache/p/protoc.tar.gz", 30)
        local_manifest = self.file(".zig-cache/h/local", 10)
        global_manifest = self.file("zig-cache/h/global", 10)
        self.assertEqual(prune(self.caches, 100), (180, 90, 3))
        self.assertFalse(old.exists())
        self.assertFalse(local_manifest.exists())
        self.assertFalse(global_manifest.exists())
        self.assertTrue(new.exists())
        self.assertTrue(package.exists())

    def test_warm_manifests_are_retained_without_output_eviction(self):
        self.file(".zig-cache/o/keep/test", 40)
        manifest = self.file(".zig-cache/h/keep", 10)
        self.assertEqual(prune(self.caches, 100), (50, 50, 0))
        self.assertTrue(manifest.exists())

    def test_manifest_symlink_is_removed_without_following_it(self):
        self.file(".zig-cache/o/old/libanswer.a", 70, 1)
        outside = self.file("outside/manifest", 10)
        manifests = self.caches[0] / "h"
        manifests.symlink_to(outside.parent, target_is_directory=True)
        self.assertEqual(prune(self.caches, 0)[1], 0)
        self.assertFalse(manifests.is_symlink())
        self.assertTrue(outside.exists())

    def test_scratch_databases_are_not_archived(self):
        scratch = self.file(".zig-cache/tmp/database", 1000)
        output = self.file(".zig-cache/o/keep/test", 20)
        self.assertEqual(prune(self.caches, 100), (20, 20, 0))
        self.assertFalse(scratch.exists())
        self.assertTrue(output.exists())

    def test_package_only_oversize_and_zero_limit(self):
        self.file("zig-cache/p/large.tar.gz", 120)
        self.assertEqual(prune(self.caches, 100), (120, 0, 1))
        self.file(".zig-cache/h/manifest", 10)
        self.assertEqual(prune(self.caches, 0), (10, 0, 1))

    def test_symlink_output_never_removes_external_data(self):
        outside = self.file("outside/keep", 40)
        objects = self.caches[0] / "o"
        objects.mkdir(parents=True)
        (objects / "external").symlink_to(outside.parent, target_is_directory=True)
        self.assertEqual(prune(self.caches, 0)[1], 0)
        self.assertEqual(outside.read_bytes(), b"x" * 40)

    def test_symlink_root_is_rejected_before_cleanup(self):
        outside = self.file("outside/tmp/keep", 40)
        self.caches[0].symlink_to(outside.parent.parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            prune(self.caches, 0)
        self.assertTrue(outside.exists())

    def test_missing_cache_and_invalid_limit(self):
        self.assertEqual(prune(self.caches, 100), (0, 0, 0))
        with self.assertRaises(ValueError):
            prune(self.caches, -1)

    def test_installed_binary_survives_removing_its_cached_hard_link(self):
        output = self.file(".zig-cache/o/build/geode", 50)
        installed = self.root / "zig-out/bin/geode"
        installed.parent.mkdir(parents=True)
        os.link(output, installed)
        self.assertEqual(prune(self.caches, 0), (50, 0, 1))
        self.assertFalse(output.exists())
        self.assertEqual(installed.read_bytes(), b"x" * 50)


if __name__ == "__main__":
    unittest.main()
