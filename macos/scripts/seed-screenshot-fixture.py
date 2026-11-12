"""Create fictional display-only data on an ephemeral screenshot runner.

No project directory or command is executed. Refuse to overwrite existing data.
"""
import json
from pathlib import Path

root = Path.home() / "Library/Application Support/FlutterRunbar"
if root.exists():
    raise SystemExit("Refusing to overwrite existing FlutterRunbar data")
root.mkdir(parents=True, mode=0o700)
project = "/Users/demo/Projects/示例项目（演示数据）"
preset = "22222222-2222-4222-8222-222222222222"
config = {
    "projects": [{"id": "11111111-1111-4111-8111-111111111111", "path": project, "kind": "flutter",
                  "presets": [{"id": preset, "name": "运行 macOS（演示）", "command": "fvm flutter run -d macos"},
                              {"id": "33333333-3333-4333-8333-333333333333", "name": "检查代码", "command": "fvm flutter analyze"}]}],
    "extraPath": "/Users/demo/.pub-cache/bin:/opt/homebrew/bin:/usr/local/bin"
}
# Extra fictional projects show independent row controls, including a long name.
config["projects"].extend([
    {"id": "44444444-4444-4444-8444-444444444444", "path": "/Users/demo/Projects/后台管理端（演示）", "kind": "flutter",
     "presets": [{"id": "55555555-5555-4555-8555-555555555555", "name": "运行 Chrome", "command": "fvm flutter run -d chrome"}]},
    {"id": "66666666-6666-4666-8666-666666666666", "path": "/Users/demo/Projects/这是一个名称比较长的移动客户端项目（演示）", "kind": "flutter",
     "presets": [{"id": "77777777-7777-4777-8777-777777777777", "name": "运行 macOS", "command": "fvm flutter run -d macos"}]}
])
(root / "configuration.json").write_text(json.dumps(config, ensure_ascii=False, indent=2))
logs = [
    ("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "2026-10-24T14:00:00Z", "2026-10-24T14:02:15Z", "succeeded", 0,
     "fvm flutter run -d macos", 135,
     "[演示数据 · 仅用于展示界面，没有执行 Flutter 命令]\\n\\nLaunching lib/main.dart on macOS in debug mode...\\nBuilding macOS application...                                   12.4s\\n✓ Built build/macos/Build/Products/Debug/hello_flutter.app\\nSyncing files to device macOS...                                 128ms\\n\\nFlutter run key commands.\\nr Hot reload. 🔥🔥🔥\\nR Hot restart.\\n\\nThe Flutter DevTools debugger and profiler is available at:\\nhttp://127.0.0.1:9100/?uri=http://127.0.0.1:54321/demo=/\\n\\n[14:01:20] 示例：中文、Emoji 🚀 和运行日志\\nApplication finished.\\n"),
    ("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", "2026-10-24T13:50:00Z", "2026-10-24T13:50:08Z", "succeeded", 0,
     "fvm flutter analyze", 8, "[演示数据]\\nAnalyzing hello_flutter...\\nNo issues found! (ran in 8.0s)\\n"),
    ("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", "2026-10-24T13:40:00Z", "2026-10-24T13:42:03Z", "stopped", 130,
     "fvm flutter run -d macos", 123, "[演示数据]\\nApplication finished.\\n")
]
for identifier, start, end, status, code, command, duration, output in logs:
    folder = root / "sessions" / identifier
    folder.mkdir(parents=True, mode=0o700)
    payload = output.replace("\\n", "\n").encode()
    session = dict(id=identifier, projectPath=project, command=command, startedAt=start,
                   endedAt=end, duration=duration, exitCode=code, status=status,
                   devToolsURLs=["http://127.0.0.1:9100/?uri=http://127.0.0.1:54321/demo=/"] if identifier.startswith("A") else [])
    (folder / "session.json").write_text(json.dumps(session, ensure_ascii=False, indent=2))
    (folder / "output.raw").write_bytes(payload)
    (folder / "events.jsonl").write_text(json.dumps(dict(sequence=0, receivedAt=start, offset=0, byteCount=len(payload))) + "\n")
print("Created three fictional sessions; no commands were executed.")
