// CPU0 deep idle on UMS9620 (T157/T760). WFI and other CPUs are untouched.
import * as fs from 'fs';
const ROOT=getenv('UNISOC_IDLE_ROOT') || '';
const CONFIG=getenv('UNISOC_IDLE_CONFIG') || ROOT+'/etc/unisoc-cpu-idle.json';
function read(p) { return trim(fs.readfile(p) ?? ''); }
function states() {
    let compat=split(fs.readfile(ROOT+'/sys/firmware/devicetree/base/compatible') ?? '', '\x00');
    if(index(compat,'sprd,ums9620')<0) return [];
    let base=ROOT+'/sys/devices/system/cpu/cpu0/cpuidle', out=[];
    for(let id in sort(fs.lsdir(base) || [])) {
        if(!match(id,/^state[0-9]+$/))continue;
        let path=base+'/'+id, name=read(path+'/name'), value=read(path+'/disable');
        if(name!='cluster-pd' && !match(name,/^core-sleep-/))continue;
        if(value!='0' && value!='1')die('无法读取 CPU0 深度休眠状态');
        push(out,{id,name,disabled:value=='1',path:path+'/disable'});
    }
    return out;
}
function profile() {
    if(!fs.stat(CONFIG))return null;
    let v=json(fs.readfile(CONFIG));
    if(v?.version!=1 || type(v.enabled)!='bool' || length(keys(v))!=2)die('CPU0 深度休眠配置无效');
    return v;
}
function status(nodes) {
    if(!length(nodes))return {ok:true,supported:false,enabled:false,mixed:false,states:[]};
    let p=profile(), enabled=length(filter(nodes,n=>!n.disabled));
    return {ok:true,supported:!!length(nodes),enabled:!!length(nodes) && enabled==length(nodes),
        mixed:enabled>0 && enabled<length(nodes),saved:p?.enabled,
        states:map(nodes,n=>({id:n.id,name:n.name,disabled:n.disabled}))};
}
function write_nodes(nodes, enabled) {
    let value=enabled?'0':'1';
    for(let n in nodes) {
        if(read(n.path)==value)continue;
        if(fs.writefile(n.path,value+'\n')==null || read(n.path)!=value)return false;
    }
    return true;
}
function restore(nodes) {
    let ok=true;
    for(let n in nodes) {
        let value=n.disabled?'1':'0';
        if(read(n.path)!=value && (fs.writefile(n.path,value+'\n')==null || read(n.path)!=value))ok=false;
    }
    return ok;
}
function save(enabled) {
    let tmp=CONFIG+'.new', text=sprintf('%J\n',{version:1,enabled});
    if(fs.writefile(tmp,text)==length(text) && fs.chmod(tmp,384) && fs.rename(tmp,CONFIG))return true;
    fs.unlink(tmp);return false;
}
try {
    let action=ARGV[0] || 'get', nodes=states();
    if(action=='get')print(sprintf('%J\n',status(nodes)));
    else if(action=='boot' || action=='apply') {
        let enabled;
        if(action=='boot') {
            let p=profile();
            if(!p || !length(nodes)) {print('{"ok":true,"skipped":true}\n');exit(0);}
            enabled=p.enabled;
        } else {
            let request=json(fs.readfile('/dev/stdin') || '{}');
            delete request.ubus_rpc_session;
            if(type(request.enabled)!='bool' || length(keys(request))!=1)die('CPU0 深度休眠请求无效');
            if(!length(nodes))die('此平台不提供 CPU0 深度休眠开关');
            enabled=request.enabled;
        }
        // Validate any saved file before changing hardware.
        profile();
        if(!write_nodes(nodes,enabled)) {
            print(sprintf('%J\n',{ok:false,error:'内核未接受 CPU0 深度休眠设置',rollback:restore(nodes)}));exit(1);
        }
        if(action=='apply' && !save(enabled)) {
            print(sprintf('%J\n',{ok:false,error:'无法保存 CPU0 深度休眠设置',rollback:restore(nodes)}));exit(1);
        }
        print(sprintf('%J\n',status(states())));
    } else die('CPU0 深度休眠操作无效');
} catch(e) {print(sprintf('%J\n',{ok:false,error:replace(''+e,/\n.*/, '')}));exit(1);}
