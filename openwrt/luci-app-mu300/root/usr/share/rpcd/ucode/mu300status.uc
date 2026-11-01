// The snapshot provider the UFI panel polls (mu300status.status / .cells / .sysinfo), plus the SMS head it
// wants for the messages page.
//
// status and cells are the platform's own snapshot, served by mu300dash: the same collector LuCI's status page
// uses, with the stale-cache kick, the AT discipline, the single-instance locks and the response shape already in
// place (the panel's own recorded example has exactly this shape: info, cell, sig, their ages and refreshing).
// A second sampler here would double the AT burst and could disagree with the LuCI page; this file adds no AT
// access of its own and never reads the modem. cells is the same answer without the system info.
//
// sms_head is the local pool's head (the SMS store), a read-only file view. Its checks are the panel's own: an
// external SMS adapter owns its format, a pool path must be absolute and clean, and only a known pool is reported.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const DASH = getenv('MU300_STATUS_DASH') || '/usr/libexec/rpcd/mu300dash';

// Every slot argument is a string on the wire; absent means the platform default (slot 0).
function slot_name(slot) { return slot == null ? '' : '' + slot; }

function slot_usable(slot) {
	if (!(slot in ['', '0', '1']))
		return false;
	if (slot != '1')
		return true;
	return cursor().get('unisoc_modem', 'main', 'sim_slots') == '2';
}

// mu300dash answers one JSON line on stdout. It is a script, not an RPC: running it directly (not through ubus)
// avoids asking rpcd about itself from inside rpcd, and keeps this object's answer identical to the LuCI page's.
// Its own failure (the runtime directory refused, the collector killed) arrives as its error object, which is
// the honest answer here too: the panel shows it rather than an empty snapshot.
function snapshot() {
	let p = fs.popen(DASH + ' call status', 'r');
	if (!p)
		return null;
	let out = trim(p.read('all') || '');
	p.close();
	if (!length(out))
		return null;
	try {
		let r = json(out);
		return type(r) == 'object' ? r : null;
	} catch (e) {
		return null;
	}
}

function status(slot) {
	slot = slot_name(slot);
	if (!slot_usable(slot))
		return { error: 'SIM 卡槽不可用' };
	let r = snapshot();
	if (r == null)
		return { error: 'The status collector gave no answer' };
	return r;
}

function sms_head(slot) {
	slot = slot_name(slot);
	if (!slot_usable(slot))
		return { error: 'SIM 卡槽不可用' };
	let c = cursor();
	let cmd = c.get('unisoc_modem', 'main', 'sms_command') || '';
	// Adapter selection is explicit configuration. An external adapter owns
	// its format; never assume its records use the native pool layout.
	if (cmd && !match(cmd, /(^|\/)mu300-sms$/))
		return { adapter: true };
	let pool = rtrim(c.get('unisoc_modem', 'main', 'sms_pool') || '/etc/mu300/sms', '/');
	if (pool == '/etc/unisoc-modem/sms')
		pool = '/etc/mu300/sms';
	if (substr(pool, 0, 1) != '/' || match(pool, /[[:cntrl:]]/) || index(pool, '//') >= 0 ||
	    length(filter(split(pool, '/'), part => part == '.' || part == '..')))
		return { error: 'Invalid SMS pool' };
	if (slot == '1')
		pool += '/sim1';
	let s = fs.stat(pool + '/msg');
	let next = trim(fs.readfile(pool + '/next_id') || '');
	return {
		source: pool,
		next_id: match(next, /^[0-9]+$/) ? +next : null,
		count: length(filter(fs.lsdir(pool + '/msg') || [], f => !!match(f, /^[0-9]+$/))),
		mtime: s != null ? s.mtime : null
	};
}

return {
	mu300status: {
		status: { args: { slot: '' }, call: (req) => status(req.args.slot) },
		cells: {
			args: { slot: '' },
			call: (req) => {
				let r = status(req.args.slot);
				if (type(r) == 'object' && 'info' in r)
					r.info = null;
				return r;
			}
		},
		// The first paint's snapshot: the same info object, without the cellular cache.
		sysinfo: { call: () => { let r = status(''); return (type(r) == 'object' && type(r.info) == 'object') ? r.info : {}; } },
		sms_head: { args: { slot: '' }, call: (req) => sms_head(req.args.slot) }
	}
};
