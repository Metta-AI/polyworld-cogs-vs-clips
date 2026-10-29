"""Package Safa's unchanged float32 weights with a BASIC tensor program."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--checkpoint')
parser.add_argument('--model', default='out/safa/model.bin')
parser.add_argument('--output', default='out/safa/safa-tensors.zip')
args = parser.parse_args()
shapes = {
    'scales': [256],
    'conv1': [64, 134, 3, 3], 'bias1': [64], 'norm1': [64], 'shift1': [64],
    'conv2': [128, 64, 3, 3], 'bias2': [128], 'norm2': [128], 'shift2': [128],
    'image': [256, 2048], 'imageBias': [256],
    'center': [256, 134], 'centerBias': [256],
    'input': [2048, 512], 'recurrent': [2048, 512],
    'inputBias': [2048], 'recurrentBias': [2048],
    'actor': [5, 512], 'actorBias': [5], 'critic': [1, 512], 'criticBias': [1],
}
entries = []
offset = 12
for name, shape in shapes.items():
    count = 1
    for dimension in shape:
        count *= dimension
    entries.append(dict(name=name, dtype='float32', shape=shape,
                        resource='model.bin', offset=offset))
    offset += count * 4
modelPath = Path(args.model)
if args.checkpoint:
    import torch
    keys = ['_feature_scale', '_cnn.0.weight', '_cnn.0.bias', '_cnn.1.weight',
            '_cnn.1.bias', '_cnn.3.weight', '_cnn.3.bias', '_cnn.4.weight',
            '_cnn.4.bias', '_cnn_fc.weight', '_cnn_fc.bias', '_self_encoder.weight',
            '_self_encoder.bias', '_rnn.weight_ih_l0', '_rnn.weight_hh_l0',
            '_rnn.bias_ih_l0', '_rnn.bias_hh_l0', '_action_head.weight',
            '_action_head.bias', '_value_head.weight', '_value_head.bias']
    state = torch.load(args.checkpoint, map_location='cpu', weights_only=True)
    if set(state) != set(keys):
        raise ValueError('Unexpected checkpoint parameters')
    chunks = [b'SAFANN01' + struct.pack('<I', 134)]
    for key, shape in zip(keys, shapes.values(), strict=True):
        tensor = state[key].detach().contiguous()
        if list(tensor.shape) != shape or not torch.isfinite(tensor).all():
            raise ValueError('Invalid checkpoint tensor: ' + key)
        chunks.append(tensor.numpy().astype('<f4').tobytes())
    modelPath.parent.mkdir(parents=True, exist_ok=True)
    modelPath.write_bytes(b''.join(chunks))
    modelPath.with_suffix('.json').write_text(json.dumps(dict(
        checkpoint_sha256=hashlib.sha256(Path(args.checkpoint).read_bytes()).hexdigest(),
        model_sha256=hashlib.sha256(modelPath.read_bytes()).hexdigest(),
        features=134, architecture='CNN-GN-LSTM512',
        schema_status='reconstructed candidate, not authenticated submission metadata'), indent=2))
model = modelPath.read_bytes()
assert model[:12] == b'SAFANN01' + struct.pack('<I', 134)
assert len(model) == offset
entries.append(dict(name='centerIndices', dtype='int32', shape=[134],
                    resource='indices.bin', offset=0))
output = Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    archive.write('players/neural/safa.bas', 'player.bas')
    archive.writestr('model.bin', model)
    archive.write(modelPath.with_suffix('.json'), 'model.json')
    archive.writestr('indices.bin', struct.pack('<134i', *[i*169+84 for i in range(134)]))
    archive.writestr('tensors.json', json.dumps(dict(tensors=entries)))
print(output, output.stat().st_size)
