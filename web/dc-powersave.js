/* Datacenter -> Power Management. Loaded after pvemanagerlib.js. */
(function () {
    'use strict';
    var driverHelpUrl = 'https://github.com/gszigethy/pve-dc-powersave/blob/main/docs/INTEL-PSTATE.md';
    var GOVERNOR_KEYS = ['active_governor', 'idle_governor', 'migration_governor', 'failsafe_governor'];
    var NOT_INSTALLED_HINT = 'Rerun the installer on this node: a pve-manager upgrade removes the registration.';
    var STATUS_HINT = 'Double click a node for prerequisites and CPU policies';

    // Pure helpers, exposed for the tests in web/tests/.
    var ns = {
        GOVERNOR_KEYS: GOVERNOR_KEYS,

        // Whether the signed-in user holds a datacenter privilege.
        hasCap: function (privilege) {
            try {
                var caps = Ext.state.Manager.get('GuiCap');
                return !!(caps && caps.dc && caps.dc[privilege]);
            } catch (e) {
                return false;
            }
        },

        isGone: function (panel) {
            return !panel || !!panel.destroyed || !!panel.isDestroyed;
        },

        // A readable one-line reason for a failed Ext.Ajax response.
        describeFailure: function (response) {
            response = response || {};
            var message = response.statusText || 'Request failed';
            try { message = Ext.decode(response.responseText).message || message; } catch (e) { /* keep HTTP error */ }
            return (response.status > 0 ? 'HTTP ' + response.status + ': ' : '') + message;
        },

        // PVE answers an unregistered API path with 501 (404 is kept as
        // well): the plugin registration is gone from this node.
        nodeFailure: function (response) {
            var status = response && response.status;
            if (status === 501 || status === 404) {
                return { reason: 'plugin_not_installed', last_error: NOT_INSTALLED_HINT };
            }
            return { reason: 'status_unavailable', last_error: response && response.statusText };
        },

        // Decide what a save sends and whether it needs the capability
        // report. Mirrors the server: capabilities only matter when the
        // update turns the policy on or changes a governor of an enabled
        // one, so interval changes and disabling work with a node down.
        planSave: function (values, loaded, capabilities) {
            var out = Ext.apply({}, values);
            out.enabled = values.enabled ? 1 : 0;
            if (loaded) {
                GOVERNOR_KEYS.forEach(function (key) { out[key] = out[key] || loaded[key]; });
            }
            var wasEnabled = !!loaded && !loaded.configuration_error && Number(loaded.enabled) === 1;
            var changed = !wasEnabled || GOVERNOR_KEYS.some(function (key) { return out[key] !== loaded[key]; });
            var plan = { values: out, needsCheck: !!out.enabled && changed, error: null };
            if (plan.needsCheck && (!capabilities || !capabilities.complete)) {
                plan.error = 'Every node must report fresh CPU governor capabilities before the policy can be enabled.';
            } else if (plan.needsCheck && !(capabilities.common_governors || []).length) {
                plan.error = 'No common CPU governor is available across all nodes. See the Intel P-state setup guide.';
            }
            return plan;
        },

        // Wrap PVE.panel.Config.initComponent. The wrapper must never throw
        // and must call the original exactly once for every kind of config
        // panel (node, VM, CT, storage, datacenter): a failure in this
        // plugin may cost the Power Management card, never another panel.
        wrapConfigInit: function (original) {
            return function () {
                try {
                    var datacenter = typeof PVE.dc !== 'undefined' && PVE.dc.Config;
                    if (datacenter && this instanceof PVE.dc.Config && ns.hasCap('Sys.Audit')) {
                        if (Array.isArray(this.items)) {
                            this.items.push({
                                xtype: 'pveDcPowerManagement', title: 'Power Management',
                                iconCls: 'fa fa-bolt', itemId: 'power-management',
                            });
                        } else {
                            console.warn('pve-dc-powersave: datacenter panel has no items list; Power Management card skipped');
                        }
                    }
                } catch (e) {
                    console.warn('pve-dc-powersave: cannot add the Power Management card', e);
                }
                return original.apply(this, arguments);
            };
        },
    };
    PVE.DCPowerSave = ns;

    // User-initiated requests report failures in a dialog. Background
    // refreshes pass their own failure handler and stay inline.
    function request(options) {
        Ext.Ajax.request(Ext.apply({
            headers: { CSRFPreventionToken: Proxmox.CSRFPreventionToken },
            failure: function (response) {
                Ext.Msg.alert('Power Management', Ext.String.htmlEncode(ns.describeFailure(response)));
            },
        }, options));
    }

    Ext.define('PVE.dc.PowerManagement', {
        extend: 'Ext.panel.Panel',
        alias: 'widget.pveDcPowerManagement',
        layout: { type: 'vbox', align: 'stretch' },
        bodyPadding: 12,
        scrollable: true,

        initComponent: function () {
            var me = this;
            me.commonGovernorStore = Ext.create('Ext.data.Store', {
                fields: ['name'],
                data: [],
            });
            function governorField(name, label) {
                return {
                    xtype: 'combo', name: name, fieldLabel: label, allowBlank: false,
                    store: me.commonGovernorStore, queryMode: 'local', editable: false,
                    displayField: 'name', valueField: 'name', forceSelection: true,
                    emptyText: 'Waiting for all node capabilities',
                };
            }
            me.configForm = Ext.create('Ext.form.Panel', {
                title: 'Cluster policy',
                bodyPadding: 12,
                layout: 'anchor',
                defaults: { anchor: '100%', labelWidth: 200 },
                items: [
                    { xtype: 'checkbox', name: 'enabled', fieldLabel: 'Enabled', boxLabel: 'Manage CPU governors' },
                    governorField('active_governor', 'Active governor'),
                    governorField('idle_governor', 'Idle governor'),
                    governorField('migration_governor', 'Migration governor'),
                    governorField('failsafe_governor', 'Failsafe governor'),
                    { xtype: 'numberfield', name: 'reconciliation_interval', allowDecimals: false, fieldLabel: 'Safety reconciliation (s)', minValue: 5, maxValue: 3600 },
                    { xtype: 'numberfield', name: 'event_poll_interval', allowDecimals: false, fieldLabel: 'Task poll (s)', minValue: 1, maxValue: 60 },
                    { xtype: 'numberfield', name: 'idle_candidate_delay', allowDecimals: false, fieldLabel: 'Idle candidate delay (s)', minValue: 0, maxValue: 3600 },
                    { xtype: 'numberfield', name: 'boot_protection_period', allowDecimals: false, fieldLabel: 'Boot protection (s)', minValue: 0, maxValue: 86400 },
                ],
                buttons: [
                    { text: 'Reload policy', handler: function () { me.loadConfig(); } },
                    { text: 'Save cluster policy', iconCls: 'fa fa-save',
                        disabled: !ns.hasCap('Sys.Modify'),
                        handler: function () { me.saveConfig(); } },
                ],
            });
            me.capabilityNotice = Ext.create('Ext.Component', {
                padding: '10 12',
                style: { border: '1px solid #d0d0d0', background: '#f5f5f5' },
                html: 'Checking governors available across all nodes...',
            });
            me.statusStore = Ext.create('Ext.data.Store', {
                fields: ['node', 'state', 'actual_governors', 'desired_governor', 'running_vm_count',
                    'running_ct_count', 'protected', 'reason', 'last_error', 'prerequisites'],
                sorters: ['node'],
            });
            me.statusInfo = Ext.create('Ext.toolbar.TextItem', { text: STATUS_HINT });
            me.statusGrid = Ext.create('Ext.grid.Panel', {
                title: 'Node status',
                flex: 1,
                minHeight: 300,
                store: me.statusStore,
                columns: [
                    { text: 'Node', dataIndex: 'node', width: 130, renderer: Ext.String.htmlEncode },
                    { text: 'State', dataIndex: 'state', width: 135, renderer: Ext.String.htmlEncode },
                    { text: 'Actual', dataIndex: 'actual_governors', width: 150,
                        renderer: function (v) { return Ext.String.htmlEncode((v || []).join(', ') || 'unknown'); } },
                    { text: 'Desired', dataIndex: 'desired_governor', width: 140, renderer: Ext.String.htmlEncode },
                    { text: 'VMs', dataIndex: 'running_vm_count', width: 60 },
                    { text: 'CTs', dataIndex: 'running_ct_count', width: 60 },
                    { text: 'Protected', dataIndex: 'protected', width: 85, renderer: function (v) { return v ? 'Yes' : 'No'; } },
                    { text: 'Reason', dataIndex: 'reason', flex: 1, renderer: Ext.String.htmlEncode },
                    { text: 'Last error', dataIndex: 'last_error', flex: 1, renderer: Ext.String.htmlEncode },
                ],
                tbar: [
                    { text: 'Refresh', iconCls: 'fa fa-refresh', handler: function () { me.loadCapabilities(); me.loadStatus(); } },
                    // Requesting a reconciliation needs Sys.Modify.
                    { text: 'Reconcile selected', hidden: !ns.hasCap('Sys.Modify'), handler: function () { me.reconcileSelected(); } },
                    { text: 'Reconcile all', hidden: !ns.hasCap('Sys.Modify'), handler: function () { me.reconcileAll(); } },
                    '->', me.statusInfo,
                ],
                listeners: {
                    itemdblclick: function (grid, record) {
                        var details = Ext.JSON.encode(record.getData());
                        Ext.Msg.alert(Ext.String.htmlEncode(record.get('node')), '<pre style="white-space:pre-wrap;max-height:450px;overflow:auto">'
                            + Ext.String.htmlEncode(details) + '</pre>');
                    },
                },
            });
            me.items = [
                { xtype: 'component', html: '<p><strong>Homelab use only.</strong> Production use is not advised. '
                    + 'Idle requires verified guest, task, and CPU policy state.</p>' },
                me.capabilityNotice,
                { xtype: 'component', height: 12 },
                me.configForm,
                { xtype: 'component', height: 12 },
                me.statusGrid,
            ];
            me.callParent();
            me.on('show', function () {
                me.loadConfig(); me.loadCapabilities(); me.loadStatus();
                // Capability discovery runs pvesh on every node, so it is not
                // polled: it reloads on show, Refresh, and after a save.
                // The timer must not also fire when it starts: the status
                // was just loaded above.
                if (!me.refreshTask) {
                    me.refreshTask = Ext.TaskManager.start({ run: function () {
                        if (!ns.isGone(me) && me.isVisible()) { me.loadStatus(); }
                    }, interval: 15000, fireOnStart: false });
                }
            });
            me.on('destroy', function () { if (me.refreshTask) { Ext.TaskManager.stop(me.refreshTask); } });
        },

        loadCapabilities: function () {
            var me = this;
            if (me.capabilitiesLoading) { return; }
            me.capabilitiesLoading = true;
            request({ url: '/api2/json/cluster/power-management/capabilities', method: 'GET',
                success: function (response) {
                    me.capabilitiesLoading = false;
                    if (ns.isGone(me)) { return; }
                    var data = Ext.decode(response.responseText).data;
                    me.clusterCapabilities = data;
                    me.commonGovernorStore.loadData((data.common_governors || []).map(function (governor) {
                        return { name: governor };
                    }));
                    me.restoreGovernorFields();
                    if (!data.complete) {
                        var problems = (data.errors || []).map(function (error) {
                            return (error.node ? error.node + ': ' : '') + (error.message || error.reason);
                        });
                        me.capabilityNotice.update('<strong>Cluster governor discovery is incomplete.</strong> '
                            + Ext.String.htmlEncode(problems.join('; ') || 'One or more nodes did not report usable capabilities.')
                            + ' Power management cannot be enabled.');
                        return;
                    }
                    if (!(data.common_governors || []).length) {
                        me.capabilityNotice.update('<strong>No common CPU governor is available across all nodes.</strong> '
                            + 'Set the CPU frequency driver mode identically on every node. '
                            + '<a href="' + driverHelpUrl + '" target="_blank" rel="noopener">'
                            + 'Intel P-state and Proxmox VE setup guide</a>.');
                        return;
                    }
                    me.capabilityNotice.update('<strong>Governors available on every node:</strong> '
                        + Ext.String.htmlEncode(data.common_governors.join(', ')));
                },
                failure: function (response) {
                    me.capabilitiesLoading = false;
                    if (ns.isGone(me)) { return; }
                    me.clusterCapabilities = { complete: false, common_governors: [] };
                    me.commonGovernorStore.removeAll();
                    me.capabilityNotice.update('<strong>Cluster governor discovery failed.</strong> '
                        + Ext.String.htmlEncode(ns.describeFailure(response))
                        + ' Power management cannot be enabled.');
                },
            });
        },

        loadConfig: function () {
            var me = this;
            request({ url: '/api2/json/cluster/power-management', method: 'GET',
                success: function (response) {
                    if (ns.isGone(me)) { return; }
                    var data = Ext.decode(response.responseText).data;
                    me.digest = data.digest;
                    me.loadedConfig = data;
                    me.configForm.getForm().setValues(data);
                    me.restoreGovernorFields();
                    if (data.configuration_error) {
                        Ext.Msg.alert('Invalid cluster policy', Ext.String.htmlEncode(data.configuration_error)
                            + '<br>Review the fields and save to repair the configuration.');
                    }
                },
            });
        },

        // A combo with forceSelection drops a value its store does not
        // contain. Policy and capabilities load in parallel, so fill any
        // governor field left empty once both are known, without touching
        // a value the user has chosen.
        restoreGovernorFields: function () {
            var me = this;
            var form = me.configForm.getForm();
            if (!me.loadedConfig) { return; }
            GOVERNOR_KEYS.forEach(function (key) {
                var field = form.findField(key);
                var value = me.loadedConfig[key];
                if (!field.getValue() && value && me.commonGovernorStore.findExact('name', value) !== -1) {
                    field.setValue(value);
                    field.resetOriginalValue();
                }
            });
        },

        saveConfig: function () {
            var me = this;
            var form = me.configForm.getForm();
            var values = form.getValues();
            values.enabled = form.findField('enabled').getValue() ? 1 : 0;
            var plan = ns.planSave(values, me.loadedConfig, me.clusterCapabilities);
            if (plan.error) {
                Ext.Msg.alert('Power Management', plan.error);
                return;
            }
            // Disabling, and changes that leave the governors of an enabled
            // policy alone, do not need the governor combos (they are empty
            // while a node cannot report its capabilities).
            if (plan.values.enabled && !me.formValid(plan.needsCheck)) { return; }
            plan.values.digest = me.digest;
            request({ url: '/api2/json/cluster/power-management', method: 'PUT', params: plan.values,
                success: function (response) {
                    if (ns.isGone(me)) { return; }
                    var saved = Ext.decode(response.responseText).data;
                    me.digest = saved.digest;
                    me.loadedConfig = saved;
                    me.loadCapabilities();
                    me.loadStatus();
                    Ext.Msg.alert('Power Management', 'Cluster policy saved. Nodes will reconcile on their next poll.');
                },
            });
        },

        formValid: function (includeGovernors) {
            return this.configForm.getForm().getFields().getRange().every(function (field) {
                return (!includeGovernors && GOVERNOR_KEYS.indexOf(field.getName()) !== -1) || field.isValid();
            });
        },

        // Background refreshes report failures inline (toolbar text), never
        // in a dialog: an expired login or a pveproxy restart would
        // otherwise pop an alert every 15 seconds. The next success clears it.
        showStatusError: function (response) {
            this.statusInfo.setText(Ext.String.htmlEncode('Status refresh failed: ' + ns.describeFailure(response)
                + '. Showing the last known state; retrying automatically.'));
        },
        clearStatusError: function () {
            this.statusInfo.setText(STATUS_HINT);
        },

        loadStatus: function () {
            var me = this;
            // Refreshes overlap (timer, buttons, one deferred reload after
            // Reconcile all). Only the newest sweep may write rows, or late
            // replies from an older sweep duplicate nodes.
            var generation = me.statusGeneration = (me.statusGeneration || 0) + 1;
            function current() { return !ns.isGone(me) && generation === me.statusGeneration; }
            request({ url: '/api2/json/cluster/status', method: 'GET',
                success: function (response) {
                    if (!current()) { return; }
                    me.clearStatusError();
                    var nodes = Ext.decode(response.responseText).data.filter(function (entry) { return entry.type === 'node'; });
                    me.statusStore.removeAll();
                    nodes.forEach(function (node) {
                        if (!node.online) {
                            me.statusStore.add({ node: node.name, state: 'ERROR', reason: 'node_offline' });
                            return;
                        }
                        request({ url: '/api2/json/nodes/' + encodeURIComponent(node.name) + '/power-management', method: 'GET',
                            success: function (result) {
                                if (current()) { me.statusStore.add(Ext.decode(result.responseText).data); }
                            },
                            failure: function (result) {
                                if (!current()) { return; }
                                me.statusStore.add(Ext.apply({ node: node.name, state: 'ERROR' }, ns.nodeFailure(result)));
                            },
                        });
                    });
                },
                failure: function (response) {
                    if (current()) { me.showStatusError(response); }
                },
            });
        },

        reconcileSelected: function () {
            var selected = this.statusGrid.getSelectionModel().getSelection();
            if (selected.length) { this.reconcileNode(selected[0].get('node')); }
        },
        // Returns after posting; the caller decides when to reload the status.
        reconcileNode: function (node, done) {
            var me = this;
            if (!ns.hasCap('Sys.Modify')) { return; }
            request({ url: '/api2/json/nodes/' + encodeURIComponent(node) + '/power-management/reconcile', method: 'POST',
                success: function () { if (done) { done(); } else { me.reloadStatusSoon(); } },
                failure: function (response) {
                    if (done) { done(); }
                    if (!ns.isGone(me)) {
                        Ext.Msg.alert('Power Management', Ext.String.htmlEncode(node + ': ' + ns.describeFailure(response)));
                    }
                },
            });
        },
        reloadStatusSoon: function () {
            var me = this;
            Ext.defer(function () { if (!ns.isGone(me)) { me.loadStatus(); } }, 2500);
        },
        reconcileAll: function () {
            var me = this;
            var pending = 0;
            function done() { if (--pending === 0) { me.reloadStatusSoon(); } }
            var nodes = [];
            me.statusStore.each(function (record) {
                if (record.get('reason') !== 'node_offline') { nodes.push(record.get('node')); }
            });
            pending = nodes.length;
            nodes.forEach(function (node) { me.reconcileNode(node, done); });
        },
    });

    // The existing config panel builds its navigation tree in the base
    // initComponent. Insert the new declarative card just before that step.
    // Anything missing from this PVE version only costs the card.
    if (typeof PVE.panel !== 'undefined' && PVE.panel.Config) {
        PVE.panel.Config.override({
            initComponent: ns.wrapConfigInit(PVE.panel.Config.prototype.initComponent),
        });
    } else {
        console.warn('pve-dc-powersave: PVE.panel.Config not found; Power Management card not added');
    }
}());
