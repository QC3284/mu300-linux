'use strict';
'require baseclass';
'require rpc';
'require mu300.common as M';

var get = rpc.declare({object:'mu300dash',method:'sim_radio_get',nobatch:true,expect:{'':{}}});
var set = rpc.declare({object:'mu300dash',method:'sim_radio_set',params:['slot','enabled','confirm'],nobatch:true,expect:{'':{}}});
var status = rpc.declare({object:'mu300dash',method:'sim_radio_status',params:['id'],nobatch:true,expect:{'':{}}});
function errorMessage(error) {
    return M.translate(error.message||String(error));
}

// Shared by the SIM page and home quick control. A submission receipt is
// not proof that RF changed; only the final job result releases the button.
function wait(job, active) {
    if (!job || !job.ok || !job.id) return Promise.reject(new Error(job && job.error || 'Submission failed'));
    var deadline=Date.now()+360000;
    return new Promise(function(resolve,reject) {
        function watch() {
            if(active && !active()){resolve(null);return;}
            if(Date.now()>deadline){reject(new Error(M.translate('Apply timed out: refresh to confirm the modem state')));return;}
            status(job.id).then(function(r) {
                if(active && !active()){resolve(null);return;}
                if(r && r.ok && r.state==='done')resolve(r);
                else if(!r || !['queued','running'].includes(r.state))reject(new Error(r && r.error || 'Could not read the job result'));
                else setTimeout(watch,1000);
            }).catch(function(){setTimeout(watch,1000);});
        }
        watch();
    });
}

function attach(root) {
    var disposed=false, pending=false, flags=null, supported=[true,true], readRevision=0;
    root.innerHTML='<h3></h3><p class="mud-note"></p><div data-radios></div><p role="status" aria-live="polite"></p>';
    root.querySelector('h3').textContent=M.translate('SIM radio');
    root.querySelector('.mud-note').textContent=M.translate('Control the radio of each card separately and remember the setting. With its radio off a card cannot call, message or use data; the other card is not switched to automatically.');
    var buttons=[], result=root.querySelector('[role=status]'), rows=root.querySelector('[data-radios]');
    rows.style.cssText='display:grid;gap:12px;margin:16px 0';
    [0,1].forEach(function(slot) {
        var row=document.createElement('div'), label=document.createElement('span'), b=document.createElement('button');
        row.style.cssText='display:flex;align-items:center;justify-content:space-between;gap:16px';
        label.textContent='SIM '+(slot+1); b.type='button'; b.className='mud-btn'; b.setAttribute('role','switch'); b.setAttribute('aria-label','SIM '+(slot+1)+' '+M.translate('radio'));
        row.append(label,b); rows.append(row); buttons.push(b);
        b.onclick=function() {
            if(pending||!flags)return;
            var enabled=!flags[slot]; readRevision++; pending=true; paint();
            M.confirmBox('SIM '+(slot+1)+' - '+M.translate(enabled?'Enable radio':'Disable radio'), M.translate('The setting is kept after a reboot. Turning off the card in use cuts the cellular network.')).then(function(yes) {
                if(disposed)return;
                if(!yes){pending=false;paint();return;}
                result.textContent=M.translate('Applying the radio setting...');
                return set(String(slot),enabled,true).then(function(job) {
                    if(!job||!job.ok)throw new Error(job&&job.error||'Submission failed');
                    return wait(job,function(){return !disposed;}).then(function(){finish();},finish);
                });
            }).catch(finish);
        };
    });
    function paint() {
        buttons.forEach(function(b,i){ b.disabled=pending||!flags||supported[i]===false;
            b.textContent=flags&&supported[i]!==false?M.translate(flags[i]?'Enabled':'Disabled'):'--';
            b.setAttribute('aria-checked',String(!!(flags&&flags[i]&&supported[i]!==false)));
            b.classList.toggle('on',!!(flags&&flags[i]&&supported[i]!==false)); });
    }
    function refresh() {
        if(disposed||pending||document.hidden)return Promise.resolve();
        var revision=++readRevision;
        return get().then(function(r){if(disposed||pending||revision!==readRevision)return;flags=r&&r.ok&&Array.isArray(r.enabled)?r.enabled:null;supported=r&&Array.isArray(r.supported)?r.supported:[true,true];paint();}).catch(function(){if(!disposed&&!pending&&revision===readRevision){flags=null;paint();}});
    }
    function finish(error) {
        if(disposed)return;
        pending=false;
        result.textContent=error?errorMessage(error):M.translate('Radio setting applied and saved');
        result.style.color=error?'var(--danger,#dc3545)':'';
        refresh();
    }
    paint();refresh();
    return {refresh:refresh,dispose:function(){disposed=true;}};
}
return baseclass.extend({attach:attach,wait:wait});
