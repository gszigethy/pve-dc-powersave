'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { load, fakePanel } = require('./harness.js');

const ALL_CAPS = { dc: { 'Sys.Audit': 1, 'Sys.Modify': 1 } };


// ---- finding: the initComponent override must never break other panels ------

test('override: PVE.dc undefined -> no throw, original called exactly once', () => {
    const env = load({ PVE: { panel: {} }, withConfig: true, guiCap: ALL_CAPS });
    const panel = new env.Config();
    assert.doesNotThrow(() => panel.initComponent());
    assert.strictEqual(env.initCalls, 1);
});

test('override: PVE.dc without Config -> no throw, original called exactly once', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = new env.Config();
    assert.doesNotThrow(() => panel.initComponent());
    assert.strictEqual(env.initCalls, 1);
    assert.strictEqual(env.warnings.length, 0);
});

test('override: PVE.dc.Config that is not a constructor -> warn, original once', () => {
    const env = load({ guiCap: ALL_CAPS });
    env.PVE.dc.Config = {};
    const panel = new env.Config();
    assert.doesNotThrow(() => panel.initComponent());
    assert.strictEqual(env.initCalls, 1);
    assert.strictEqual(env.warnings.length, 1);
});

test('override: missing GuiCap or caps -> no throw, no card, original once', () => {
    for (const guiCap of [undefined, {}, { dc: null }, { dc: {} }]) {
        const env = load({ guiCap, datacenterConfig: true });
        const panel = new env.PVE.dc.Config();
        assert.doesNotThrow(() => panel.initComponent());
        assert.strictEqual(env.initCalls, 1);
        assert.strictEqual(panel.items.length, 0);
    }
});

test('override: datacenter panel with Sys.Audit gets the card, original once', () => {
    const env = load({ guiCap: ALL_CAPS, datacenterConfig: true });
    const panel = new env.PVE.dc.Config();
    assert.strictEqual(panel.initComponent(), 'original');
    assert.strictEqual(env.initCalls, 1);
    assert.strictEqual(panel.items.length, 1);
    assert.strictEqual(panel.items[0].xtype, 'pveDcPowerManagement');
    assert.strictEqual(panel.items[0].itemId, 'power-management');
});

test('override: other config panels are untouched', () => {
    const env = load({ guiCap: ALL_CAPS, datacenterConfig: true });
    const panel = new env.Config();
    panel.items = [];
    panel.initComponent();
    assert.strictEqual(env.initCalls, 1);
    assert.deepStrictEqual(panel.items, []);
});

test('override: items that are not an array -> warn, original once', () => {
    const env = load({ guiCap: ALL_CAPS, datacenterConfig: true });
    const panel = new env.PVE.dc.Config();
    panel.items = undefined;
    assert.doesNotThrow(() => panel.initComponent());
    assert.strictEqual(env.initCalls, 1);
    assert.strictEqual(env.warnings.length, 1);
});

test('override: PVE.panel.Config missing -> the file still loads', () => {
    const env = load({ PVE: {}, guiCap: ALL_CAPS });
    assert.strictEqual(env.warnings.length, 1);
    assert.ok(env.panel, 'the panel class is still defined');
});

test('override: an error from the original propagates untouched', () => {
    const env = load({ guiCap: ALL_CAPS });
    env.Config.prototype.initComponent = function () { throw new Error('boom'); };
    // the override captured the original at load time, so call the wrapper directly
    const wrapped = env.ns.wrapConfigInit(env.Config.prototype.initComponent);
    assert.throws(() => wrapped.call(new env.Config()), /boom/);
});

// ---- finding: 501 means the plugin is not installed ---------------------------

test('node failure: 501 and 404 map to plugin_not_installed with an installer hint', () => {
    const env = load({ guiCap: ALL_CAPS });
    for (const status of [501, 404]) {
        const row = env.ns.nodeFailure({ status, statusText: 'Not Implemented' });
        assert.strictEqual(row.reason, 'plugin_not_installed');
        assert.match(row.last_error, /Rerun the installer on this node/);
    }
});

test('node failure: other failures stay status_unavailable', () => {
    const env = load({ guiCap: ALL_CAPS });
    for (const status of [500, 401, 596, 0, undefined]) {
        const row = env.ns.nodeFailure({ status, statusText: 'oops' });
        assert.strictEqual(row.reason, 'status_unavailable');
        assert.strictEqual(row.last_error, 'oops');
    }
});

test('loadStatus: a node answering 501 is listed as plugin_not_installed', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = fakePanel(env);
    panel.loadStatus();
    env.ajax[0].success({ responseText: JSON.stringify({ data: [{ type: 'node', name: 'pve02', online: 1 }] }) });
    assert.match(env.ajax[1].url, /nodes\/pve02\/power-management$/);
    env.ajax[1].failure({ status: 501, statusText: 'Not Implemented' });
    assert.strictEqual(panel.rows.length, 1);
    assert.strictEqual(panel.rows[0].node, 'pve02');
    assert.strictEqual(panel.rows[0].reason, 'plugin_not_installed');
    assert.strictEqual(env.alerts.length, 0);
});

// ---- finding: background failures are inline ----------------------------------

test('loadStatus: a failed refresh shows inline, never in a dialog, and clears on success', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = fakePanel(env);
    panel.loadStatus();
    env.ajax[0].failure({ status: 401, statusText: 'No ticket', responseText: '' });
    assert.strictEqual(env.alerts.length, 0, 'no modal alert');
    assert.match(panel.statusInfo.text, /Status refresh failed: HTTP 401: No ticket/);

    // the same failure every 15 s must not accumulate dialogs either
    panel.loadStatus();
    env.ajax[1].failure({ status: 401, statusText: 'No ticket', responseText: '' });
    assert.strictEqual(env.alerts.length, 0);

    panel.loadStatus();
    env.ajax[2].success({ responseText: JSON.stringify({ data: [] }) });
    assert.doesNotMatch(panel.statusInfo.text, /failed/);
});

test('loadStatus: the failure text is HTML-escaped', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = fakePanel(env);
    panel.loadStatus();
    env.ajax[0].failure({ status: 500, statusText: 'x', responseText: JSON.stringify({ message: '<img src=x>' }) });
    assert.doesNotMatch(panel.statusInfo.text, /<img/);
});

test('loadStatus: replies after destroy are ignored', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = fakePanel(env);
    panel.loadStatus();
    panel.destroyed = true;
    env.ajax[0].failure({ status: 500, statusText: 'late' });
    assert.strictEqual(panel.statusInfo.text, '');
    env.ajax[0].success({ responseText: JSON.stringify({ data: [{ type: 'node', name: 'a', online: 0 }] }) });
    assert.strictEqual(panel.rows.length, 0);
});

test('loadStatus: only the newest sweep writes rows', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = fakePanel(env);
    panel.loadStatus();
    panel.loadStatus();
    const reply = { responseText: JSON.stringify({ data: [{ type: 'node', name: 'a', online: 0 }] }) };
    env.ajax[0].success(reply);
    assert.strictEqual(panel.rows.length, 0);
    env.ajax[1].success(reply);
    assert.strictEqual(panel.rows.length, 1);
});

test('loadCapabilities: callbacks check for a destroyed panel', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = fakePanel(env, {
        commonGovernorStore: { loadData() { throw new Error('touched a destroyed panel'); }, removeAll() { throw new Error('touched'); } },
    });
    panel.loadCapabilities();
    panel.isDestroyed = true;
    assert.doesNotThrow(() => env.ajax[0].success({ responseText: JSON.stringify({ data: { common_governors: [] } }) }));
    assert.strictEqual(panel.capabilitiesLoading, false);
    panel.capabilitiesLoading = false;
    panel.loadCapabilities();
    assert.doesNotThrow(() => env.ajax[1].failure({ status: 500 }));
});

// ---- finding: Reconcile needs Sys.Modify ----------------------------------------

test('reconcile: no request without Sys.Modify', () => {
    const env = load({ guiCap: { dc: { 'Sys.Audit': 1 } } });
    const panel = fakePanel(env);
    panel.reconcileNode('pve01');
    assert.strictEqual(env.ajax.length, 0);
    assert.strictEqual(env.ns.hasCap('Sys.Modify'), false);
});

test('reconcile: with Sys.Modify the request is posted', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = fakePanel(env);
    panel.reconcileNode('pve01');
    assert.strictEqual(env.ajax.length, 1);
    assert.strictEqual(env.ajax[0].method, 'POST');
    assert.match(env.ajax[0].url, /nodes\/pve01\/power-management\/reconcile$/);
});

test('reconcile all: one status reload after all nodes were asked', () => {
    const env = load({ guiCap: ALL_CAPS });
    const panel = fakePanel(env);
    panel.rows.push({ node: 'a' }, { node: 'b' }, { node: 'c', reason: 'node_offline' });
    let reloads = 0;
    panel.loadStatus = function () { reloads++; };
    panel.reconcileAll();
    assert.strictEqual(env.ajax.length, 2, 'offline nodes are skipped');
    env.ajax[0].success();
    assert.strictEqual(reloads, 0);
    env.ajax[1].success();
    assert.strictEqual(reloads, 1);
});

// ---- save planning and the governor key list -------------------------------------

test('governor keys are defined once', () => {
    const env = load({ guiCap: ALL_CAPS });
    assert.deepStrictEqual(Array.from(env.ns.GOVERNOR_KEYS),
        ['active_governor', 'idle_governor', 'migration_governor', 'failsafe_governor']);
    const source = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'dc-powersave.js'), 'utf8');
    assert.strictEqual((source.match(/'failsafe_governor'/g) || []).length, 2, 'once in the list, once in the field definitions');
});

const loaded = { enabled: '1', active_governor: 'performance', idle_governor: 'powersave',
    migration_governor: 'performance', failsafe_governor: 'performance', reconciliation_interval: '30' };
const incomplete = { complete: false, common_governors: [] };
const complete = { complete: true, common_governors: ['performance', 'powersave'] };

test('planSave: an interval change on an enabled policy needs no capabilities', () => {
    const env = load({ guiCap: ALL_CAPS });
    const plan = env.ns.planSave({ enabled: true, reconciliation_interval: 60 }, loaded, incomplete);
    assert.strictEqual(plan.error, null);
    assert.strictEqual(plan.needsCheck, false);
    assert.strictEqual(plan.values.idle_governor, 'powersave', 'blank governors keep their stored value');
});

test('planSave: enabling or changing a governor needs complete capabilities', () => {
    const env = load({ guiCap: ALL_CAPS });
    const off = Object.assign({}, loaded, { enabled: '0' });
    assert.match(env.ns.planSave({ enabled: true }, off, incomplete).error, /Every node must report/);
    assert.match(env.ns.planSave({ enabled: true, idle_governor: 'schedutil' }, loaded, incomplete).error, /Every node must report/);
    assert.match(env.ns.planSave({ enabled: true }, off, { complete: true, common_governors: [] }).error, /No common CPU governor/);
    assert.strictEqual(env.ns.planSave({ enabled: true }, off, complete).error, null);
    assert.strictEqual(env.ns.planSave({ enabled: true }, undefined, undefined).needsCheck, true);
});

test('planSave: disabling never needs capabilities', () => {
    const env = load({ guiCap: ALL_CAPS });
    const plan = env.ns.planSave({}, loaded, undefined);
    assert.strictEqual(plan.error, null);
    assert.strictEqual(plan.values.enabled, 0);
    assert.strictEqual(plan.needsCheck, false);
});

test('planSave: an unusable stored configuration counts as not enabled', () => {
    const env = load({ guiCap: ALL_CAPS });
    const plan = env.ns.planSave({ enabled: true }, Object.assign({ configuration_error: 'bad' }, loaded), incomplete);
    assert.strictEqual(plan.needsCheck, true);
});
