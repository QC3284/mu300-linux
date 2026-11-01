import * as info from 'mu300.info';
// The panel's status objects, as the author's firmware serves them: status, cells,
// sysinfo (the first-paint snapshot) and sms_head. The snapshot itself is mu300.info
// (a port of the author's dash.uc) reading THIS platform's collectors and caches.
return {mu300status:{
    status:{args:{slot:''},call:(req)=>info.status(req.args.slot,false)},
    cells:{args:{slot:''},call:(req)=>info.status(req.args.slot,true)},
    sysinfo:{call:()=>info.info(null)},
    sms_head:{args:{slot:''},call:(req)=>info.sms_head(req.args.slot)}
}};
