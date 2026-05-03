#!/usr/bin/env python3
import copy
import json
import os
from pathlib import Path

CONFIG_DIRS = [
    Path(os.environ.get('OPENCODE_CONFIG_DIR', '')).expanduser() if os.environ.get('OPENCODE_CONFIG_DIR') else None,
    Path('/config/opencode'),
    Path.home() / '.config' / 'opencode',
]
BASE_FILENAMES = ['oh-my-openagent.json']
USER_FILENAMES = ['oh-my-openagent.user.json']


def resolve_config_dir() -> Path | None:
    env_dir = os.environ.get('OPENCODE_CONFIG_DIR', '').strip()
    if env_dir:
        return Path(env_dir).expanduser()
    for directory in CONFIG_DIRS[1:]:
        if directory and directory.exists():
            return directory
    for directory in CONFIG_DIRS[1:]:
        if directory:
            return directory
    return None


def strip_jsonc(text: str) -> str:
    lines = []
    for line in text.splitlines():
        out = []
        in_string = False
        escaped = False
        i = 0
        while i < len(line):
            ch = line[i]
            if escaped:
                out.append(ch)
                escaped = False
            elif ch == '\\':
                out.append(ch)
                escaped = True
            elif ch == '"':
                out.append(ch)
                in_string = not in_string
            elif not in_string and ch == '/' and i + 1 < len(line) and line[i + 1] == '/':
                break
            else:
                out.append(ch)
            i += 1
        lines.append(''.join(out))
    return '\n'.join(lines)


def load_json(path: Path):
    if not path.exists():
        return {}
    raw = path.read_text(encoding='utf-8')
    cleaned = strip_jsonc(raw).strip()
    return json.loads(cleaned) if cleaned else {}


def save_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def locate_base_path() -> Path:
    preferred_dir = resolve_config_dir()
    if preferred_dir:
        return preferred_dir / BASE_FILENAMES[0]
    return Path.home() / '.config' / 'opencode' / BASE_FILENAMES[0]


def locate_user_override(base_path: Path) -> Path:
    return base_path.parent / USER_FILENAMES[0]


def deep_merge(base, overlay):
    if isinstance(base, dict) and isinstance(overlay, dict):
        merged = dict(base)
        for key, value in overlay.items():
            merged[key] = deep_merge(base.get(key), value)
        return merged
    if isinstance(base, list) and isinstance(overlay, list):
        return copy.deepcopy(overlay)
    return copy.deepcopy(overlay)


def sync_models(data):
    model = os.environ.get('OMO_AGENT_MODEL', '').strip() or os.environ.get('OPENCODE_MODEL', '').strip()
    category_model = os.environ.get('OMO_CATEGORY_MODEL', '').strip() or model
    if model:
        agents = data.get('agents')
        if isinstance(agents, dict):
            for agent in agents.values():
                if isinstance(agent, dict):
                    agent['model'] = model
    if category_model:
        categories = data.get('categories')
        if isinstance(categories, dict):
            for category in categories.values():
                if isinstance(category, dict):
                    category['model'] = category_model
    return data


def main():
    base_path = locate_base_path()
    data = load_json(base_path)
    if not isinstance(data, dict):
        data = {}
    data = sync_models(data)
    user_override = locate_user_override(base_path)
    if user_override.exists():
        override_data = load_json(user_override)
        if isinstance(override_data, dict):
            data = deep_merge(data, override_data)
    save_json(base_path, data)
    print(base_path)


if __name__ == '__main__':
    main()
