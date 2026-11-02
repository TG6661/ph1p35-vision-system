"""Check tracked inputs only; never invoke FPGA tools or access hardware."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree as ET


def check(root):
    tracked = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '-z']).decode('utf-8').split('\0')
    tracked = {p for p in tracked if p}
    errors = []
    for name in sorted(tracked):
        path = root / name
        if not path.is_file():
            errors.append(f'Missing tracked file: {name}')
            continue
        if path.stat().st_size >= 50 * 1024**2:
            errors.append(f'File >= 50 MiB; use a Release attachment: {name}')
        if (re.search(r'^FPGA/td_project/[^/]+_Runs/', name)
                or re.search(r'^FDWork/[^/]+/(build|Debug|Release)/', name)
                or re.search(r'^FPGA/sim/current/([^/]+_work|runs)/', name)):
            errors.append(f'Generated output committed: {name}')

    def input_file(path, label):
        path = path.resolve()
        try:
            name = path.relative_to(root).as_posix()
        except ValueError:
            errors.append(f'Input escapes repository ({label})')
            return
        if name not in tracked or not path.is_file():
            errors.append(f'Missing or untracked input ({label}): {name}')

    project = root / 'FPGA/td_project/camera_to_dsi_display.al'
    # TD uses XML tag names containing ::; standard XML parsers reject those tags.
    refs = re.findall(r'<File\s+Path="([^"]+)"', project.read_text(encoding='utf-8-sig'))
    if not refs:
        errors.append('No source entries found in TD project')
    for name in refs:
        input_file(project.parent / name, 'TD source/constraint/IP')

    required = [
        'FPGA/sim/current/logo_pixels.hex',
        'FPGA/user_source/hdl_source/ph1p35_ddr/ddr2/src/rtl/phy/ddrphy_cfg_rom.txt',
        'FDWork/MCU_startup/LICENSE',
        'FDWork/ph1p35_hello/Makefile',
        'FDWork/MCU_startup/tools/make/rules.mk',
        'FDWork/ph1p35_hello/lds/gcc_ph1p35_xip_dlm.ld',
    ]
    for name in required:
        input_file(root / name, 'required build/test input')

    templates = root / 'tools/templates'
    for name in ['application.project.json.template', 'bsp.project.json.template']:
        raw = (templates / name).read_text(encoding='utf-8-sig')
        obj = json.loads(raw.replace('@REPO_ROOT@', '/checkout'))
        if not obj['location'].startswith('/checkout/FDWork/'):
            errors.append(f'Nonportable location in {name}')
    launch = ET.fromstring((templates / 'final_current_0x70ff.launch.template')
                           .read_text(encoding='utf-8-sig').replace('@REPO_ROOT@', '/checkout'))
    for key in ['org.eclipse.cdt.launch.PROGRAM_NAME',
                'org.eclipse.cdt.debug.gdbjtag.core.imageFileName',
                'org.eclipse.cdt.debug.gdbjtag.core.symbolsFileName']:
        values = [e.get('value') for e in launch if e.get('key') == key]
        if values != ['/checkout/FDWork/ph1p35_hello/build/ph1p35_hello.elf']:
            errors.append(f'Nonportable launch path: {key}')

    if errors:
        for msg in errors:
            print(f'ERROR: {msg}', file=sys.stderr)
        return 1
    print(f'REPOSITORY_CHECK_PASS tracked={len(tracked)} td_inputs={len(refs)}')
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    sys.exit(check(args.root.resolve()))
