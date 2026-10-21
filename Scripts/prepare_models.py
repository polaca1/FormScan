"""Fetch pinned, hash-verified models; adapt RF-DETR's signed ConvInteger weights.

Changing (w, zero_point) to (w + 128, zero_point + 128) preserves the exact
integer convolution while enabling ORT 1.20's uint8/uint8 CPU kernel on mobile.
No training, float re-quantization, or changes to scales or predictions.
"""
import hashlib
import pathlib
import shutil
import urllib.request

import numpy as np
import onnx
from onnx import numpy_helper

ROOT = pathlib.Path(__file__).resolve().parents[1]
NANO = "https://huggingface.co/nutrientdocs/form-field-v1-nano/resolve/7cbc1ecd55d59f6315a1415dddc59c3c8b115f05/"
DETR = "https://huggingface.co/Frooodle/ffdetr-int8/resolve/ad3223d7c3ae25ce1d1ec8fe972c8ff7630aff45/ffdetr-int8.onnx"


def fetch(url, path, checksum):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        with urllib.request.urlopen(url) as response, path.open("wb") as target:
            shutil.copyfileobj(response, target)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == checksum, f"Model checksum mismatch: {path.name}"


def main():
    fetch(NANO + "model.onnx", ROOT / "Models/model.onnx", "d7ab44396154af79409c9f8a4fded6c9aa907ae6d283fbe5d2b533d3b7314ec1")
    compact = ROOT / "ModelAssets/nano-compact.onnx"
    fetch(NANO + "model_fp16.onnx", compact, "88e2a21b65a7d481e0c65541be874b07f3fa5fcb50c2bd2d78a615fd82c0a523")
    original = ROOT / "ModelAssets/ffdetr-original.onnx"
    fetch(DETR, original, "de43bb39adb08459fe62fa1a7be6bfb4f2d397bb034c46055f3b8fa3d04fc8f4")
    model = onnx.load(str(original))
    initializers = {value.name: value for value in model.graph.initializer}
    for node in model.graph.node:
        if node.op_type != "ConvInteger":
            continue
        for index in (1, 3):
            if index >= len(node.input) or node.input[index] not in initializers:
                continue
            values = numpy_helper.to_array(initializers[node.input[index]])
            if values.dtype == np.int8:
                shifted = (values.astype(np.int16) + 128).astype(np.uint8)
                assert np.array_equal(shifted.astype(np.int16) - 128, values.astype(np.int16))
                name = node.input[index] + "_u8_compat"
                model.graph.initializer.append(numpy_helper.from_array(shifted, name))
                node.input[index] = name
    used = {name for node in model.graph.node for name in node.input}
    keep = [value for value in model.graph.initializer if value.name in used]
    del model.graph.initializer[:]
    model.graph.initializer.extend(keep)
    onnx.checker.check_model(model)
    mobile = ROOT / "ModelAssets/ffdetr-mobile-int8.onnx"
    mobile.write_bytes(model.SerializeToString(deterministic=True))
    assert hashlib.sha256(mobile.read_bytes()).hexdigest() == "83adb3b1b6ed8ebe584c9046725913b541daccd9aee6d7bd18a00bbdebe6e33e"
    fixtures = ROOT / "Tests/Models"
    fixtures.mkdir(parents=True, exist_ok=True)
    for path in (compact, mobile):
        shutil.copyfile(path, fixtures / path.name)
    for path in (compact, mobile):
        shutil.copyfile(path, ROOT / "Models" / path.name)
    print("All three verified inference resources are bundled for automatic offline analysis.")


if __name__ == "__main__":
    main()
