"""Query OSV for the exact hosted Pub package versions in the supplied lockfile."""
import datetime,json,sys,urllib.request
from pathlib import Path
import yaml
lock=yaml.safe_load(Path(sys.argv[1]).read_text())
packages=[{'package':{'name':n,'ecosystem':'Pub'},'version':str(p['version'])} for n,p in lock['packages'].items() if p['source']=='hosted']
req=urllib.request.Request('https://api.osv.dev/v1/querybatch',data=json.dumps({'queries':packages}).encode(),headers={'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=90) as res:
 results=json.load(res)['results']
report={'date_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Resolved hosted Pub dependencies only. Does not cover native bundled libraries or prove malware absence.','packages':[dict(q,findings=r) for q,r in zip(packages,results)]}
Path(sys.argv[2]).write_text(json.dumps(report,indent=2))
findings=[r for r in results if r.get('vulns')]
print(f'{len(packages)} packages queried; {len(findings)} packages with advisories')
if findings:sys.exit(1)
