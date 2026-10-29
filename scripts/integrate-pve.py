#!/usr/bin/env python3
"""Install or remove the two narrow API registrations and the UI script tag.

PVE has no supported general UI/API plugin loader. Refuse unknown layouts,
keep backups, and never edit the compiled pvemanagerlib.js bundle.
Run with --remove to take the registrations out again before uninstalling.

Backups of the edited files live in BACKUP_DIR (newest KEEP_BACKUPS per
original file), for inspection only: after a pve-manager upgrade a restored
copy would downgrade PVE's API.
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
import urllib.parse

BACKUP_DIR = pathlib.Path('/var/lib/pve-dc-powersave/backups')  # tests patch this
KEEP_BACKUPS = 5
RELOAD = ['systemctl', 'reload-or-restart', 'pvedaemon', 'pveproxy']


def run_perl(args):
    """Run perl and raise a RuntimeError that carries Perl's own stderr."""
    command = ['perl', *args]
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        raise RuntimeError(f'Cannot run perl: {error}') from error
    if result.returncode != 0:
        detail = (result.stderr or '').strip() or '(no output)'
        raise RuntimeError(f'{" ".join(command)} failed with exit status {result.returncode}:\n{detail}')
    return result


def perl_module_path(name):
    """Find a Perl module file in @INC without loading it.

    Loading (`require`) dies while the module uses a plugin module that is
    missing, which is exactly the state --remove has to repair.
    """
    relative = name.replace('::', '/') + '.pm'
    for directory in run_perl(['-e', 'print join "\\n", @INC']).stdout.split('\n'):
        if directory and (pathlib.Path(directory) / relative).is_file():
            return pathlib.Path(directory) / relative
    raise RuntimeError(f'{relative} not found in Perl @INC')


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
    migrate_legacy_backups((cluster, nodes, index))
    if args.remove:
        transforms = ((cluster, api_remove), (nodes, api_remove), (index, index_remove))
    else:
        transforms = ((cluster, cluster_transform), (nodes, node_transform), (index, index_transform))
    apply_edits(plan_edits(transforms), (cluster, nodes), 'Removed from' if args.remove else 'Integrated')


def backup_name(path, stamp):
    """Name that keeps the original path recoverable: %2F-quoted path + stamp."""
    return f"{urllib.parse.quote(str(path), safe='')}.{stamp}.backup"


BACKUP_NAME = re.compile(r'^(?P<original>.+)\.(?P<stamp>\d+)\.backup$')


def ensure_backup_dir():
    if BACKUP_DIR.is_symlink():
        raise RuntimeError(f'Backup directory {BACKUP_DIR} is a symlink; refusing to use it')
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    BACKUP_DIR.chmod(0o700)


def prune_backups():
    """Keep only the newest KEEP_BACKUPS backups per original file."""
    if not BACKUP_DIR.is_dir():
        return
    groups = {}
    for entry in BACKUP_DIR.iterdir():
        match = BACKUP_NAME.match(entry.name)
        if match and entry.is_file() and not entry.is_symlink():
            groups.setdefault(match['original'], []).append((int(match['stamp']), entry))
    for entries in groups.values():
        for _, entry in sorted(entries, key=lambda item: item[0], reverse=True)[KEEP_BACKUPS:]:
            entry.unlink()


def migrate_legacy_backups(paths):
    """Move `<file>.dc-powersave.backup.<ns>` copies out of PVE's directories.

    Only files that match our own naming next to the three integration files
    are touched. They are moved, never deleted in place.
    """
    for path in paths:
        legacy = re.compile(re.escape(path.name) + r'\.dc-powersave\.backup\.(\d+)')
        for entry in sorted(path.parent.iterdir()):
            match = legacy.fullmatch(entry.name)
            if not match or not entry.is_file() or entry.is_symlink():
                continue
            ensure_backup_dir()
            target = BACKUP_DIR / backup_name(path, match[1])
            if target.exists():
                continue
            shutil.move(str(entry), str(target))
            print(f'Moved old backup {entry} to {target}')
    prune_backups()


def plan_edits(transforms):
    edits = []
    for path, transform in transforms:
        original = path.read_text()
        modified = transform(original)
        if modified != original:
            edits.append((path, modified, BACKUP_DIR / backup_name(path, time.time_ns())))
    return edits


def apply_edits(edits, perl_modules, verb):
    backups = []
    try:
        if edits:
            ensure_backup_dir()
        for path, modified, backup in edits:
            shutil.copy2(path, backup)
            backups.append((path, backup))
            write_atomic(path, modified)
            print(f'{verb}: {path} (backup: {backup})')
        # Safety net: the edited file must still compile. For integrate this
        # proves the plugin modules it now loads are installed and valid; for
        # --remove it proves PVE's file is sound without the plugin, even when
        # the plugin module it used to load is already gone.
        for path in perl_modules:
            run_perl(['-c', str(path)])
        if edits:
            subprocess.run(RELOAD, check=True)
    except Exception:
        for path, backup in reversed(backups):
            shutil.copy2(backup, path)
        if backups:
            subprocess.run(RELOAD, check=False)
        raise
    prune_backups()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'PVE integration failed: {error}', file=sys.stderr)
        sys.exit(1)
