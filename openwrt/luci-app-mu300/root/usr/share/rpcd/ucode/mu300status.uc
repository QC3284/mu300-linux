// The panel's status object (the author firmware's rpcd provider): the dashboard
// snapshot (info.uc), the cellular caches with their ages, and the SMS pool head.
// The dashboard polls this every ~1.5 s; building the snapshot walks /sys, uci and
// ubus, so the answer is held for TTL seconds in /run when a page and the external
// panel ask together. No AT access here (the collectors are kicked by mu300dash).
import * as fs from 'fs';
import * as info from 'mu300.info';

const RUN = getenv('MU300_PANEL_RUN') || '/run/mu300';
const TTL = +(getenv('MU300_PANEL_STATUS_TTL') || '1.5');
// the author's provider defaults an absent slot to the first card
function asked_slot(v) { return (v == null || v === '') ? '0' : '' + v; };
function cache_path(slot, cells) { return RUN + '/panel-status-' + slot + (cells ? '-cells' : '') + '.json'; };
function cached(path, build) {
    let stamp = fs.stat(path);
    if (stamp != null && stamp.size > 0) {
        let age = time() - stamp.mtime;
        if (age >= 0 && age < TTL) {
            try { let hit = json(fs.readfile(path)); if (type(hit) == 'object') return hit; } catch(e) {}
        }
    }
    let value = build();
    if (value == null) return null;
    if (fs.stat(RUN) == null) fs.mkdir(RUN, 448);
    try {
        if (fs.writefile(path + '.new', sprintf('%J
', value)) != null)
            fs.rename(path + '.new', path);
    } catch(e) {}
    return value;
};
function status(slot, cells) {
    slot = asked_slot(slot);
    return cached(cache_path(slot, cells), () => info.status(slot, !!cells));
};
return {mu300status:{
    status:{args:{slot:''},call:(req)=>status(req.args.slot,false)},
    cells:{args:{slot:''},call:(req)=>status(req.args.slot,true)},
    sysinfo:{call:()=>info.info(null)},
    sms_head:{args:{slot:''},call:(req)=>info.sms_head(asked_slot(req.args.slot))}
}};
