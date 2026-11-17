#!/usr/bin/env ucode
// Firmware update check of the Archer A5 v4 / C50 v4 build: the LuCI page System -> Archer A5 v4
// / C50 v4 build updates and the notice on the Overview page. The check and the download run in
// the background (/usr/libexec/fwupdate); the page polls status.

'use strict';

import { readfile, stat, access, unlink } from 'fs';
import { cursor } from 'uci';

const DIR = '/tmp/fwupdate';
const IMAGE = DIR + '/firmware.bin';
const CHECKING = DIR + '/checking';
// a check or a download that has not finished after this long has died; the script keeps the
// time of a download below it (DOWNLOAD_TIME in /usr/libexec/fwupdate)
const STALE = 900;

function read_json(file) {
	const s = readfile(file);
	if (s == null)
		return null;
	try {
		return json(s);
	}
	catch (e) {
		return null;
	}
}

function installed() {
	const s = readfile('/etc/a5v4_release') || '';
	const get = (k) => {
		const m = match(s, regexp('(^|\n)' + k + "='([^']*)'"));
		return m ? m[2] : '';
	};
	return { release: get('RELEASE'), commit: get('COMMIT') };
}

// the shell returns at once and leaves cmd running on its own
function background(cmd) {
	system('(' + cmd + ') </dev/null >/dev/null 2>&1 &');
}

function running(file) {
	const s = stat(file);
	return s != null && time() - s.mtime < STALE;
}

function downloading() {
	const dl = read_json(DIR + '/download.json');
	return dl && dl.state == 'downloading' && time() - dl.started < STALE;
}

function status() {
	const c = cursor();
	const dl = read_json(DIR + '/download.json');
	if (dl && dl.state == 'downloading') {
		const s = stat(DIR + '/firmware.part');
		dl.done = s ? s.size : 0;
		if (time() - dl.started >= STALE)
			dl.state = 'error', dl.error = 'stalled';
	}
	return {
		installed: installed(),
		status: read_json(DIR + '/status.json'),
		download: dl,
		checking: running(CHECKING),
		settings: {
			enabled: c.get('fwupdate', 'settings', 'enabled') != '0',
			notify: c.get('fwupdate', 'settings', 'notify') != '0',
			skip: c.get('fwupdate', 'settings', 'skip') || ''
		}
	};
}

// What the notice on the Overview page shows, on every refresh of that page: it reads the status
// file, and the settings only when a newer release is out. Empty when there is nothing to show.
function notice() {
	const st = read_json(DIR + '/status.json');
	if (!st || !st.update || type(st.latest) != 'object')
		return {};
	const c = cursor();
	if (c.get('fwupdate', 'settings', 'notify') == '0' || c.get('fwupdate', 'settings', 'skip') == st.latest.tag)
		return {};
	return { tag: st.latest.tag, method: st.method, releases: st.releases };
}

function check() {
	if (running(CHECKING))
		return { result: 'busy' };
	system('mkdir -p ' + DIR + ' && touch ' + CHECKING);
	background('/usr/libexec/fwupdate check; rm -f ' + CHECKING);
	return { result: 'started' };
}

function download() {
	if (downloading())
		return { result: 'busy' };
	const st = read_json(DIR + '/status.json');
	if (!st || !st.latest)
		return { error: 'no_release' };
	if (st.method == 'manual')
		return { error: 'manual' };
	background('/usr/libexec/fwupdate download');
	return { result: 'started' };
}

function upgrade(keep) {
	const st = read_json(DIR + '/status.json');
	const dl = read_json(DIR + '/download.json');

	if (!st || !st.latest || !dl || dl.state != 'ready' || dl.tag != st.latest.tag ||
	    dl.sha256 != st.latest.sysupgrade.sha256 || !access(IMAGE))
		return { error: 'not_ready' };
	if (st.method == 'manual')
		return { error: 'manual' };

	keep = keep && st.method != 'reset' && dl.allow_backup;
	// sysupgrade does not return: start it after the reply has been sent
	background('sleep 1; exec /sbin/sysupgrade ' + (keep ? '' : '-n ') + IMAGE);
	return { result: 'ok', keep: keep };
}

function skip(tag) {
	const c = cursor();
	c.set('fwupdate', 'settings', 'skip', (type(tag) == 'string') ? tag : '');
	c.commit('fwupdate');
	return { result: 'ok' };
}

// the downloaded image takes its size of the RAM until it is installed
function discard() {
	if (downloading())
		return { result: 'busy' };
	unlink(IMAGE);
	unlink(DIR + '/firmware.part');
	unlink(DIR + '/download.json');
	return { result: 'ok' };
}

const methods = {
	status: { call: () => status() },
	notice: { call: () => notice() },
	check: { call: () => check() },
	download: { call: () => download() },
	discard: { call: () => discard() },
	upgrade: {
		args: { keep: false },
		call: (req) => upgrade(req.args.keep ? true : false)
	},
	skip: {
		args: { tag: '' },
		call: (req) => skip(req.args.tag)
	}
};

return { 'luci.fwupdate': methods };
