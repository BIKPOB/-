"""Mirror the public VPN Gate feed; never generate profiles or invent live status."""
import urllib.request,csv,datetime,json,os,base64
url='https://www.vpngate.net/api/iphone/'
with urllib.request.urlopen(url,timeout=45) as response:
 data=response.read(12*1024*1024+1)
if len(data)>12*1024*1024:raise ValueError('Catalog too large')
body=data.decode('utf-8-sig');lines=body.replace('\r\n','\n').splitlines()
start=next(i for i,l in enumerate(lines) if l.startswith('#HostName,'))
rows=list(csv.DictReader([lines[start][1:]]+[l for l in lines[start+1:] if l.strip()!='*']))
valid=0
for row in rows:
 p=row.get('OpenVPN_ConfigData_Base64','')
 if p and len(base64.b64decode(p))<=131072:valid+=1
if valid<1:raise ValueError('No public profiles; retaining previous snapshot')
content=json.dumps({'fetchedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source':url,'csv':body},ensure_ascii=False).encode()
api='https://api.github.com/repos/'+os.environ['GITHUB_REPOSITORY']+'/contents/catalog/vpngate.json'
headers={'Authorization':'Bearer '+os.environ['GH_TOKEN'],'Accept':'application/vnd.github+json','User-Agent':'QuietVPN-catalog'}
sha=None
try:
 with urllib.request.urlopen(urllib.request.Request(api,headers=headers),timeout=30) as r:sha=json.load(r)['sha']
except urllib.error.HTTPError as e:
 if e.code!=404:raise
payload={'message':'Refresh public VPN Gate cache [skip ci]','content':base64.b64encode(content).decode(),'branch':'main'}
if sha:payload['sha']=sha
with urllib.request.urlopen(urllib.request.Request(api,data=json.dumps(payload).encode(),headers=headers,method='PUT'),timeout=30) as r:
 print('Snapshot updated:',valid,'public profiles;',r.status)
