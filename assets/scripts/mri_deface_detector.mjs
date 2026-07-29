#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import * as tf from '@tensorflow/tfjs-node';
import * as niftiNs from 'nifti-reader-js';

const nifti = niftiNs.default ?? niftiNs;

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i];
    const val = argv[i + 1];
    if (!key || !key.startsWith('--') || val === undefined) {
      throw new Error(`Bad arguments near: ${key ?? '<end>'}`);
    }
    out[key.slice(2)] = val;
  }
  return out;
}

function nodeBufferToArrayBuffer(buf) {
  return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
}

function readTypedImage(imageBuffer, dims) {
  const nvox = dims.reduce((a, b) => a * b, 1);

  if (imageBuffer.byteLength === nvox) return new Int8Array(imageBuffer);
  if (imageBuffer.byteLength === nvox * 2) return new Int16Array(imageBuffer);
  if (imageBuffer.byteLength === nvox * 4) return new Float32Array(imageBuffer);
  if (imageBuffer.byteLength === nvox * 8) return new Float64Array(imageBuffer);

  throw new Error(
    `Unsupported image byte length ${imageBuffer.byteLength} for ${nvox} voxels`
  );
}

function loadNifti(filePath) {
  let data = nodeBufferToArrayBuffer(fs.readFileSync(filePath));

  if (nifti.isCompressed(data)) {
    data = nifti.decompress(data);
  }
  if (!nifti.isNIFTI(data)) {
    throw new Error(`Not a valid NIfTI file: ${filePath}`);
  }

  const header = nifti.readHeader(data);
  const dims = Array.from(header.dims.slice(1, 4)).reverse();
  const image = nifti.readImage(header, data);
  const imageData = readTypedImage(image, dims);

  return { dims, imageData };
}

function minmaxNormalize(img3d) {
  return tf.tidy(() => {
    const maxVal = img3d.max();
    const minVal = img3d.min();
    let out = img3d.div(maxVal.sub(minVal)).mul(255.0);

    const minScalar = minVal.dataSync()[0];
    if (minScalar < 0) {
      out = out.add(127.5);
    }
    return out;
  });
}

function centerSlice(img3d, dims, axis) {
  return tf.tidy(() => {
    if (axis === 0) {
      return img3d
        .slice([Math.floor(dims[0] / 2), 0, 0], [1, dims[1], dims[2]])
        .squeeze([0]);
    }
    if (axis === 1) {
      return img3d
        .slice([0, Math.floor(dims[1] / 2), 0], [dims[0], 1, dims[2]])
        .squeeze([1]);
    }
    return img3d
      .slice([0, 0, Math.floor(dims[2] / 2)], [dims[0], dims[1], 1])
      .squeeze([2]);
  });
}

function makeModelInput(img3d, dims, axis, inputSize = 32) {
  return tf.tidy(() => {
    const slice = centerSlice(img3d, dims, axis).transpose();
    const withChannel = slice.expandDims(-1);          // [H, W, 1]
    const resized = tf.image.resizeBilinear(withChannel, [inputSize, inputSize], false);
    return resized.expandDims(0).div(255.0);           // [1, 32, 32, 1]
  });
}

async function main() {
  const args = parseArgs(process.argv);

  const input = args.in;
  const modelDir = args['model-dir'];
  const outJson = args['out-json'];
  const outPass = args['out-pass'];
  const threshold = parseFloat(args.threshold ?? '0.5');

  if (!input || !modelDir || !outJson || !outPass) {
    throw new Error('Required args: --in --model-dir --out-json --out-pass [--threshold]');
  }

  const { dims, imageData } = loadNifti(input);

  const img3d = minmaxNormalize(
    tf.tensor(Array.from(imageData), dims, 'float32')
  );

  const input0 = makeModelInput(img3d, dims, 0, 32);
  const input1 = makeModelInput(img3d, dims, 1, 32);
  const input2 = makeModelInput(img3d, dims, 2, 32);

  const modelPath = `file://${path.resolve(modelDir, 'model.json')}`;
  const model = await tf.loadLayersModel(modelPath);

  const predTensor = model.predict([input0, input1, input2]);
  const score = (await predTensor.data())[0];
  const predDefaced = score >= threshold;

  const payload = {
    input_file: path.basename(input),
    model: 'mri-deface-detector',
    score_defaced: score,
    threshold,
    pred_defaced: predDefaced,
    soft_pass: predDefaced
  };

  fs.writeFileSync(outJson, JSON.stringify(payload, null, 2));
  fs.writeFileSync(outPass, predDefaced ? 'true\n' : 'false\n');

  tf.dispose([img3d, input0, input1, input2, predTensor]);
  if (typeof model.dispose === 'function') {
    model.dispose();
  }
}

main().catch((err) => {
  console.error(err?.stack || String(err));
  process.exit(1);
});
