// Global TCP policy only. No AT, interface restart, live qdisc replacement or daemon.
import * as fs from 'fs';
const ROOT=getenv('UNISOC_NET_ROOT') || '';
const CONFIG=ROOT+'/etc/unisoc-network-performance.json';
const BASE=ROOT+'/run/unisoc-network-performance-defaults.json';
const SYS=ROOT+'/proc/sys/';
const CC='net/ipv4/tcp_congestion_control', QDISC='net/core/default_qdisc';
function read(path) { return trim(fs.readfile(path) ?? ''); }
function token(v) { return type(v)=='string' && !!match(v,/^[a-z][a-z0-9_]{0,31}$/); }
function store(path,value) {
    let text=sprintf('%J\n',value), temp=path+'.new';
    if(fs.writefile(temp,text)==length(text) && fs.chmod(temp,384) && fs.rename(temp,path))return true;
    fs.unlink(temp);return false;
}
function profile() {
    if(!fs.stat(CONFIG))return null;
    let p=json(fs.readfile(CONFIG));
    if(p?.version!=1 || length(keys(p))!=2 || index(['default','cubic','bbr'],p.algorithm)<0)die('network_invalid');
    return p;
}
function snapshot() { return {algorithm:read(SYS+CC),qdisc:read(SYS+QDISC)}; }
function defaults(capture) {
    let boot=read(ROOT+'/proc/sys/kernel/random/boot_id'), d=null;
    try { d=json(fs.readfile(BASE) || 'null'); } catch(e) {}
    if(boot && d?.boot==boot && token(d.algorithm) && token(d.qdisc))return d;
    let current=snapshot();
    if(!capture)return current;
    if(!boot || !token(current.algorithm) || !token(current.qdisc))die('network_read_failed');
    d={boot,algorithm:current.algorithm,qdisc:current.qdisc};
    if(!store(BASE,d))die('network_save_failed');
    return d;
}
function available() { return filter(split(read(SYS+'net/ipv4/tcp_available_congestion_control'),/\s+/),v=>token(v)); }
function status() {
    let s=snapshot(), p=profile();
    return {ok:true,supported:token(s.algorithm) && token(s.qdisc),available:available(),
        current:s.algorithm,qdisc:s.qdisc,selection:p?.algorithm || 'default',defaults:defaults(false)};
}
function write(key,value) {
    if(read(SYS+key)==value)return true;
    return fs.writefile(SYS+key,value+'\n')==length(value)+1 && read(SYS+key)==value;
}
function restore(old) {
    let a=write(CC,old.algorithm), q=write(QDISC,old.qdisc);
    return a && q;
}
try {
    let action=ARGV[0] || 'get';
    if(action=='get') { print(sprintf('%J\n',status()));exit(0); }
    if(action!='apply' && action!='boot')die('network_invalid');
    let saved=profile(), wanted;
    if(action=='boot') {
        defaults(true);
        if(!saved) { print('{"ok":true,"skipped":true}\n');exit(0); }
        wanted=saved.algorithm;
    } else {
        let request=json(fs.readfile('/dev/stdin') || '{}');
        if(type(request)!='object')die('network_invalid');
        delete request.ubus_rpc_session;
        if(length(keys(request))!=1 || index(['default','cubic','bbr'],request.algorithm)<0)die('network_invalid');
        wanted=request.algorithm;
    }
    let base=defaults(true), old=snapshot();
    let algorithm=wanted=='default'?base.algorithm:wanted, qdisc=wanted=='bbr'?'fq':base.qdisc;
    if(index(available(),algorithm)<0)die('network_unsupported');
    // The kernel resolves sch_fq through its normal module loader. This only
    // changes the default for newly created interfaces; existing QoS is untouched.
    let error=null;
    if(!write(QDISC,qdisc) || !write(CC,algorithm))error='network_apply_failed';
    if(!error && action=='apply') {
        if(wanted=='default') {
            if(fs.stat(CONFIG) && !fs.unlink(CONFIG))error='network_save_failed';
        } else if(!store(CONFIG,{version:1,algorithm:wanted}))error='network_save_failed';
    }
    if(error) { print(sprintf('%J\n',{ok:false,error,rollback:restore(old)}));exit(1); }
    print(sprintf('%J\n',status()));
} catch(e) { print(sprintf('%J\n',{ok:false,error:replace(''+e,/\n.*/, '')}));exit(1); }
