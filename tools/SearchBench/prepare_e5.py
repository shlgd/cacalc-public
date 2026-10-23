"""Optional public-model preparation; no personal data. Outputs ignored build assets."""
import json, time, pathlib, sqlite3, shutil
import numpy as np
import torch
from transformers import AutoTokenizer, AutoModel
import coremltools as ct
root=pathlib.Path(__file__).resolve().parents[2]
out=root/'data/search-e5';out.mkdir(parents=True,exist_ok=True)
repo='intfloat/multilingual-e5-small';revision='614241f622f53c4eeff9890bdc4f31cfecc418b3'
torch.set_num_threads(2)
t=time.perf_counter(); tok=AutoTokenizer.from_pretrained(repo,revision=revision); model=AutoModel.from_pretrained(repo,revision=revision,attn_implementation='eager').eval()
print('load',time.perf_counter()-t,flush=True)
class Encoder(torch.nn.Module):
 def __init__(self): super().__init__();self.encoder=model
 def forward(self,input_ids,attention_mask):
  h=self.encoder(input_ids=input_ids,attention_mask=attention_mask).last_hidden_state
  mask=attention_mask.unsqueeze(-1).float()
  v=(h*mask).sum(1)/mask.sum(1).clamp(min=1)
  return torch.nn.functional.normalize(v,p=2,dim=1)
e=Encoder().eval()
def encode(texts):
 x=tok(texts,padding='max_length',truncation=True,max_length=64,return_tensors='pt')
 with torch.no_grad(): return e(x['input_ids'],x['attention_mask']).numpy()
# Synthetic development probe, not production accuracy.
docs=['Гречка Агроальянс','Огурец свежий','Овсяные хлопья','Куриная грудка сырая','Творог 5%','Творог 9%','Йогурт без сахара','Йогурт с сахаром','Картофель вареный','Картофель сырой','Помидор свежий','Рис сухой']
queries=['геркулес','томаты','гречка агро альянс','гречка аграальянс','картошка отварная','творог пять процентов','йогурт без сахара','куриная грудка','полёт самолёта']
d=encode(['passage: '+x for x in docs]);q=encode(['query: '+x for x in queries]);report=[]
for text,v in zip(queries,q):
 scores=d@v; ix=np.argsort(-scores)[:3];report.append({'query':text,'top':[(docs[i],float(scores[i])) for i in ix]})
print(json.dumps(report,ensure_ascii=False),flush=True)
(out/'probe.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
assets=out/'FoodSearch';assets.mkdir(exist_ok=True)
tok.save_pretrained(assets/'tokenizer')
example=(torch.ones((1,64),dtype=torch.long),torch.ones((1,64),dtype=torch.long))
t=time.perf_counter()
with torch.no_grad(): traced=torch.jit.trace(e,example)
ml=ct.convert(traced,inputs=[ct.TensorType(name='input_ids',shape=(1,64),dtype=np.int32),ct.TensorType(name='attention_mask',shape=(1,64),dtype=np.int32)],outputs=[ct.TensorType(name='embedding')],minimum_deployment_target=ct.target.iOS17,compute_precision=ct.precision.FLOAT32)
ml.save(str(out/'FoodEmbedding.mlpackage'))
# Check actual converted runtime against the reference, not only graph conversion.
x=tok('query: гречка агро альянс',padding='max_length',truncation=True,max_length=64,return_tensors='np')
pred=ml.predict({k:v.astype(np.int32) for k,v in x.items() if k in ['input_ids','attention_mask']})['embedding'].reshape(-1)
ref=encode(['query: гречка агро альянс'])[0];similarity=float(pred@ref/(np.linalg.norm(pred)*np.linalg.norm(ref)))
print('conversion_seconds',time.perf_counter()-t,'cosine',similarity,flush=True)
assert similarity>.999
rows=sqlite3.connect(root/'ios/Resources/catalog.sqlite').execute('select id,name,brands from products').fetchall()
cache={}
for start in range(0,len(rows),16):
 batch=rows[start:start+16];texts=[' '.join([r[1],r[2]]).strip() for r in batch]
 vectors=encode(['passage: '+x for x in texts])
 for r,text,v in zip(batch,texts,vectors):cache[r[0]]={'text':text,'vector':[round(float(n),7) for n in v]}
(assets/'catalog-vectors.json').write_text(json.dumps(cache,ensure_ascii=False,separators=(',',':')))
(assets/'manifest.json').write_text(json.dumps({'model':repo,'revision':revision,'dimensions':384,'maxTokens':64,'conversionCosine':similarity,'license':'MIT'},indent=2))
print('READY',out,flush=True)
