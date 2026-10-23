"""Build matched original C++ extensions with and without step observations."""
import concurrent.futures
import difflib
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

source = Path('/Users/me/p/metta/packages/mettagrid/cpp')
root = Path('out/cpp-comparison').resolve()
copied = root / 'cpp'
shutil.copytree(source, copied, dirs_exist_ok=True)
binding = copied / 'bindings/mettagrid_c.cpp'
original = binding.read_text()
prefix, step = original.split('void MettaGrid::_step() {', 1)
modified = prefix + 'void MettaGrid::_step() {' + step.replace(
    '  auto obs_ptr = static_cast<ObservationType*>(_observations.request().ptr);\n'
    '  auto obs_size = _observations.size();\n'
    '  std::fill(obs_ptr, obs_ptr + obs_size, EmptyTokenByte);',
    '#ifndef CVC_BENCH_NO_OBSERVATIONS\n'
    '  auto obs_ptr = static_cast<ObservationType*>(_observations.request().ptr);\n'
    '  auto obs_size = _observations.size();\n'
    '  std::fill(obs_ptr, obs_ptr + obs_size, EmptyTokenByte);\n'
    '#endif',
).replace(
    '  _compute_observations(executed_actions);',
    '#ifndef CVC_BENCH_NO_OBSERVATIONS\n'
    '  _compute_observations(executed_actions);\n'
    '#endif',
)
assert modified.count('#ifndef CVC_BENCH_NO_OBSERVATIONS') == 2
binding.write_text(modified)
(root / 'no-observations.patch').write_text(''.join(difflib.unified_diff(
    original.splitlines(True), modified.splitlines(True),
    fromfile='bindings/mettagrid_c.cpp', tofile='bindings/mettagrid_c.cpp',
)))
includes = shlex.split(subprocess.check_output(
    [sys.executable, '-m', 'pybind11', '--includes'], text=True))
flags = ['clang++', '-std=c++20', '-O3', '-DNDEBUG', '-fPIC',
         '-fvisibility=hidden', '-DNPY_NO_DEPRECATED_API=NPY_1_7_API_VERSION',
         *includes, '-I' + str(copied), '-I' + str(copied / 'bindings'),
         '-I' + str(copied / 'include/mettagrid')]
sources = sorted((copied / 'src').rglob('*.cpp')) + [
    copied / 'bindings/mettagrid_py.cpp', copied / 'bindings/profiling_py.cpp']


def compile_source(path):
    """Compile a shared translation unit once for both variants."""
    output = root / (str(path.relative_to(copied)).replace('/', '_') + '.o')
    subprocess.run([*flags, '-c', str(path), '-o', str(output)], check=True)
    print('Compiled', path.name, flush=True)
    return output


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    objects = list(pool.map(compile_source, sources))
for variant in ['with-obs', 'without-obs']:
    directory = root / variant
    directory.mkdir(exist_ok=True)
    output = directory / 'mettagrid_c.o'
    defines = ['-DCVC_BENCH_NO_OBSERVATIONS'] if variant == 'without-obs' else []
    subprocess.run([*flags, *defines, '-c', str(binding), '-o', str(output)], check=True)
    subprocess.run(['clang++', '-shared', '-undefined', 'dynamic_lookup',
                    str(output), *map(str, objects), '-o',
                    str(directory / 'mettagrid_c.so')], check=True)
    print('Built', variant, flush=True)
