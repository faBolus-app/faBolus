#!/usr/bin/env python3
"""Fail if the app could build TandemKit with a package trait on.

TandemKit's `BenchWrites` trait adds UserInteraction and ChangeTimeDate to the signed writes its link
sends. Only TandemKit's own bench package may turn it on; an app build must have neither write. This
checks every faBolus package three ways:

- its manifest names no trait on its TandemKit dependency, conditional ones included (a root trait,
  such as `--enable-all-traits` turns on, could otherwise switch it on);
- SwiftPM's resolved graph, which reports the traits actually enabled on each package, has none on
  TandemKit, wherever in the graph it is reached and whatever asked for it;
- the resolved TandemKit declares no default trait, which an app picks up without naming it.

It also refuses a traits key in project.yml, the generated Xcode project and any Package.resolved, so
a trait can't arrive by a route the SwiftPM checks don't see. The project and the resolved files are
gitignored, so each is checked where it exists: CI's run has the packages' resolved files, which the
graph check writes, and project.yml, the generated project's only source.

Before checking the tree it runs the same checks on small packages that enable the trait each way, and
fails if any of them passes, so a check that stopped biting can't go unnoticed.
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT = "tandemkit"
# "traits" in any case, or a camel-case key ending in "Traits" (enabledTraits). Not the "trait" in
# "Portrait".
TRAITS_KEY = re.compile(r"(?i:\btraits\b)|[a-z]Traits\b")


def is_kit(*names):
    """TandemKit, or a checkout of it. SwiftPM names a package after its URL's or folder's last component,
    so a checkout in TandemKit-bench/ is "tandemkit-bench": any identity, declared name or location whose
    last component has "tandemkit" in it counts, which errs towards checking too much. Only the last
    component, so a faBolus clone inside a folder named for TandemKit doesn't make every package match."""
    for name in names:
        last = (name or "").rstrip("/").rsplit("/", 1)[-1].lower().removesuffix(".git")
        if KIT in last:
            return True
    return False


def swiftpm(package, *args):
    out = subprocess.run(["swift", "package", "--package-path", package, *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"traits: swift package {' '.join(args)} failed in {package}:\n{out.stderr}")
    return json.loads(out.stdout)


def manifest_problems(package):
    """The traits the manifest asks for on TandemKit: only the default set, unconditioned, passes. And no
    traits of the package's own: with none, no conditional trait anywhere in the graph can be switched on
    (by `--enable-all-traits` or a trait picked in Xcode), the graph check below sees every trait that
    can be on, and a package outside faBolus can't be the route."""
    problems = []
    manifest = swiftpm(package, "dump-package")
    own = [t["name"] for t in manifest.get("traits") or []]
    if own:
        problems.append(f"{package}/Package.swift: declares traits of its own {own}")
    for dep in manifest["dependencies"]:
        for entry in [e for entries in dep.values() for e in entries]:
            location = entry.get("location", {})
            urls = [u.get("urlString") for u in location.get("remote", [])] + location.get("local", [])
            if not is_kit(entry.get("identity"), entry.get("nameForTargetDependencyResolutionOnly"),
                          entry.get("path"), *urls):
                continue
            for trait in entry.get("traits") or []:
                if trait.get("name") != "default" or "condition" in trait:
                    problems.append(f"{package}/Package.swift: its TandemKit dependency names trait {trait}")
    return problems


def graph_problems(package, kit_paths):
    """The traits SwiftPM enables on TandemKit in the package's resolved graph. "default" alone means
    TandemKit's default set, which the checkout check below requires to be empty."""
    problems = []
    found = False

    def walk(node, via):
        nonlocal found
        here = via + [node.get("name", node["identity"])]
        if is_kit(node["identity"], node.get("name"), node.get("url")):
            found = True
            kit_paths.add(node["path"])
            enabled = sorted(set(node.get("traits") or []) - {"default"})
            if enabled:
                problems.append(f"{package}: TandemKit is resolved with traits {enabled} ({' -> '.join(here)})")
        for child in node.get("dependencies") or []:
            walk(child, here)

    walk(swiftpm(package, "show-dependencies", "--format", "json"), [])
    return problems, found


def default_trait_problems(kit_path):
    problems = []
    for trait in swiftpm(kit_path, "dump-package").get("traits") or []:
        if trait.get("name") == "default" and trait.get("enabledTraits"):
            problems.append(
                f"{kit_path}/Package.swift: TandemKit's default traits are {trait['enabledTraits']}, "
                "which every app that depends on it picks up")
    return problems


def text_problems(path, text, comment="#"):
    problems = []
    for number, line in enumerate(text.splitlines(), 1):
        # A comment starts a line or follows whitespace; a "#" inside a URL doesn't start one.
        code = re.sub(r"(^|\s)" + re.escape(comment) + ".*", "", line) if comment else line
        if TRAITS_KEY.search(code):
            problems.append(f"{path}:{number}: a traits key: {line.strip()}")
    return problems


def resolved_problems(path, data):
    """Package.resolved records no traits today; a format that starts to would be checked here."""
    problems = []

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if TRAITS_KEY.search(key):
                    problems.append(f"{path}: a traits key {key!r}: {json.dumps(child)}")
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(data)
    return problems


def check_packages(packages):
    """Returns (problems, whether any package's graph reached TandemKit)."""
    problems, kit_paths, found_any = [], set(), False
    for package in packages:
        problems += manifest_problems(package)
        graph, found = graph_problems(package, kit_paths)
        problems += graph
        found_any = found_any or found
    manifests = set()  # PumpSession, PhoneApp and WatchLink each check out the same release
    for kit_path in sorted(kit_paths):
        with open(os.path.join(kit_path, "Package.swift"), "rb") as f:
            manifest = f.read()
        if manifest not in manifests:
            manifests.add(manifest)
            problems += default_trait_problems(kit_path)
    return problems, found_any


# The self-test's packages: a stand-in TandemKit with the trait, optionally on by default, and apps that
# depend on it. Each failing case names the check that must catch it, so a case caught by another check
# doesn't hide one that stopped biting.
FAKE_KIT = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "TandemKit", products: [.library(name: "TandemMessages", targets: ["TandemMessages"])],
    traits: [.trait(name: "BenchWrites"){default}],
    targets: [.target(name: "TandemMessages")])
"""
APP = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "{name}",
    products: [.library(name: "{name}", targets: ["{name}"])],{traits}
    dependencies: [.package({alias}path: "../{folder}"{dep_traits})],
    targets: [.target(name: "{name}", dependencies: [.product(name: "{product}", package: "{package}")])])
"""
NAMES = "names trait"  # manifest_problems
OWN = "traits of its own"  # manifest_problems
RESOLVED = "is resolved with traits"  # graph_problems
DEFAULT = "default traits are"  # default_trait_problems


def write_package(root, folder, manifest, target):
    os.makedirs(os.path.join(root, folder, "Sources", target))
    with open(os.path.join(root, folder, "Package.swift"), "w", encoding="utf-8") as f:
        f.write(manifest)
    with open(os.path.join(root, folder, "Sources", target, f"{target}.swift"), "w", encoding="utf-8") as f:
        f.write("public let marker = 0\n")


def app(name, dep="TandemKit", folder=None, dep_traits="", traits=""):
    folder = folder or dep
    product = "TandemMessages" if dep == "TandemKit" else dep
    alias = f'name: "{dep}", ' if folder != dep else ""
    return APP.format(name=name, folder=folder, alias=alias, package=dep, product=product,
                      dep_traits=dep_traits, traits=traits)


def self_test():
    names_it = ', traits: ["BenchWrites"]'
    cases = [
        # (case, TandemKit's folder, the trait on by default, the apps, what must be reported; none: a pass)
        ("names no trait", "TandemKit", False, [app("App")], []),
        ("names the trait", "TandemKit", False, [app("App", dep_traits=names_it)], [NAMES, RESOLVED]),
        ("names the trait on a checkout in another folder", "TandemKit-bench", False,
         [app("App", folder="TandemKit-bench", dep_traits=names_it)], [NAMES, RESOLVED]),
        ("names the trait under a trait of its own", "TandemKit", False,
         [app("App", traits='\n    traits: [.trait(name: "Bench")],',
              dep_traits=', traits: [.trait(name: "BenchWrites", condition: .when(traits: ["Bench"]))]')],
         [NAMES, OWN]),
        ("a dependency names the trait under a trait of the app's", "TandemKit", False,
         [app("Middle", traits='\n    traits: [.trait(name: "Via")],',
              dep_traits=', traits: [.trait(name: "BenchWrites", condition: .when(traits: ["Via"]))]'),
          app("App", dep="Middle", traits='\n    traits: [.trait(name: "Bench")],',
              dep_traits=', traits: [.trait(name: "Via", condition: .when(traits: ["Bench"]))]')],
         [OWN]),
        ("a dependency of the app names the trait", "TandemKit", False,
         [app("Middle", dep_traits=names_it), app("App", dep="Middle")], [RESOLVED]),
        ("TandemKit turns it on by default", "TandemKit", True, [app("App")], [RESOLVED, DEFAULT]),
        ("TandemKit turns it on by default, the app turns defaults off", "TandemKit", True,
         [app("App", dep_traits=", traits: []")], [DEFAULT]),
    ]
    failures = []
    with tempfile.TemporaryDirectory() as scratch:
        for index, (case, kit_folder, on_by_default, apps, expected) in enumerate(cases):
            root = os.path.join(scratch, str(index))
            default = ', .default(enabledTraits: ["BenchWrites"])' if on_by_default else ""
            write_package(root, kit_folder, FAKE_KIT.replace("{default}", default), "TandemMessages")
            for manifest in apps:
                name = re.search(r'name: "(\w+)"', manifest).group(1)
                write_package(root, name, manifest, name)
            checked = re.search(r'name: "(\w+)"', apps[-1]).group(1)
            problems, found = check_packages([os.path.join(root, checked)])
            if not found:
                failures.append(f"self-test '{case}': the graph check never reached the stand-in TandemKit")
            missing = [e for e in expected if not any(e in p for p in problems)]
            if missing or (not expected and problems):
                failures.append(f"self-test '{case}': expected {expected or 'a pass'}, got {problems or 'a pass'}")
    text_cases = [
        (text_problems("project.yml", "packages:\n  TandemKit:\n    traits: [BenchWrites]\n"), False),
        (text_problems("project.pbxproj", "\t\t\tenabledTraits = (\n\t\t\t\tBenchWrites,\n"), False),
        (text_problems("project.pbxproj", "\t\t\tTraits = (BenchWrites);\n"), False),
        (text_problems("project.yml", '    TandemKit: {url: "https://host/TandemKit.git#x", traits: [B]}\n'), False),
        (text_problems("project.yml", "    UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]\n"
                                      "    # no traits here, a comment\n"), True),
        (resolved_problems("Package.resolved", {"pins": [{"identity": KIT, "traits": ["BenchWrites"]}]}), False),
        (resolved_problems("Package.resolved", {"pins": [{"identity": KIT, "state": {"version": "0.4.0"}}]}), True),
    ]
    for index, (problems, should_pass) in enumerate(text_cases):
        if bool(problems) == should_pass:
            failures.append(f"self-test text case {index}: expected {'a pass' if should_pass else 'a failure'}, "
                            f"got {problems or 'a pass'}")
    return failures


def main():
    failures = self_test()
    if failures:
        print("\n".join(failures), file=sys.stderr)
        print("traits: the check itself is broken; nothing was checked", file=sys.stderr)
        return 1

    packages = sorted(os.path.dirname(p) for p in glob.glob(os.path.join(ROOT, "Packages", "*", "Package.swift")))
    problems, found = check_packages(packages)
    if not found:
        problems.append("no faBolus package's graph reaches TandemKit, so nothing was checked")

    with open(os.path.join(ROOT, "project.yml"), encoding="utf-8") as f:
        problems += text_problems("project.yml", f.read())
    pbxproj = os.path.join(ROOT, "faBolus.xcodeproj", "project.pbxproj")
    if os.path.exists(pbxproj):
        with open(pbxproj, encoding="utf-8") as f:
            # pbxproj comments are /* ... */ on the same line; a traits key would sit outside them.
            problems += text_problems("faBolus.xcodeproj/project.pbxproj", re.sub(r"/\*.*?\*/", "", f.read()), None)
    resolved = glob.glob(os.path.join(ROOT, "Packages", "*", "Package.resolved"))
    resolved += glob.glob(os.path.join(ROOT, "faBolus.xcodeproj", "**", "Package.resolved"), recursive=True)
    for path in sorted(resolved):
        with open(path, encoding="utf-8") as f:
            problems += resolved_problems(os.path.relpath(path, ROOT), json.load(f))

    if problems:
        print("\n".join(problems), file=sys.stderr)
        print("traits: an app build must enable no TandemKit trait (BenchWrites is for TandemKit's bench only)",
              file=sys.stderr)
        return 1
    print(f"traits: no TandemKit trait in {len(packages)} packages, project.yml or {len(resolved)} Package.resolved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
