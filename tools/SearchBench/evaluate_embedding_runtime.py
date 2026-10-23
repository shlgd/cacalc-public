"""Local Core ML precision/compute experiment; canonical weights never change.

Requires coremltools 9.0, numpy, tokenizers. No torch, download or personal data.
Conversion intermediates live in TemporaryDirectory and are removed on exit.
Quality means agreement with current FP32 embeddings on these synthetic strings,
not accuracy of matching arbitrary food or iPhone latency.
"""
import argparse
import gc
import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load
import numpy as np
from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parents[2]
DOCS = ['Яблоко', 'Банан, мякоть', 'Молоко 1%', 'Молоко 3,5%', 'Творог 5%', 'Творог 9%',
        'Пюре из чечевицы', 'Пюре из картофеля', 'Овсяные хлопья', 'Гречка, сухая',
        'Йогурт без сахара', 'Йогурт с сахаром', 'Куриная грудка, сырая', 'Куриная грудка, готовая',
        'Апельсин', 'Рис, сухой', 'Хлеб ржаной', 'Огурец', 'Помидор']
QUERIES = ['яблоко', 'банана', 'молока один процент', 'молоко 3.5 процента', 'творог пять процентов',
           'творога девять процентов', 'чечевичное пюре', 'картофельное пюре', 'геркулес', 'гречка',
           'йогурт без сахара', 'йогурт с сахаром', 'куриная грудка', 'сырая курица', 'готовая курица',
           'апельсин', 'рис', 'ржаного хлеба', 'огурца', 'томаты', 'суп из ресторана',
           'протеин первый русский протеин', 'кофе с молоком', 'яблоко и банан']


def rss():
    return int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(__import__('os').getpid())]).strip()) * 1024


def inputs(tokenizer, text):
    tokens = tokenizer.encode(text).ids
    ids = tokens[:64]
    if len(tokens) > 64:
        ids[-1] = tokens[-1]
    return {'input_ids': np.asarray([ids + [1] * (64-len(ids))], dtype=np.int32),
            'attention_mask': np.asarray([[1] * len(ids) + [0] * (64-len(ids))], dtype=np.int32)}


def evaluate(path, unit, tokenizer):
    baseline = rss(); began = time.perf_counter()
    model = ct.models.MLModel(str(path), compute_units=unit)
    result = {'loadSeconds': time.perf_counter()-began, 'rssBefore': baseline, 'rssLoaded': rss()}
    vectors, timings = [], []
    for text in ['passage: '+x for x in DOCS] + ['query: '+x for x in QUERIES]:
        began = time.perf_counter()
        vector = model.predict(inputs(tokenizer, text))['embedding'].reshape(-1).astype(np.float64)
        timings.append(time.perf_counter()-began)
        if not np.isfinite(vector).all() or np.linalg.norm(vector) <= 0:
            result.update(finite=False, firstInvalidText=text, rssInferred=rss())
            del model; gc.collect()
            return result, None
        vectors.append(vector / np.linalg.norm(vector))
    result.update(finite=True, firstInferenceSeconds=timings[0], medianInferenceSeconds=statistics.median(timings[1:]), rssInferred=rss())
    del model; gc.collect()
    return result, np.asarray(vectors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert ct.__version__ == '9.0', 'The MIL proto loader is pinned to coremltools 9.0'
    package = ROOT/'data/search-e5/FoodEmbedding.mlpackage'
    tokenizer = Tokenizer.from_file(str(ROOT/'data/search-e5/FoodSearch/tokenizer/tokenizer.json'))
    report = {'platform': 'Mac', 'coremltools': ct.__version__, 'docs': DOCS, 'queries': QUERIES,
              'qualityScope': 'Agreement with current FP32 on synthetic strings; no iPhone claims', 'variants': {}}
    base, reference = evaluate(package, ct.ComputeUnit.CPU_ONLY, tokenizer)
    assert reference is not None
    report['variants']['fp32_cpuOnly'] = base
    other, vectors = evaluate(package, ct.ComputeUnit.CPU_AND_NE, tokenizer)
    report['variants']['fp32_cpuAndNeuralEngine'] = other
    expected = reference[len(DOCS):] @ reference[:len(DOCS)].T
    def compare(result, vectors):
        if vectors is not None:
            scores = vectors[len(DOCS):] @ vectors[:len(DOCS)].T
            result.update(minReferenceCosine=float(np.min(np.sum(reference*vectors, axis=1))),
                          maxScoreDifference=float(np.max(np.abs(scores-expected))),
                          sameTop1=int(np.sum(np.argmax(scores, axis=1) == np.argmax(expected, axis=1))), totalQueries=len(QUERIES))
    compare(other, vectors)
    with tempfile.TemporaryDirectory(prefix='cacalc-e5-precision-') as folder:
        source = ct.models.MLModel(str(package), skip_model_load=True)
        for name, precision in [('fp16', ct.precision.FLOAT16), ('mixed16', ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type in {'matmul', 'linear', 'gather'}))]:
            began = time.perf_counter()
            program = load(source.get_spec(), source.get_spec().specificationVersion, file_weights_dir=source.weights_dir)
            model = ct.convert(program, source='milinternal', convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17, compute_precision=precision, skip_model_load=True)
            path = Path(folder)/(name+'.mlpackage'); model.save(str(path)); del model, program; gc.collect()
            conversion_seconds = time.perf_counter()-began
            size = sum(x.stat().st_size for x in path.rglob('*') if x.is_file())
            for label, units in [('cpuOnly', ct.ComputeUnit.CPU_ONLY), ('cpuAndNeuralEngine', ct.ComputeUnit.CPU_AND_NE)]:
                result, vectors = evaluate(path, units, tokenizer)
                result.update(conversionSeconds=conversion_seconds, packageBytes=size)
                compare(result, vectors); report['variants'][name+'_'+label] = result
                print(name, label, json.dumps(result), flush=True)
            __import__('shutil').rmtree(path)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print('Saved', args.output)


if __name__ == '__main__':
    main()
