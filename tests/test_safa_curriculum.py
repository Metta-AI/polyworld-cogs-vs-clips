"""Check role renewal, recurrent episode boundaries, and actual idle-loss masking."""
import sys
from pathlib import Path
import numpy as np
import torch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'training'))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from safa import SafaEnvironment, SafaPolicy, PPO, assign_roles, WEIGHTS
import safa_pufferl
from train_puffer import UnavailableUtilization
import pufferlib.pufferl

torch.set_num_threads(2)
torch.manual_seed(7)
roles = assign_roles(np.random.default_rng(7), 100)
assert set(roles) == {3, 4}
assert ((roles.reshape(-1, 8) == 3).sum(axis=1) >= 1).all()
# Source examples: ten resource units pay .05, one alignment plus spent heart .9.
events = np.zeros((3, 10), np.float32)
events[0, 3] = 10
events[1, [7, 9]] = 1
events[2, 7] = 1
assert np.allclose((events * WEIGHTS[[3, 3, 4]]).sum(1), [.05, .9, 0])
env = SafaEnvironment('out/libcvc.dylib', max_ticks=2)
obs, info = env.reset(7)
first_roles = env.roles.copy()
assert np.array_equal(info[0]['_cogames_train_mask'], first_roles != 4)
# Own role tokens must describe each seat, including idle seats.
for slot, role in enumerate(first_roles):
    assert obs[slot, 108 + 2 * role, 12, 12] > 0
    assert obs[slot, 36 + 2 * role, 6, 6] > 0
for _ in range(2):
    obs, rewards, done, _, info = env.step(np.zeros(32, np.int32))
assert done.all() and (obs[:, 134, 0, 0] == 1).all()
assert not np.array_equal(env.roles, first_roles)
assert np.array_equal(info[0]['_cogames_train_mask'], env.roles != 4)
policy = SafaPolicy()
# A reset observation must erase prior LSTM memory, not leak the previous game.
with torch.no_grad():
    sample = torch.from_numpy(obs[:2].copy())
    a = policy(sample, dict(lstm_h=torch.randn(2,512), lstm_c=torch.randn(2,512)))
    b = policy(sample, dict(lstm_h=torch.zeros(2,512), lstm_c=torch.zeros(2,512)))
    assert all(torch.equal(x,y) for x,y in zip(a,b))
env.close()
env = SafaEnvironment('out/libcvc.dylib', max_ticks=10000)
argv = sys.argv
sys.argv = [sys.argv[0]]
config = pufferlib.pufferl.load_config('default')['train']
sys.argv = argv
config.update(PPO)
config.update(env='mask_test',device='cpu',optimizer='adam',use_rnn=True,
              batch_size=32*8,bptt_horizon=8,minibatch_size=256,
              max_minibatch_size=256,total_timesteps=1000000,checkpoint_interval=10000,
              seed=7,data_dir='out/safa-mask-test',compile=False,
              cpu_offload=False,precision='float32')
safa_pufferl.Utilization = UnavailableUtilization
trainer = safa_pufferl.PuffeRL(config,env,policy)
trainer.print_dashboard = lambda *a,**kw: None
try:
    trainer.evaluate()
    assert set(trainer.train_mask.unique().tolist()) == {0.,1.}
    before = {k:v.clone() for k,v in policy.state_dict().items()}
    trainer.train_mask.zero_()
    trainer.train()
    assert all(torch.equal(v,before[k]) for k,v in policy.state_dict().items())
finally:
    trainer.close()
print('Role assignment, observation IDs, renewal, episode memory and idle PPO masking pass.')
