// Native dashboard snapshot. Shared by rpcd and the compatibility CLI.
// No AT access, shell commands, configuration writes or private credentials.
import * as fs from 'fs';
import * as nl from 'nl80211';
import * as rt from 'rtnl';
import { statvfs } from 'luci.core';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as hotspot from '/usr/libexec/unisoc-modem/hotspot.uc';
import * as apn from '/usr/libexec/unisoc-modem/apn.uc';

const ROOT = getenv('MU300_DASH_SYSROOT') || '';
const CONFIG = getenv('MU300_DASH_CONFIG') || '/etc/config';
// This platform's runtime directory (lib.sh RUN_DIR): the cell and sig caches, the fast.lck
// and collect.lck owner files live here; MU300_DASH_DIR overrides it (tests, chroot).
const RUN = getenv('MU300_DASH_DIR') || '/var/run/unisoc-modem';
function rd(path) { return trim(fs.readfile(ROOT + path) || ''); }
function obj(path) { try { return json(rd(path)); } catch(e) { return null; } }
function num(v) { return v != null && match(''+v, /^-?[0-9]+(\.[0-9]+)?$/) ? +v : null; }
function text(v) { return v == null || v === '' ? null : replace(''+v,/[\r\n]/g,''); }
function device(v) { return type(v)=='string' && v!='.' && v!='..' && match(v,/^[A-Za-z0-9_.:-]{1,15}$/) ? v : null; }
function exists(p) { return fs.stat(ROOT+p)!=null; }
function executable(p) { return fs.access(ROOT+p,'x')==true; }
// A detached child: rpcd's ucode context has no working uloop.process (it returns
// null and starts nothing there - measured on the device and in the test image),
// so a background start goes through the shell. fs.popen() forks, the shell
// backgrounds the command and exits, and closing the pipe only reaps the shell.
function spawn(cmd) {
    let pipe=fs.popen(cmd+' </dev/null >/dev/null 2>&1 &','r');
    if(!pipe)return false;
    pipe.close();
    return true;
};

// A short command whose answer is data (the SIM selector's own account, the VPN
// module's orphan check): fs.popen forks, and only a snapshot that is not cached
// runs it (mu300status keeps that copy).
function runcmd(cmd) {
    let pipe=fs.popen(cmd, 'r');
    if(!pipe)return '';
    let out=pipe.read('all') || '';
    pipe.close();
    return out;
};
export function sim_state(slot) {
    if(!(slot in ['0','1']))return 'unknown';
    let row=obj('/run/mu300-registration/sim'+slot+'.json');
    // The AT owner records absence only after the SIM was known to be powered.
    // An empty ICCID or CFUN=0 alone is never proof of removal.
    if(type(row)!='object' || row.slot!==int(slot) || !exists('/run/mu300-registration/sim-power'+slot) ||
       !(row.state in ['ready','locked','absent']))return 'unknown';
    return row.state;
};
// Equipment identity is independent of SIM presence and the selected view.
// HTTP reads use RAM files; only this bounded background worker uses the AT owner.
let equipment_job=null;
function equipment(atd,slots) {
    let dir='/run/unisoc-modem-equipment', boot_id=rd('/proc/sys/kernel/random/boot_id');
    let valid=boot_id!='' && rd(dir+'/boot_id')==boot_id;
    let values=map(['0','1'],n=>valid && match(rd(dir+'/imei'+n),/^[0-9]{15}$/)?rd(dir+'/imei'+n):null);
    let stamp=fs.stat(ROOT+dir+'/attempt')?.mtime, age=stamp==null?null:time()-stamp;
    if(atd && boot_id!='' && !equipment_job && (values[0]==null || (slots=='2' && values[1]==null)) &&
       (!valid || age==null || age<0 || age>=60)) {
        equipment_job=1;
        spawn('PATH=/usr/sbin:/usr/bin:/sbin:/bin MU300_EQUIPMENT_SLOTS='+slots+
            ' /usr/libexec/unisoc-modem/dashboard-equipment');
    }
    return values;
};
function call(bus,o,m) { return bus?.call(o,m,{}) || {}; }
function net(dev) {
    dev=device(dev);
    if(!dev || !exists('/sys/class/net/'+dev))return null;
    let p='/sys/class/net/'+dev+'/';
    return {rx:num(rd(p+'statistics/rx_bytes')),tx:num(rd(p+'statistics/tx_bytes')),up:rd(p+'operstate')=='up'?1:0};
};
function address(rows,dev,global6) {
    for(let a in rows || []) if(a.dev==dev && a.address) {
        let s=replace(a.address,/\/.*/,'');
        if(!global6 || match(s,/^[23]/))return s;
    }
    return null;
};
function board() {
    // Match mu300-device: live DT outranks a restored rootfs/runtime label.
    if(exists('/proc/device-tree/charger_policy_service'))return 'u30air';
    if(exists('/proc/device-tree/soc/soc:ap-ahb/i2c@2270000/aw9523b_led@5b') ||
       exists('/proc/device-tree/soc/ap-ahb/i2c@2270000/aw9523b_led@5b'))return 'v50';
    if(exists('/proc/device-tree'))return 'f50';
    return rd('/run/mu300/device');
};
export function power() {
    const base='/sys/class/power_supply';
    let model=board(), battery=null, usb=null, usb_dir=null;
    let names=['battery','sc27xx-fgu',...(fs.lsdir(ROOT+base) || [])], seen={};
    for(let name in names) {
        if(seen[name])continue; seen[name]=true;
        let p=base+'/'+name, kind=rd(p+'/type');
        if(model!='f50' && model!='v50' && !battery &&
           (name=='battery' || name=='sc27xx-fgu' || kind=='Battery') &&
           rd(p+'/present')!='0') {
            let raw=rd(p+'/capacity'), cap=match(raw,/^[0-9]+$/)?+raw:null;
            if(cap!=null && cap>=0 && cap<=100)battery=p;
        }
        if(name in ['usb','ac','bq256xx-charger'] || match(kind,/^(USB|Mains)/)) {
            let on=num(rd(p+'/online'));
            if(on==1){if(usb_dir==null)usb_dir=p; usb=1;}
            else if(on==0 && usb==null)usb=0;
        }
    }
    let volts=battery?num(rd(battery+'/voltage_now')):null;
    let amps=battery?num(rd(battery+'/current_now')):null;
    let in_volts=usb_dir?num(rd(usb_dir+'/voltage_now')):null;
    let in_amps=usb_dir?num(rd(usb_dir+'/current_now')):null;
    if(in_amps==null && usb_dir)in_amps=num(rd(usb_dir+'/input_current_now'));
    // watts: |V x I| in W with two decimals, as dashboard-info printed them (never from a zero voltage)
    let watts=(v,a)=>(v!=null && a!=null && v>0)?+sprintf('%.2f',(v<0?-v:v)*a/1000000000000.0):null;
    return {present:battery?1:0,capacity:battery?num(rd(battery+'/capacity')):null,
        status:battery?text(rd(battery+'/status')):null,
        volt:volts!=null && volts>0?+sprintf('%.2f',volts/1000000.0):null,
        ua:amps,w:watts(volts,amps),usb,
        in_volt:in_volts!=null && in_volts>0?+sprintf('%.2f',in_volts/1000000.0):null,
        in_ua:in_amps,in_w:watts(in_volts,in_amps)};
};
export function boot() {
    let state=rd('/etc/mu300/default-boot') || rd('/run/mu300/default-boot') || 'android';
    if(!(state in ['android','linux']))state='unknown';
    let slot=rd('/run/mu300/linux-slot') || 'b', writable=false;
    if(executable('/opt/mu300/bin/mu300-next-boot') && slot in ['a','b']) {
        writable=fs.stat(ROOT+'/run/mu300/misc-bc-linux-trial.bin')?.size>0 &&
            fs.stat(ROOT+'/run/mu300/misc-bc-android.bin')?.size>0;
        if(slot=='b')writable = writable || fs.stat(ROOT+'/run/mu300/misc-bc-slot-b-trial.bin')?.size>0 &&
            fs.stat(ROOT+'/run/mu300/misc-bc-slot-a.bin')?.size>0;
    }
    return {default:state,temporary:state=='unknown'?null:state!='linux',can_set_default:!!writable};
};
function clients(dev,bus,leases) {
    if(!device(dev) || !exists('/sys/class/net/'+dev))return {rows:[],count:0};
    let dump=nl.request(nl.const.NL80211_CMD_GET_STATION,nl.const.NLM_F_DUMP,{dev}), rows=[], seen={};
    // Drivers without station metrics still expose association through hostapd.
    // Both are sources in this single collector, never an alternate backend.
    for(let s in dump || []) {
        let mac=lc(s.mac || '');
        if(!match(mac,/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) || seen[mac])continue;
        seen[mac]=true;
        let i=s.sta_info || {}, lease=leases[mac] || {};
        let rate=(r)=>(r?.bitrate32 ?? r?.bitrate)!=null?sprintf('%g Mbit/s',(r.bitrate32 ?? r.bitrate)/10.0):null;
        push(rows,{mac,host:lease.host,ip:lease.ip,signal:i.signal ?? null,
            tx:rate(i.tx_bitrate),rx:rate(i.rx_bitrate),
            conn:i.connected_time!=null?sprintf('%d min',int(i.connected_time/60)):null});
    }
    if(!length(rows)) {
        let associated=call(bus,'hostapd.'+dev,'get_clients').clients;
        if(associated!=null && dump==null)dump=[];
        for(let mac in associated || {}) {
            mac=lc(mac);
            if(!match(mac,/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/))continue;
            let lease=leases[mac] || {};
            push(rows,{mac,host:lease.host,ip:lease.ip,signal:null,tx:null,rx:null,conn:null});
        }
    }
    return {rows,count:dump==null && !length(rows)?null:length(rows)};
};
export function conntrack() {
    let raw=rd('/proc/sys/net/netfilter/nf_conntrack_count');
    let scalar=match(raw,/^[0-9]+$/)?+raw:null;
    if(scalar!=null)return scalar;
    // Older kernels may expose only the table. Count it in bounded chunks,
    // as wc -l did, rather than allocating a potentially huge connection table.
    fs.error();
    let table=fs.open(ROOT+'/proc/net/nf_conntrack','r');
    if(!table)return null;
    let count=0;
    while(true) {
        let chunk=table.read(4096);
        if(chunk==null || chunk=='')break;
        count+=length(split(chunk,'\n'))-1;
    }
    let error=fs.error(); table.close();
    return error?null:count;
};

export function info(slot) {
    const c=cursor(CONFIG), bus=connect(null,2), now=time();
    function cfg(k,d) { return c.get('unisoc_modem','main',k) || d; }
    let iface=cfg('data_interface','wan'), iface6=cfg('data_interface_v6','wan6');
    let wan=match(iface,/^[A-Za-z0-9_]{1,32}$/)?call(bus,'network.interface.'+iface,'status'):{};
    let wan6=match(iface6,/^[A-Za-z0-9_]{1,32}$/)?call(bus,'network.interface.'+iface6,'status'):{};
    let mobile=device(wan.l3_device || wan.device || cfg('data_device','sipa_eth0'));
    let lan=device(cfg('lan_device','br-lan')), usb=device(cfg('usb_device','usb0'));
    let wifi=hotspot.status(c,call(bus,'network.wireless','status'),cfg('wifi_iface',null),cfg('wifi_device','wlan0'));
    let wd=device(wifi.device || cfg('wifi_device','wlan0'));
    let rows4=rt.request(rt.const.RTM_GETADDR,rt.const.NLM_F_DUMP,{family:rt.const.AF_INET});
    let rows6=rt.request(rt.const.RTM_GETADDR,rt.const.NLM_F_DUMP,{family:rt.const.AF_INET6});
    let leases=[], bymac={};
    for(let line in split(rd('/tmp/dhcp.leases'),'\n')) {
        let f=split(trim(line),/[ \t]+/);
        if(length(f)<4)continue;
        let row={host:f[3]=='*'?null:text(f[3]),ip:text(f[2]),mac:text(f[1]),left:max(0,(num(f[0]) || 0)-now)};
        push(leases,row); bymac[lc(f[1])]=row;
    }
    let stations=clients(wd,bus,bymac), hapd=wd?call(bus,'hostapd.'+wd,'get_status'):{};
    let cpu=split(split(rd('/proc/stat'),'\n')[0],/[ \t]+/), total=0;
    for(let i=1;i<=8;i++)total+=num(cpu[i]) || 0;
    let freqs=[];
    for(let p in fs.glob(ROOT+'/sys/devices/system/cpu/cpufreq/policy*') || []) {
        if(fs.readfile(p+'/scaling_cur_freq')==null)continue;
        push(freqs,{cur:num(trim(fs.readfile(p+'/scaling_cur_freq') || '')),max:num(trim(fs.readfile(p+'/cpuinfo_max_freq') || ''))});
    }
    let mem={};
    for(let line in split(rd('/proc/meminfo'),'\n')) {
        let m=match(line,/^(MemTotal|MemAvailable):[ \t]+([0-9]+)/);
        if(m)mem[m[1]]=+m[2];
    }
    let temps={soc:null,cpu:null,modem:null,board:null,hottest:null};
    let labels={'soc-thmzone':'soc','apcpu0-thmzone':'cpu','nr0-thmzone':'modem','board-thmzone':'board'};
    for(let z in fs.glob(ROOT+'/sys/class/thermal/thermal_zone*') || []) {
        let t=num(trim(fs.readfile(z+'/temp') || '')), kind=trim(fs.readfile(z+'/type') || '');
        if(t==null)continue;
        t=+sprintf('%.1f',t/1000.0);
        if(temps.hottest==null || t>temps.hottest)temps.hottest=t;
        if(labels[kind] && temps[labels[kind]]==null)temps[labels[kind]]=t;
    }
    let vfs=statvfs(ROOT || '/'), storage={total_kb:null,used_kb:null,avail_kb:null};
    if(vfs?.frsize)storage={total_kb:vfs.blocks*vfs.frsize/1024,used_kb:(vfs.blocks-vfs.bfree)*vfs.frsize/1024,avail_kb:vfs.bavail*vfs.frsize/1024};
    let release=match(rd('/etc/openwrt_release'),/DISTRIB_DESCRIPTION='([^']*)'/);
    let kernel=rd('/proc/sys/kernel/osrelease'), fw=release?release[1]:'Linux '+kernel;
    let private_fw=obj('/etc/unisoc-ota/current.json')?.version || rd('/etc/mu300/image-version');
    if(private_fw)fw=private_fw+' ('+fw+')';
    let data_slot=cfg('data_sim','0')=='1'?'1':'0';
    let active_slot=rd('/run/mu300-data-sim-actual');
    if(wan.up) {
        if(mobile==cfg('sim0_device','sipa_eth0'))active_slot='0';
        else if(mobile==cfg('sim1_device','sipa_eth8'))active_slot='1';
    }
    if(exists('/run/mu300/sim-active-unknown'))active_slot='';
    // Each ledger has its own snapshot. A viewed SIM is not necessarily the
    // data SIM; never substitute SIM1's plan or totals for an absent SIM2 view.
    let traffic_slot=slot in ['0','1']?slot:active_slot in ['0','1']?active_slot:data_slot;
    let selection=apn.status(c,obj('/run/unisoc-apn-sim'+data_slot+'.json') || {}), selected_apn=null;
    if(selection.ok && (slot==null || ''+selection.data_sim==slot) && selection.source in ['sim','auto','network','default'] &&
       type(selection.apn)=='string' && length(selection.apn)<=100 && !match(selection.apn,/[^A-Za-z0-9.-]/))
        selected_apn=selection.apn || '(SIM default)';
    let dns=[];
    for(let w in [wan,wan6])for(let ip in w['dns-server'] || [])if(index(dns,ip)<0)push(dns,ip);
    let atd=false;
    for(let p in ['/run/mu300-at','/run/mu300-at4']) {
        let pid=rd(p+'/owner/pid');
        if(match(pid,/^[1-9][0-9]*$/) && exists('/proc/'+pid) && fs.stat(ROOT+p+'/cmd')?.type=='fifo')atd=true;
    }
    let urc=fs.stat(ROOT+'/run/mu300-at/urc/stty_nr0.log');
    let ht=replace(wifi.htmode || '',/[^0-9]/g,'');
    // ---- the dashboard's own additions to the author snapshot (the LuCI home page reads
    // them; other consumers ignore unknown keys). Same sources dashboard-info used, read
    // here without its per-command forks.
    let sim=null;
    if(executable('/opt/mu300/bin/mu300-sim')) {
        let st=null;
        try { st=json(runcmd('/opt/mu300/bin/mu300-sim status --json')); } catch(e) { st=null; }
        if(type(st)=='object') {
            let a=st.active, w=st.default, s1=st.slot1_supported;
            if((a==1 || a==2) && (w==1 || w==2) && (s1==0 || s1==1))sim={slot:a-1,wanted:w-1,slot1_supported:s1};
            if(sim!=null && type(st.v50)=='object')sim.v50=1;
        }
    }
    // the note mu300-update leaves when a check finds a newer release
    let update=null, note=getenv('MU300_NOTICE') || '/run/mu300/update-available';
    for(let line in split(rd(note),'\n')) {
        let m=match(line,/^mu300-linux (v[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[1-9][0-9]?)?) is out /);
        if(m){update=m[1];break;}
    }
    if(update!=null && !match(update,/^v[0-9]{4}\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])(\.[1-9][0-9]?)?$/))update=null;
    // the VPN module: enabled in its config, the selected profile's engine, its link and
    // the kill-switch orphan state (the module's own function, run in its shell)
    let vpn={enabled:0,engine:null,up:0,orphaned:0};
    for(let line in split(rd('/etc/mu300/vpn.conf'),'\n')) if(line=='ENABLE=1')vpn.enabled=1;
    let vact=rd('/etc/mu300/vpn/active');
    if(match(vact,/^[a-z0-9-]{1,32}$/)) {
        for(let line in split(rd('/etc/mu300/vpn/profiles/'+vact+'/meta'),'\n')) {
            let m=match(line,/^TYPE=(.*)$/);
            if(m){let e=replace(m[1],/^'|'$/g,''); if(match(e,/^[A-Za-z0-9._-]{1,32}$/))vpn.engine=e; break;}
        }
    }
    if(vpn.engine==null) for(let line in split(rd('/etc/mu300/vpn.conf'),'\n')) {
        let m=match(line,/^ENGINE=(.*)$/);
        if(m){vpn.engine=replace(m[1],/^'|'$/g,''); break;}
    }
    let vif=rd('/run/mu300-vpn/iface');
    if(match(vif,/^[A-Za-z0-9_.-]{1,32}$/) && exists('/sys/class/net/'+vif))vpn.up=1;
    else if(exists('/sys/class/net/xtun') || exists('/sys/class/net/sbtun'))vpn.up=1;
    if(exists('/opt/mu300/lib/vpn-orphan.sh') &&
       trim(runcmd('/bin/sh -c ". /opt/mu300/lib/vpn-orphan.sh 2>/dev/null && vpn_killswitch_orphaned /opt/mu300/bin/mu300-vpn >/dev/null 2>&1 && echo 1"'))=='1')vpn.orphaned=1;
    // data roaming, as dashboard-info read it: the card's own option (slot 1 has its own)
    // and the marker mobile-data leaves when it holds data back
    let roaming={allowed:1,held:0}, rkey=(active_slot=='1')?'roaming_internal':'roaming';
    let rraw=c.get('network',iface,rkey);
    if(rraw!=null && rraw!='' && (rraw in ['0','off','no','false']))roaming.allowed=0;
    if(exists(getenv('MU300_ROAM_HELD') || '/run/mu300/data-roaming-held'))roaming.held=1;
    // the data usage summary the home card paints (the plan ledger's own counters)
    let tsum={};
    for(let line in split(rd('/run/mu300/traffic/summary'),'\n')) {
        let m=match(line,/^([a-z_]+)=(.*)$/);
        if(m)tsum[m[1]]=m[2];
    }
    let tint=(v)=>{let s=v==null?'':''+v; return match(s,/^(0|[1-9][0-9]*)$/)?+s:0;};
    let tlevel=(tsum.level in ['ok','warn','over','none'])?tsum.level:null;
    let traffic_summary=tlevel!=null?{level:tlevel,today:tint(tsum.today_rx)+tint(tsum.today_tx),
        used:tint(tsum.used),cap:tint(tsum.cap),warn:tint(tsum.warn),clock:tint(tsum.clock)}:null;
    let capabilities={vpn:(executable('/opt/mu300/bin/mu300-vpn') && executable('/etc/init.d/mu300-vpn'))?1:0,
        dualboot:executable('/opt/mu300/bin/mu300-next-boot')?1:0,
        bootlock:(exists('/mnt/mu300-disk/.mu300/boot-lock') || exists('/.mu300/boot-lock'))?1:0};
    return {ts:now,uptime:int(rd('/proc/uptime')),host:text(c.get('system','@system[0]','hostname') || rd('/proc/sys/kernel/hostname')),
        model:text(rd('/tmp/sysinfo/model') || replace(rd('/proc/device-tree/model'),/\x00/g,'')),fw,kernel,
        cpu:{n:length(filter(split(rd('/proc/cpuinfo'),'\n'),line=>!!match(line,/^processor[ \t]*:/))),total,idle:(num(cpu[4]) || 0)+(num(cpu[5]) || 0),freqs},
        mem:{total_kb:mem.MemTotal ?? null,avail_kb:mem.MemAvailable ?? null},storage,temps,power:power(),
        net:{mobile:net(mobile),sipa_eth0:net(mobile),brlan:net(lan),wlan0:net(wd),usb0:net(usb)},
        wan:{up:wan.up?1:0,uptime:wan.uptime ?? null,proto:text(wan.proto),device:mobile,apn:selected_apn,
            ip4:wan['ipv4-address']?.[0]?.address ?? null,ip6:address(rows6,mobile,true),dns:text(join(', ',dns)),roaming},
        wifi:{available:wifi.available?1:0,enabled:wifi.enabled?1:0,pending:wifi.pending?1:0,section:text(wifi.section),radio:text(wifi.radio),
            error:text(wifi.error),up:wifi.up && hapd.status=='ENABLED' && exists('/sys/class/net/'+wd)?1:0,
            ssid:text(wifi.ssid),channel:text(wifi.channel),band:text(wifi.band),width:ht?substr(ht,0,2)+' MHz':null,
            country:text(wifi.country),enc:wifi.enc || 'none',hidden:wifi.hidden ?? null,hostapd:hapd.status=='ENABLED'?1:0,
            clients:stations.rows,clients_n:stations.count},
        lan:{leases:length(leases),ip:address(rows4,lan,false),list:leases},
        modem:{data_sim:active_slot in ['0','1']?int(active_slot):null,alive:atd || (urc && now-urc.mtime<240)?1:0,atd:atd?1:0,data_paused:exists('/run/mu300-mobile-data-down')?1:0,
            imeis:equipment(atd,cfg('sim_slots','1')),sims:map(['0','1'],n=>({slot:int(n),state:atd?sim_state(n):'unknown'}))},
        boot:boot(),capabilities,
        conns:conntrack(),data_device:mobile,sim,update,vpn,traffic_summary,
        traffic:obj('/run/unisoc-modem-traffic/'+(traffic_slot=='1'?'sim1/':'')+'view.json')};
};

function ident_fix(o) {
    if(type(o)!='object')return o;
    let i=o.ident;
    if(type(i)=='object') {
        if(i.msisdn==null && o.msisdn!=null)i.msisdn=o.msisdn;
        if(i.msisdn_source==null && o.msisdn_src!=null)i.msisdn_source=o.msisdn_src;
        if(i.ts==null && o.ts!=null)i.ts=o.ts;
        if(i.boot_id==null)i.boot_id=rd('/proc/sys/kernel/random/boot_id') || null;
    }
    if(o.neigh_pending==null)o.neigh_pending=null;
    if(o.partial==null)o.partial=null;
    return o;
};
function age(path) { let s=fs.stat(ROOT+path); return s?.size>0?time()-s.mtime:-1; }
function owner(dir) {
    let pid=rd(dir+'/pid');
    return match(pid,/^[1-9][0-9]*$/) && exists('/proc/'+pid) &&
        !!match(join(' ',split(rd('/proc/'+pid+'/cmdline'),'\x00')),/unisoc-modem\/cell|mu300-modemd/);
};
export function status(slot,cells) {
    let c=cursor(CONFIG);
    if(!(slot in ['0','1']) || (slot=='1' && c.get('unisoc_modem','main','sim_slots')!='2'))return {error:'SIM 卡槽不可用'};
    // This platform has no slot-1 reader: no mu300-modemd, and /run/mu300-at4 is never created on an F50
    // (mu300-at answers slot-1 AT calls itself now). Asking for the second card answers the author's
    // empty-card shape - no cell, no signal, no ages, not refreshing - instead of starting a collector
    // that could only fail and flap. The snapshot (info) is still the normal one, as the author serves it.
    if(slot=='1' && fs.stat(ROOT+'/run/mu300-at4/cmd')==null)
        return {info:cells?null:info(slot),cell:null,sig:null,cell_age:-1,sig_age:-1,refreshing:0};
    let dir=RUN+(slot=='1'?'/sim1':''), cage=age(dir+'/cell.json'), sage=age(dir+'/sig.json');
    // A lock apply (SFUN restart) and a SIM switch both make the modem answer garbage:
    // the collectors stay off and the last snapshot is served.
    let busy=exists('/run/unisoc-modem-lock-apply') || exists('/run/mu300/sim-switching') ||
        exists('/run/mu300/sim-active-unknown') || owner(dir+'/collect.lck');
    let fast=busy || owner(dir+'/fast.lck'), failed=false;
    // a round that read nothing leaves a marker: do not kick again for a few seconds, serve what
    // the last good round cached and let the modem recover (the marker's age is the hold-off)
    let fm=fs.stat(dir+'/at-failed'), recentfail=fm!=null && (time()-fm.mtime)<5;
    let mode=cage<0 || cage>=5?'full':sage<0 || sage>=1?'fast':null;
    if(recentfail)mode=null;
    if(mode && !(mode=='full'?busy:fast)) {
        // This platform's collector: unisoc-modem/cell-kick [fast], detached. The wrapper takes
        // the single-flight lock without waiting, so overlapping status polls (the app polls
        // about once a second) drop their kick instead of stacking collectors on the AT channel.
        failed=!spawn('setsid /usr/libexec/unisoc-modem/cell-kick'+(mode=='fast'?' fast':''));
        // a kick was attempted: the caller refreshes, it does not see an error
        if(mode=='full')busy=true;
    }
    // a cache that exists is served even when the kick failed (its age says how old it is);
    // the error is only for a request that has neither a cache nor a working start
    // a cache holding the adapter's error is not data: never serve it as the snapshot
    let goodcache=o=>type(o)=='object' && o.error==null;
    let cell=obj(dir+'/cell.json'), sig=obj(dir+'/sig.json');
    if(!goodcache(cell))cell=null;
    if(!goodcache(sig))sig=null;
    return {info:cells?null:info(slot),
        cell:cell!=null?ident_fix(cell):failed?{error:'Unable to read cellular status'}:null,
        sig:sig!=null?sig:failed?{error:'Unable to read cellular status'}:null,
        cell_age:cage,sig_age:sage,refreshing:busy?1:0};
};

export function sms_head(slot) {
    let c=cursor(CONFIG);
    if(!(slot in ['0','1']) || (slot=='1' && c.get('unisoc_modem','main','sim_slots')!='2'))return {error:'SIM 卡槽不可用'};
    let cmd=c.get('unisoc_modem','main','sms_command') || '';
    // Adapter selection is explicit configuration. An external adapter owns
    // its format; never assume its records use the native pool layout.
    if(cmd && !match(cmd,/(^|\/)mu300-sms$/))return {adapter:true};
    let pool=rtrim(c.get('unisoc_modem','main','sms_pool') || '/etc/mu300/sms','/');
    if(pool=='/etc/unisoc-modem/sms')pool='/etc/mu300/sms';
    if(substr(pool,0,1)!='/' || match(pool,/[[:cntrl:]]/) || index(pool,'//')>=0 ||
       length(filter(split(pool,'/'),part=>part=='.' || part=='..')))
        return {error:'Invalid SMS pool'};
    if(slot=='1')pool+='/sim1';
    let s=fs.stat(ROOT+pool+'/msg');
    return {source:pool,next_id:num(rd(pool+'/next_id')),count:length(filter(fs.lsdir(ROOT+pool+'/msg') || [],f=>!!match(f,/^[0-9]+$/))),mtime:s?.mtime ?? null};
};
