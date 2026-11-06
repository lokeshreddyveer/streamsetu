#!/usr/bin/env python3
"""Tests of the Android part of Scripts/audit-dependencies.py. No network and no Gradle: a saved listing of the dependency tree and a stand-in for the OSV database.

  python3 Scripts/test_audit_dependencies.py
"""
import json, os, pathlib, re, subprocess, sys, tempfile, unittest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "audit-dependencies.py"

TREE = """
------------------------------------------------------------
Project ':app'
------------------------------------------------------------

releaseRuntimeClasspath - Runtime classpath of '/release'.
+--- org.jetbrains.kotlin:kotlin-stdlib:2.0.21
|    +--- org.jetbrains:annotations:13.0 -> 23.0.0
|    +--- org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.8.0 -> 1.9.0 (c)
|    \\--- org.jetbrains.kotlin:kotlin-stdlib-common:2.0.21 (c)
+--- project :data
|    +--- project :core-model
|    |    +--- org.jetbrains.kotlin:kotlin-stdlib:2.0.21 (*)
|    |    \\--- org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0
\\--- com.squareup.okhttp3:okhttp:4.12.0
     +--- com.squareup.okio:okio:3.6.0
     \\--- org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.8.21 -> 2.0.21 (*)
"""
EXPECTED = ["com.squareup.okhttp3:okhttp:4.12.0", "com.squareup.okio:okio:3.6.0", "org.jetbrains:annotations:23.0.0", "org.jetbrains.kotlin:kotlin-stdlib-jdk8:2.0.21",
            "org.jetbrains.kotlin:kotlin-stdlib:2.0.21", "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0"]
EXPECTED.sort()          # the order the script writes


def load_parser():
    src = SCRIPT.read_text()
    ns = {"re": re}
    exec(src[src.index("def parse_gradle_tree"):src.index("def gradle_dependencies")], ns)
    return ns["parse_gradle_tree"]


class Run:
    """One run of the script in a temporary folder, with its own lock file, saved tree and OSV answer."""
    def __init__(self, test, tree=TREE, osv=None, lock="same", extra=()):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        test.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        (self.tmp / "tree.txt").write_text(tree)
        (self.tmp / "osv.json").write_text(json.dumps(osv if osv is not None else {"vulns": {}}))
        parse = load_parser()
        if lock == "same": (self.tmp / "lock.txt").write_text("\n".join(parse(tree)) + "\n")
        elif lock is not None: (self.tmp / "lock.txt").write_text(lock)
        env = dict(os.environ, AUDIT_OSV_FIXTURE=str(self.tmp / "osv.json"))
        cmd = [sys.executable, str(SCRIPT), "--scope", "android", "--strict", "--gradle-deps-file", str(self.tmp / "tree.txt"), "--lock-file", str(self.tmp / "lock.txt"),
               "--report", str(self.tmp / "report.json"), "--android-sbom", str(self.tmp / "sbom.json"), *extra]
        r = subprocess.run(cmd, capture_output=True, text=True, env=env)
        self.code, self.out = r.returncode, r.stdout + r.stderr


class AndroidDependencyAudit(unittest.TestCase):
    def test_the_tree_is_read_as_the_libraries_gradle_resolved(self):
        self.assertEqual(load_parser()(TREE), EXPECTED)

    def test_a_clean_lookup_passes(self):
        r = Run(self)
        self.assertEqual(r.code, 0, r.out)
        self.assertIn("6 of 6 libraries checked and clean", r.out)

    def test_a_reported_vulnerability_fails_with_exit_1_and_names_the_library(self):
        r = Run(self, osv={"vulns": {"com.squareup.okhttp3:okhttp:4.12.0": ["GHSA-test-1234"]}})
        self.assertEqual(r.code, 1, r.out)
        self.assertIn("okhttp:4.12.0: GHSA-test-1234", r.out)

    def test_an_unreachable_database_fails_with_exit_2_never_passes(self):
        r = Run(self, osv={"unreachable": True})
        self.assertEqual(r.code, 2, r.out)
        self.assertIn("could not look the libraries up", r.out)

    def test_an_empty_listing_is_not_a_pass(self):
        r = Run(self, tree="------\nProject ':app'\n------\n\nreleaseRuntimeClasspath - nothing\n", lock="")
        self.assertEqual(r.code, 2, r.out)
        self.assertIn("a check of nothing proves nothing", r.out)

    def test_a_missing_lock_fails_with_exit_2(self):
        r = Run(self, lock=None)
        self.assertEqual(r.code, 2, r.out)
        self.assertIn("reviewed list of libraries is missing", r.out)

    def test_a_changed_dependency_set_fails_until_the_lock_is_reviewed_and_updated(self):
        old = "\n".join(l for l in EXPECTED if "okio" not in l) + "\n"
        r = Run(self, lock=old)
        self.assertEqual(r.code, 2, r.out)
        self.assertIn("new or changed: com.squareup.okio:okio:3.6.0", r.out)
        updated = Run(self, lock=old, extra=("--update-lock",))
        self.assertEqual(updated.code, 0, updated.out)
        self.assertEqual((updated.tmp / "lock.txt").read_text().split(), EXPECTED)

    def test_the_sbom_lists_every_library_with_its_package_url(self):
        r = Run(self)
        sbom = json.loads((r.tmp / "sbom.json").read_text())
        self.assertEqual(sbom["bomFormat"], "CycloneDX")
        self.assertIn("pkg:maven/com.squareup.okhttp3/okhttp@4.12.0", [c["purl"] for c in sbom["components"]])
        self.assertEqual(len(sbom["components"]), len(EXPECTED))

    def test_the_android_scope_does_not_depend_on_the_website_or_the_swift_packages(self):
        r = Run(self)
        self.assertNotIn("known vulnerabilities (critical", r.out, "the website's npm audit is not part of an Android release")


if __name__ == "__main__":
    unittest.main(verbosity=2)
