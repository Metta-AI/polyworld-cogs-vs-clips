"""Benchmark original FourScore C++ steps using the Nim port's action stream.

Run with cogsguard and mettagrid on PYTHONPATH, from the port repository root.
"""
import json
import hashlib
import importlib.util
import os
import sys
import time
from pathlib import Path

import numpy as np

# Load either isolated build before importing the package's Python modules.
variant = sys.argv[1] if len(sys.argv) > 1 else 'installed'
if variant != 'installed':
    extension = Path('out/cpp-comparison') / variant / 'mettagrid_c.so'
    spec = importlib.util.spec_from_file_location('mettagrid.mettagrid_c', extension)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
os.environ.pop('METTAGRID_PROFILING', None)
from cogsguard.missions.four_score import FourScoreMission
from mettagrid.config.mettagrid_c_config import (
    convert_to_cpp_game_config,
    rename_map_agents,
)
from mettagrid.mapgen.mapgen import MapGen
from mettagrid.mettagrid_c import MettaGrid

config = FourScoreMission().make_env()
config.game.map_builder.seed = 1
names = [action.name for action in config.game.actions.actions()]
translation = np.array([names.index(name) for name in [
    'noop', 'move_north', 'move_east', 'move_south', 'move_west'
]], dtype=np.int32)
actions = translation[np.loadtxt('out/engine-actions.csv', delimiter=',', dtype=np.int32)]
raw_grid = MapGen(config.game.map_builder).build().grid
# Match the port's playable map, excluding only the five-cell outer border.
grid = raw_grid[5:-5, 5:-5].tolist()
assert len(grid) == 120 and all(len(row) == 120 for row in grid)
assert json.loads(Path('out/four-score-map.json').read_text()) == raw_grid.tolist()
cpp_config, renames = convert_to_cpp_game_config(config.game)
if renames:
    grid = rename_map_agents(grid, renames)


def create():
    """Create an independent engine outside the timed region."""
    return MettaGrid(cpp_config, grid, 1)


warmup = create()
for tick in range(1000):
    warmup.actions()[:] = actions[tick]
    warmup.step()
del warmup
rows = []
validation = os.environ.get('CVC_BENCH_VALIDATE') == '1'
for round_index in range(1 if validation else 3):
    for workload in ['simulation', 'idle']:
        engine = create()
        buffer = engine.actions()
        steps = actions if workload == 'simulation' else np.full_like(actions, translation[0])
        started = time.perf_counter()
        for frame in steps:
            buffer[:] = frame
            engine.step()
        elapsed = time.perf_counter() - started
        assert engine.current_step == 10000
        objects = {key: {name: value for name, value in obj.items()
                         if not callable(value)}
                   for key, obj in engine.grid_objects().items()}
        state = json.dumps(objects, sort_keys=True)
        if validation:
            Path(f'out/cpp-state-{variant}-{workload}.json').write_text(state)
        rows.append(dict(workload=workload, round=round_index, seconds=elapsed,
                         objects_hash=hashlib.sha256(state.encode()).hexdigest(),
                         held_stats={team: engine.get_game_stat(
                             f'cogs_{team}/aligned.junction.held')
                             for team in ['red', 'blue', 'green', 'yellow']}))
        print(workload, round_index, elapsed, flush=True)
        del engine
if validation:
    sys.exit(0)
# Separate phase timing pass; Python property reads do not inflate C++ timers.
os.environ["METTAGRID_PROFILING"] = "1"
engine = create()
buffer = engine.actions()
phases = {name + '_ns': 0.0 for name in [
    'reset', 'events', 'actions', 'on_tick', 'aoe', 'observations',
    'rewards', 'truncation', 'total'
]}
for frame in actions:
    buffer[:] = frame
    engine.step()
    timing = engine.step_timing
    for name in phases:
        phases[name] += getattr(timing, name)
result = {'variant': variant, 'runs': rows,
          'cpp_phase_seconds': {k.removesuffix('_ns'): v / 1e9 for k, v in phases.items()}}
Path(f'out/bench-cpp-{variant}.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2), flush=True)
