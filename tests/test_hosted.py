"""Exercise CoWorld handoff, private output, failures, and lockstep replay."""
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

root = Path('out/hosted-test').resolve()
root.mkdir(parents=True, exist_ok=True)
for invalid in [False, True]:
    directory = root / ('invalid' if invalid else 'valid')
    directory.mkdir(exist_ok=True)
    for name in ['results.json', 'failure.json', 'status.json', 'match.replay']:
        (directory / name).unlink(missing_ok=True)
    config = dict(tokens=[f'token-{i}' for i in range(32)],
                  players=[dict(name=f'Cog {i}') for i in range(32)],
                  seed=1, max_ticks=10000)
    seats = []
    for i in range(32):
        policy = directory / f'policy-{i}'
        policy.write_text('this is invalid BASIC' if invalid and i == 3 else
                          f'print "private-seat-{i}"\nact(0)\n')
        seats.append(dict(slot=i, file_uri=policy.as_uri(),
                          content_hash='', size_bytes=policy.stat().st_size,
                          log_uri=(directory / f'log-{i}.txt').as_uri(),
                          artifact_uri=(directory / f'artifact-{i}.zip').as_uri()))
    (directory / 'config.json').write_text(json.dumps(config))
    (directory / 'seats.json').write_text(json.dumps(dict(
        schema='coworld-player-seats/2', seats=seats,
        player_status_uri=(directory / 'status.json').as_uri())))
    env = os.environ.copy()
    for key, name in [('CONFIG','config.json'), ('PLAYER_SEATS','seats.json'),
                      ('RESULTS','results.json'), ('SAVE_REPLAY','match.replay'),
                      ('PLAYER_FAILURE','failure.json')]:
        env[f'COGAME_{key}_URI'] = (directory / name).as_uri()
    env['COGAME_PORT'] = '8137'
    with (directory / 'game.log').open('w') as log:
        process = subprocess.Popen(['out/cvc-coworld'], env=env, stdout=log, stderr=log)
        try:
            marker = directory / ('failure.json' if invalid else 'results.json')
            deadline = time.monotonic() + 90
            while not marker.exists():
                assert process.poll() is None, (directory / 'game.log').read_text()
                assert time.monotonic() < deadline, 'Episode timed out'
                time.sleep(.1)
            assert urllib.request.urlopen('http://127.0.0.1:8137/healthz').read() == b'ok'
            assert (directory / 'status.json').is_file()
            result = json.loads(marker.read_text())
            if invalid:
                assert result['failed_policy_index'] == 3
                assert not (directory / 'results.json').exists()
            else:
                assert result['ticks'] == 10000 and len(result['scores']) == 32
                assert (directory / 'match.replay').stat().st_size > 0
                for i in range(32):
                    text = (directory / f'log-{i}.txt').read_text()
                    assert f'private-seat-{i}\n' in text
                    assert f'private-seat-{(i+1)%32}\n' not in text
                assert 'private-seat-' not in (directory / 'game.log').read_text()
        finally:
            process.terminate()
            process.wait(timeout=10)
    print('Passed', 'compilation failure' if invalid else 'full match and private logs')
