#!/usr/bin/env python3
"""The inputs and outcomes of a lab/race.sh campaign in the terms of lab/queue.py predict, to check the model.

    python3 lab/xfit.py measurements/2026-10-22/race/X.n8.jsonl.gz
S = lock hold of a landed merge, A = agent time per conflict, pc = conflicts per fresh lock take (a take after an
agent run that saw no merge is not fresh), exit-4 counts per landed branch. Feed S - SUITE as --o, A, pc to predict.
"""
import gzip
import json, sys, collections
p=sys.argv[1]; ev=[json.loads(l) for l in (gzip.open(p, 'rt') if p.endswith('.gz') else open(p))]
runs=collections.defaultdict(list)
for e in ev: runs[e['run']].append(e)
W=[]; S=[]; A=[]; takes=conf=e4=landed=0; se4=set(); land=[]
for r,es in runs.items():
    if not any(e['ev']=='run-end' for e in es): continue
    wt={}; tk={}
    by=collections.defaultdict(list)
    for e in es:
        if e['ev']=='lock-wait': wt[e['pid']]=e['t']
        elif e['ev']=='lock-taken': takes+=1; tk[e['pid']]=e['t']; W.append(e['t']-wt.pop(e['pid'],e['t']))
        elif e['ev']=='merge-done' and e.get('rc')==0 and e['pid'] in tk: S.append(e['t']-tk[e['pid']])
        elif e['ev']=='ship-conflict': conf+=1
        elif e['ev']=='end' and e['outcome']=='landed': landed+=1
        if 'wt' in e: by[e['wt']].append(e)
    for w,xs in by.items():
        for x,y in zip(xs,xs[1:]):
            if x['ev']=='ship-conflict' and y['ev'] in ('ship-exit','ship-round'): A.append(y['t']-x['t'])
            if y['ev']=='ship-exit' and y['rc']==4: e4+=1; se4.add((r,w))
        r0=[x for x in xs if x['ev']=='ship-round']; ok=[x for x in xs if x['ev']=='ship-exit' and x['rc']==0]
q=lambda xs,p: sorted(xs)[min(len(xs)-1,int(p*len(xs)))]
fresh=takes-(conf-e4)
print(json.dumps(dict(wait_p50=round(q(W,.5),2),wait_p95=round(q(W,.95),2),S=round(sum(S)/len(S),2),A=round(sum(A)/len(A),2),pc=round(conf/max(fresh,1),2),exit4_per_landed=round(100*e4/landed),sessions_with_exit4=round(100*len(se4)/landed),landed=landed)))
