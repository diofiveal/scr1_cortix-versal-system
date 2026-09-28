from pathlib import Path
import subprocess,sys,json,re,shutil,os,time
R=Path(__file__).resolve().parents[2]; logs=R/'reports'; logs.mkdir(parents=True,exist_ok=True)
status={'scope':'local simulation and static checks; not Vivado implementation or hardware validation','started_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'tests':{},'environment':{}}
for t in ['verilator','g++','tclsh','vivado']:
 status['environment'][t]=shutil.which(t)
core=R/'third_party/scr1/src'
files=[R/'rtl/control/vd100_scr1_pkg.sv',R/'rtl/control/scr1_regs_pkg.sv']
for listname in ['core.files','axi_top.files']:
 p=core/listname
 if p.exists():
  for l in p.read_text().splitlines():
   l=l.strip()
   if l and not l.startswith(('#','//','+','-')):files.append(core/l)
for n in ['scr1_control_axil.sv','scr1_lifecycle_fsm.sv','scr1_fault_irq_aggregator.sv','scr1_control_top.sv']:
 files.append(R/'rtl/control'/n)
files.extend([R/'rtl/scr1_subsystem.sv'])
files=list(dict.fromkeys(files)); status['missing_sources']=[str(p.relative_to(R)) for p in files if not p.exists()]
# Some earlier generator revisions placed packages directly under rtl/include.
for i,p in enumerate(files):
 if not p.exists():
  q=[x for x in R.rglob(p.name) if 'originals' not in x.parts]
  if len(q)==1:files[i]=q[0]
status['missing_sources']=[str(p.relative_to(R)) for p in files if not p.exists()]
boot=[R/'rtl/boot/boot_bram_write_guard.sv',R/'rtl/boot/scr1_boot_bram_axil.sv']
include=['-I'+str(R/'rtl/include'),'-I'+str(core/'includes'),'+define+SCR1_ARCH_CUSTOM']

def run(name,top,sources,lint=False):
 out=logs/(name+'.log')
 if not shutil.which('verilator'):
  status['tests'][name]={'status':'NOT_RUN','reason':'Verilator unavailable'};return
 if any(not p.exists() for p in sources):
  status['tests'][name]={'status':'NOT_RUN','reason':'Missing source','missing':[str(p) for p in sources if not p.exists()]};return
 cmd=['verilator', '--lint-only' if lint else '--binary','--timing','--assert','-Wno-fatal','--top-module',top,'--Mdir',str(R/'build_sim'/name)]+include
 if not lint:cmd+=['-j','2']
 cmd+=[str(p) for p in sources]
 start=time.monotonic()
 try:
  p=subprocess.run(cmd,cwd=R,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=300)
  out.write_text('COMMAND: '+ ' '.join(cmd)+'\n\n'+p.stdout)
  result={'status':'PASS' if p.returncode==0 else 'COMPILE_FAIL','returncode':p.returncode,'log':'reports/'+out.name}
  if p.returncode==0 and not lint:
   exe=R/'build_sim'/name/('V'+top)
   q=subprocess.run([str(exe)],cwd=R,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
   (logs/(name+'_run.log')).write_text(q.stdout)
   result.update(status='PASS' if q.returncode==0 else 'SIMULATION_FAIL',simulation_returncode=q.returncode,run_log='reports/'+name+'_run.log')
  result['duration_seconds']=round(time.monotonic()-start,2);status['tests'][name]=result
 except subprocess.TimeoutExpired as e:
  output=e.stdout or b''
  if isinstance(output,bytes):output=output.decode(errors='replace')
  out.write_text(output);status['tests'][name]={'status':'TIMEOUT','log':'reports/'+out.name}
 except Exception as e: status['tests'][name]={'status':'ERROR','reason':repr(e)}
 (logs/'verification_status.json').write_text(json.dumps(status,indent=2))

run('lifecycle','tb_scr1_lifecycle',files[:2]+[R/'rtl/control/scr1_lifecycle_fsm.sv',R/'sim/tb_scr1_lifecycle.sv'])
run('mem_axi','tb_scr1_mem_axi',[core/'top/scr1_mem_axi.sv',R/'sim/tb_scr1_mem_axi.sv'])
run('boot_bram','tb_boot_bram',boot+[R/'sim/tb_boot_bram.sv'])
run('subsystem','tb_scr1_subsystem',files+[R/'sim/axi_memory_model.sv',R/'sim/tb_scr1_subsystem.sv'])
run('board_top_lint','vd100_scr1_top',files+boot+[R/'rtl/vd100_scr1_top.sv',R/'sim/vd100_platform_wrapper_lint_stub.sv'],True)
status['finished_at']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
(logs/'verification_status.json').write_text(json.dumps(status,indent=2))
print(json.dumps(status,indent=2))

sys.exit(0 if status.get('tests') and not status.get('missing_sources') and all(x.get('status')=='PASS' for x in status['tests'].values()) else 1)
