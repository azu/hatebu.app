#!/usr/bin/env python3
"""Exercise release publication against temporary local Git repositories."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hatebu-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = self.root / "origin.git"
        self.work = self.root / "work"
        self.work.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_SYSTEM=os.devnull, GIT_TERMINAL_PROMPT="0",
                        GIT_AUTHOR_NAME="Release Test", GIT_COMMITTER_NAME="Release Test",
                        GIT_AUTHOR_EMAIL="release@example.invalid",
                        GIT_COMMITTER_EMAIL="release@example.invalid")
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        (self.work / "scripts").mkdir()
        for name in ["release.sh", "package.py"]:
            shutil.copy2(Path(__file__).parent / name, self.work / "scripts" / name)
        (self.work / "VERSION").write_text("0.1.1\n")
        self.git("add", ".")
        self.git("commit", "-m", "initial")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "main")
        self.initial = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args, remote=False):
        return subprocess.run(["git", *args], cwd=self.remote if remote else self.work,
                              env=self.env, text=True, capture_output=True, check=True)

    def release(self, kind):
        return subprocess.run(["bash", "scripts/release.sh", kind], cwd=self.work,
                              env=self.env, text=True, capture_output=True)

    def assertUnpublished(self):
        self.assertEqual(self.git("rev-parse", "refs/heads/main", remote=True).stdout.strip(), self.initial)
        self.assertEqual(self.git("tag", "--list", remote=True).stdout.strip(), "")

    def testVersionBumpsPublishMatchingCommitAndTag(self):
        for kind, expected in [("patch", "0.1.2"), ("minor", "0.2.0"), ("major", "1.0.0")]:
            with self.subTest(kind=kind):
                result = self.release(kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.git("show", "main:VERSION", remote=True).stdout.strip(), expected)
                head = self.git("rev-parse", "HEAD").stdout.strip()
                self.assertEqual(self.git("rev-parse", f"refs/tags/v{expected}", remote=True).stdout.strip(), head)
                self.assertEqual(self.git("status", "--porcelain").stdout, "")
                self.assertEqual(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").stdout.strip(), "VERSION")

    def testDirtyTreeDoesNotChangeVersionOrPublish(self):
        (self.work / "note.txt").write_text("work in progress\n")
        self.assertNotEqual(self.release("patch").returncode, 0)
        self.assertEqual((self.work / "VERSION").read_text(), "0.1.1\n")
        self.assertUnpublished()

    def testUnpushedCommitDoesNotPublish(self):
        self.git("commit", "--allow-empty", "-m", "local change")
        self.assertNotEqual(self.release("patch").returncode, 0)
        self.assertEqual((self.work / "VERSION").read_text(), "0.1.1\n")
        self.assertUnpublished()

    def testExistingRemoteTagIsNotOverwritten(self):
        self.git("tag", "v0.1.2", "main", remote=True)
        self.assertNotEqual(self.release("patch").returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial)
        self.assertEqual(self.git("rev-parse", "refs/tags/v0.1.2", remote=True).stdout.strip(), self.initial)

    def testRejectedTagCannotPartiallyPushMain(self):
        hook = self.remote / "hooks/update"
        hook.write_text('#!/bin/sh\ncase "$1" in refs/tags/*) exit 1;; esac\n')
        hook.chmod(0o755)
        self.assertNotEqual(self.release("patch").returncode, 0)
        self.assertUnpublished()
        self.assertEqual((self.work / "VERSION").read_text(), "0.1.2\n")
        self.assertEqual(self.git("tag", "--list").stdout.strip(), "v0.1.2")

    def testInvalidArgumentOrBranchCannotPublish(self):
        self.assertEqual(self.release("invalid").returncode, 2)
        self.git("switch", "-c", "feature")
        self.assertNotEqual(self.release("patch").returncode, 0)
        self.assertUnpublished()


if __name__ == "__main__":
    unittest.main()
