'use strict';
// Loads web/dc-powersave.js into a vm context with minimal Ext/PVE stubs.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SOURCE = path.join(__dirname, '..', 'dc-powersave.js');

function load(options = {}) {
    const warnings = [];
    const alerts = [];
    const ajax = [];
    const defined = {};
    let initCalls = 0;

    function Config() {}
    Config.prototype.initComponent = function () { initCalls++; return 'original'; };
    Config.override = function (members) { Object.assign(Config.prototype, members); };

    const PVE = options.PVE || { panel: { Config }, dc: {} };
    if (PVE.panel && PVE.panel.Config === undefined && options.withConfig) { PVE.panel.Config = Config; }
    if (options.datacenterConfig) {
        PVE.dc = PVE.dc || {};
        PVE.dc.Config = function DatacenterConfig() { this.items = []; };
        PVE.dc.Config.prototype = Object.create(Config.prototype);
    }

    const Ext = {
        apply(target, source) { return Object.assign(target, source); },
        decode(text) { return JSON.parse(text); },
        define(name, config) { defined[name] = config; },
        create(cls, config) { return Object.assign({ xtype: cls }, config); },
        defer(fn) { fn(); },
        String: { htmlEncode(value) { return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); } },
        JSON: { encode: JSON.stringify },
        Msg: { alert(title, message) { alerts.push({ title, message }); } },
        Ajax: { request(opts) { ajax.push(opts); } },
        TaskManager: { start() { return {}; }, stop() {} },
        state: { Manager: { get(key) { return key === 'GuiCap' ? options.guiCap : undefined; } } },
    };
    const context = {
        Ext, PVE, Proxmox: { CSRFPreventionToken: 'token' },
        console: { warn(...args) { warnings.push(args); } },
        gettext(text) { return text; },
    };
    vm.runInNewContext(fs.readFileSync(SOURCE, 'utf8'), context, { filename: SOURCE });
    return {
        PVE, Ext, Config, defined, warnings, alerts, ajax,
        get initCalls() { return initCalls; },
        ns: PVE.DCPowerSave,
        panel: defined['PVE.dc.PowerManagement'],
    };
}

// A stand-in for a PowerManagement panel instance: the real prototype
// methods on top of recording stubs.
function fakePanel(env, extra = {}) {
    const rows = [];
    const panel = Object.create(env.panel);
    Object.assign(panel, {
        rows,
        statusStore: { removeAll() { rows.length = 0; }, add(row) { rows.push(row); }, each(fn) { rows.forEach((row) => fn({ get: (k) => row[k] })); } },
        statusInfo: { text: '', setText(text) { this.text = text; } },
        destroyed: false,
    }, extra);
    return panel;
}

module.exports = { load, fakePanel };
