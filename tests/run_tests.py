"""Run the public synthetic suites against a built or extracted filter."""
from pathlib import Path
import argparse
import os
import shutil
import unittest

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--filter', type=Path, default=Path(os.environ.get(
        'PAS2DOX_TEST_EXE', str(ROOT / 'build/pas2dox.exe'))))
    args = parser.parse_args()
    executable = args.filter.resolve()
    if not executable.is_file():
        parser.error('Build with build.cmd or extract the Windows release first; alternatively use --filter PATH.')
    for command in ['doxygen', 'dot']:
        if not shutil.which(command):
            parser.error(command + ' must be available on PATH.')
    (ROOT / 'build').mkdir(exist_ok=True)
    import test_modern
    import test_filter_graphs
    import test_delphi_todo
    modules = [test_modern, test_filter_graphs, test_delphi_todo]
    for module in modules:
        module.EXE = executable
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromModule(m) for m in modules)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    raise SystemExit(0 if result.wasSuccessful() and not result.skipped else 1)


if __name__ == '__main__':
    main()
