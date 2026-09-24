/* Datacenter -> Power Management. Loaded after pvemanagerlib.js. */
(function () {
    'use strict';
    var driverHelpUrl = 'https://github.com/gszigethy/pve-dc-powersave/blob/main/docs/INTEL-PSTATE.md';

    function request(options) {
        Ext.Ajax.request(Ext.apply({
            headers: { CSRFPreventionToken: Proxmox.CSRFPreventionToken },
            failure: function (response) {
                var message = response.statusText || 'Request failed';
                try { message = Ext.decode(response.responseText).message || message; } catch (e) { /* keep HTTP error */ }
                Ext.Msg.alert('Power Management', Ext.String.htmlEncode(message));
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
                    { xtype: 'numberfield', name: 'reconciliation_interval', fieldLabel: 'Safety reconciliation (s)', minValue: 5, maxValue: 3600 },
                    { xtype: 'numberfield', name: 'event_poll_interval', fieldLabel: 'Task poll (s)', minValue: 1, maxValue: 60 },
                    { xtype: 'numberfield', name: 'idle_candidate_delay', fieldLabel: 'Idle candidate delay (s)', minValue: 0, maxValue: 3600 },
                    { xtype: 'numberfield', name: 'boot_protection_period', fieldLabel: 'Boot protection (s)', minValue: 0, maxValue: 86400 },
                ],
                buttons: [
                    { text: 'Reload policy', handler: function () { me.loadConfig(); } },
                    { text: 'Save cluster policy', iconCls: 'fa fa-save',
                        disabled: !Ext.state.Manager.get('GuiCap').dc['Sys.Modify'],
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
            });
            me.statusGrid = Ext.create('Ext.grid.Panel', {
                title: 'Node status',
                flex: 1,
                minHeight: 300,
                store: me.statusStore,
                columns: [
                    { text: 'Node', dataIndex: 'node', width: 130 },
                    { text: 'State', dataIndex: 'state', width: 135 },
                    { text: 'Actual', dataIndex: 'actual_governors', width: 150,
                        renderer: function (v) { return Ext.String.htmlEncode((v || []).join(', ') || 'unknown'); } },
                    { text: 'Desired', dataIndex: 'desired_governor', width: 140 },
                    { text: 'VMs', dataIndex: 'running_vm_count', width: 60 },
                    { text: 'CTs', dataIndex: 'running_ct_count', width: 60 },
                    { text: 'Protected', dataIndex: 'protected', width: 85, renderer: function (v) { return v ? 'Yes' : 'No'; } },
                    { text: 'Reason', dataIndex: 'reason', flex: 1, renderer: Ext.String.htmlEncode },
                    { text: 'Last error', dataIndex: 'last_error', flex: 1, renderer: Ext.String.htmlEncode },
                ],
                tbar: [
                    { text: 'Refresh', iconCls: 'fa fa-refresh', handler: function () { me.loadStatus(); } },
                    { text: 'Reconcile selected', handler: function () { me.reconcileSelected(); } },
                    { text: 'Reconcile all', handler: function () { me.reconcileAll(); } },
                    '->', { xtype: 'tbtext', text: 'Double click a node for prerequisites and CPU policies' },
                ],
                listeners: {
                    itemdblclick: function (grid, record) {
                        var details = Ext.JSON.encode(record.getData());
                        Ext.Msg.alert(record.get('node'), '<pre style="white-space:pre-wrap;max-height:450px;overflow:auto">'
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
                if (!me.refreshTask) {
                    me.refreshTask = Ext.TaskManager.start({ run: function () {
                        if (!me.destroyed && me.isVisible()) { me.loadCapabilities(); me.loadStatus(); }
                    }, interval: 15000 });
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
                    var data = Ext.decode(response.responseText).data;
                    me.clusterCapabilities = data;
                    me.commonGovernorStore.loadData((data.common_governors || []).map(function (governor) {
                        return { name: governor };
                    }));
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
                    me.clusterCapabilities = { complete: false, common_governors: [] };
                    me.commonGovernorStore.removeAll();
                    me.capabilityNotice.update('<strong>Cluster governor discovery failed.</strong> '
                        + Ext.String.htmlEncode(response.statusText || 'Capability endpoint unavailable')
                        + ' Power management cannot be enabled.');
                },
            });
        },

        loadConfig: function () {
            var me = this;
            request({ url: '/api2/json/cluster/power-management', method: 'GET',
                success: function (response) {
                    var data = Ext.decode(response.responseText).data;
                    me.digest = data.digest;
                    me.loadedConfig = data;
                    me.configForm.getForm().setValues(data);
                    if (data.configuration_error) {
                        Ext.Msg.alert('Invalid cluster policy', Ext.String.htmlEncode(data.configuration_error)
                            + '<br>Review the fields and save to repair the configuration.');
                    }
                },
            });
        },

        saveConfig: function () {
            var me = this;
            var form = me.configForm.getForm();
            var values = form.getValues();
            values.enabled = form.findField('enabled').getValue() ? 1 : 0;
            if (!values.enabled && me.loadedConfig) {
                ['active_governor', 'idle_governor', 'migration_governor', 'failsafe_governor'].forEach(function (key) {
                    values[key] = values[key] || me.loadedConfig[key];
                });
            }
            if (values.enabled && (!me.clusterCapabilities || !me.clusterCapabilities.complete)) {
                Ext.Msg.alert('Power Management', 'Every node must report fresh CPU governor capabilities before the policy can be enabled.');
                return;
            }
            if (values.enabled && !(me.clusterCapabilities.common_governors || []).length) {
                Ext.Msg.alert('Power Management', 'No common CPU governor is available across all nodes. See the Intel P-state setup guide.');
                return;
            }
            if (values.enabled && !form.isValid()) { return; }
            values.digest = me.digest;
            request({ url: '/api2/json/cluster/power-management', method: 'PUT', params: values,
                success: function (response) {
                    me.digest = Ext.decode(response.responseText).data.digest;
                    me.loadCapabilities();
                    me.loadStatus();
                    Ext.Msg.alert('Power Management', 'Cluster policy saved. Nodes will reconcile on their next poll.');
                },
            });
        },

        loadStatus: function () {
            var me = this;
            request({ url: '/api2/json/cluster/status', method: 'GET',
                success: function (response) {
                    var nodes = Ext.decode(response.responseText).data.filter(function (entry) { return entry.type === 'node'; });
                    me.statusStore.removeAll();
                    nodes.forEach(function (node) {
                        if (!node.online) {
                            me.statusStore.add({ node: node.name, state: 'ERROR', reason: 'node_offline' });
                            return;
                        }
                        request({ url: '/api2/json/nodes/' + encodeURIComponent(node.name) + '/power-management', method: 'GET',
                            success: function (result) { me.statusStore.add(Ext.decode(result.responseText).data); },
                            failure: function (result) {
                                me.statusStore.add({ node: node.name, state: 'ERROR',
                                    reason: result.status === 404 ? 'plugin_not_installed' : 'status_unavailable',
                                    last_error: result.statusText });
                            },
                        });
                    });
                },
            });
        },

        reconcileSelected: function () {
            var selected = this.statusGrid.getSelectionModel().getSelection();
            if (selected.length) { this.reconcileNode(selected[0].get('node')); }
        },
        reconcileNode: function (node) {
            var me = this;
            request({ url: '/api2/json/nodes/' + encodeURIComponent(node) + '/power-management/reconcile', method: 'POST',
                success: function () { Ext.defer(function () { me.loadStatus(); }, 2500); },
            });
        },
        reconcileAll: function () {
            var me = this;
            me.statusStore.each(function (record) {
                if (record.get('reason') !== 'node_offline') { me.reconcileNode(record.get('node')); }
            });
        },
    });

    // The existing config panel builds its navigation tree in the base
    // initComponent. Insert the new declarative card just before that step.
    var original = PVE.panel.Config.prototype.initComponent;
    PVE.panel.Config.override({
        initComponent: function () {
            if (this instanceof PVE.dc.Config && Ext.state.Manager.get('GuiCap').dc['Sys.Audit']) {
                this.items.push({
                    xtype: 'pveDcPowerManagement', title: 'Power Management',
                    iconCls: 'fa fa-bolt', itemId: 'power-management',
                });
            }
            return original.apply(this, arguments);
        },
    });
}());
