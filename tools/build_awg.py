"""Build the pinned official AmneziaWG Android tunnel from source, including submodules."""
from pathlib import Path
import subprocess,shutil,os
root=Path(__file__).resolve().parents[1]
sha='ff15093bf3856fea0947923474870b86efb682f0'
vendor=root/'build/awg-source'
def run(args,cwd=None):subprocess.run(args,cwd=cwd,check=True)
if not (vendor/'.git').exists():
 vendor.parent.mkdir(parents=True,exist_ok=True)
 run(['git','clone','--no-checkout','https://github.com/amnezia-vpn/amneziawg-android.git',str(vendor)])
run(['git','checkout','--detach',sha],vendor)
run(['git','submodule','update','--init','--recursive'],vendor)
settings=vendor/'settings.gradle.kts'
settings.write_text(settings.read_text().replace('include(":ui")',''))
# Build the library only, preserving official namespace and pinned submodules.
run(['bash','gradlew',':tunnel:assembleRelease','--no-daemon'],vendor)
out=root/'android/app/libs';out.mkdir(parents=True,exist_ok=True)
shutil.copyfile(vendor/'tunnel/build/outputs/aar/tunnel-release.aar',out/'amneziawg-tunnel.aar')
print('Built official AmneziaWG tunnel at',sha)
