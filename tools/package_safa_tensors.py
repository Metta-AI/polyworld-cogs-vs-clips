"""Package Safa's unchanged float32 weights with a BASIC tensor program."""
import json
from pathlib import Path
import struct
import zipfile

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
model = Path('out/safa/model.bin').read_bytes()
assert model[:12] == b'SAFANN01' + struct.pack('<I', 134)
assert len(model) == offset
entries.append(dict(name='centerIndices', dtype='int32', shape=[134],
                    resource='indices.bin', offset=0))
output = Path('out/safa/safa-tensors.zip')
with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    archive.write('players/neural/safa.bas', 'player.bas')
    archive.writestr('model.bin', model)
    archive.write('out/safa/model.json', 'model.json')
    archive.writestr('indices.bin', struct.pack('<134i', *[i*169+84 for i in range(134)]))
    archive.writestr('tensors.json', json.dumps(dict(tensors=entries)))
print(output, output.stat().st_size)
