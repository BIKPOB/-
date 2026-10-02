"""Static APK inventory; marker checks are limited heuristics, not a safety verdict."""
import datetime,hashlib,json,sys,zipfile,re
from pathlib import Path
from loguru import logger
logger.remove()
from androguard.core.apk import APK
p=Path(sys.argv[1]);apk=APK(str(p))
markers=['com/google/android/gms/ads','com/facebook/ads','com/applovin','com/unity3d/ads','com/ironsource','com/startapp','com/adjust/sdk','com/appsflyer','com/google/firebase/analytics']
with zipfile.ZipFile(p) as z:
 hits=[];versions=[]
 for n in z.namelist():
  if n.endswith(('.dex','.so')):
   d=z.read(n)
   for m in markers:
    if m.encode() in d or m.replace('/','.').encode() in d:hits.append({'file':n,'marker':m})
   for v in re.findall(rb'(?:OpenVPN [0-9][ -~]{0,100}|OpenSSL [0-9][ -~]{0,100}|mbed TLS [0-9][ -~]{0,80})',d):
    versions.append({'file':n,'string':v.decode(errors='replace')})
 report={'date_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'package':apk.get_package(),'permissions':apk.get_permissions(),'activities':apk.get_activities(),'services':apk.get_services(),'receivers':apk.get_receivers(),'native_libraries':[n for n in z.namelist() if n.endswith('.so')],'native_version_strings':versions,'checked_markers':markers,'marker_hits':hits,'manifest':apk.get_android_manifest_xml() is not None,'limitations':'Static inventory and limited string markers only. Obfuscation and unknown SDKs may evade these checks. No runtime or network behavior tested.'}
 from lxml import etree
 report['manifest_xml']=etree.tostring(apk.get_android_manifest_xml(),encoding='unicode')
Path(sys.argv[2]).write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k in ['sha256','permissions','marker_hits','native_version_strings']},indent=2))
