#!/usr/bin/env python3
"""Install or remove the two narrow API registrations and the UI script tag.

PVE has no supported general UI/API plugin loader. Refuse unknown layouts,
keep a versioned backup, and never edit the compiled pvemanagerlib.js bundle.
Run with --remove to take the registrations out again before uninstalling.
"""
import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time


def perl_module_path(name):
    code = f'require {name}; print $INC{{"{name.replace("::", "/")}.pm"}}'
    result = subprocess.run(['perl', '-e', code], check=True, capture_output=True, text=True)
    return pathlib.Path(result.stdout)


def insert_once(text, marker, anchor, addition):
    if marker in text:
        return text
    if anchor not in text:
        raise RuntimeError(f'Insertion anchor missing: {anchor[:60]}')
    return text.replace(anchor, addition + anchor, 1)


def write_atomic(path, modified):
    fd, tmpname = tempfile.mkstemp(prefix='.dc-powersave.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(modified)
        os.chmod(tmpname, path.stat().st_mode)
        os.replace(tmpname, path)
    finally:
        if os.path.exists(tmpname):
            os.unlink(tmpname)


cluster_registration = '''# BEGIN pve-dc-powersave
__PACKAGE__->register_method({
    subclass => "PVE::API2::Cluster::DCPowerSave",
    path => 'power-management',
});
# END pve-dc-powersave

'''
node_registration = '''# BEGIN pve-dc-powersave
__PACKAGE__->register_method({
    subclass => "PVE::API2::Nodes::DCPowerSave",
    path => 'power-management',
});
# END pve-dc-powersave

'''


def cluster_transform(raw):
    raw = insert_once(raw, 'use PVE::API2::Cluster::DCPowerSave;',
                      'use base qw(PVE::RESTHandler);',
                      'use PVE::API2::Cluster::DCPowerSave;\n\n')
    return insert_once(raw, '# BEGIN pve-dc-powersave',
                       '__PACKAGE__->register_method({', cluster_registration)


def node_transform(raw):
    raw = insert_once(raw, 'use PVE::API2::Nodes::DCPowerSave;',
                      'use PVE::API2::NodeConfig;',
                      'use PVE::API2::Nodes::DCPowerSave;\n\n')
    return insert_once(raw, '# BEGIN pve-dc-powersave',
                       '__PACKAGE__->register_method({', node_registration)


def index_transform(raw):
    if '/pve2/js/dc-powersave.js' in raw:
        return raw
    anchor = '    <script type="text/javascript" src="/pve2/ext6/locale/'
    return insert_once(raw, '/pve2/js/dc-powersave.js', anchor,
                       '    <script type="text/javascript" src="/pve2/js/dc-powersave.js"></script>\n')


INDEX = pathlib.Path('/usr/share/pve-manager/index.html.tpl')
REGISTRATION_BLOCK = re.compile(r'# BEGIN pve-dc-powersave\n.*?# END pve-dc-powersave\n\n?', re.S)
USE_LINE = re.compile(r'^use PVE::API2::(?:Cluster|Nodes)::DCPowerSave;\n\n?', re.M)
SCRIPT_TAG = re.compile(r'^[ \t]*<script[^>]*/pve2/js/dc-powersave\.js[^>]*></script>\n', re.M)


def api_remove(raw):
    return USE_LINE.sub('', REGISTRATION_BLOCK.sub('', raw))


def index_remove(raw):
    return SCRIPT_TAG.sub('', raw)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Integrate pve-dc-powersave with the PVE API and UI.')
    parser.add_argument('--remove', action='store_true',
                        help='remove the registrations instead of adding them')
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        raise RuntimeError('Run integration as root')
    cluster = perl_module_path('PVE::API2::Cluster')
    nodes = perl_module_path('PVE::API2::Nodes')
    index = INDEX
    for path in (cluster, nodes, index):
        if not path.is_file():
            raise RuntimeError(f'PVE integration file missing: {path}')
    if args.remove:
        transforms = ((cluster, api_remove), (nodes, api_remove), (index, index_remove))
    else:
        transforms = ((cluster, cluster_transform), (nodes, node_transform), (index, index_transform))
    edits = []
    for path, transform in transforms:
        original = path.read_text()
        modified = transform(original)
        if modified != original:
            backup = path.with_name(path.name + f'.dc-powersave.backup.{time.time_ns()}')
            edits.append((path, modified, backup))
    backups = []
    try:
        for path, modified, backup in edits:
            shutil.copy2(path, backup)
            backups.append((path, backup))
            write_atomic(path, modified)
            print(f'{"Removed from" if args.remove else "Integrated"}: {path} (backup: {backup})')
        for path in (cluster, nodes):
            subprocess.run(['perl', '-c', str(path)], check=True)
        if edits:
            subprocess.run(['systemctl', 'restart', 'pvedaemon', 'pveproxy'], check=True)
    except Exception:
        for path, backup in reversed(backups):
            shutil.copy2(backup, path)
        if backups:
            subprocess.run(['systemctl', 'restart', 'pvedaemon', 'pveproxy'], check=False)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'PVE integration failed: {error}', file=sys.stderr)
        sys.exit(1)
