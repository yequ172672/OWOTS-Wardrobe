#!/usr/bin/env python3
"""Small Chinese Tkinter front end for the portable MOD converter.

The GUI deliberately delegates all decisions and validation to
``mod_converter.py``.  A worker thread keeps large PAK scans responsive, while
the report pane shows the same machine-readable diagnostics a CLI user gets.
All fields have visible labels and keyboard focus order; errors are rendered
with a text prefix as well as color so status is not color-only.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import locale
import os
from pathlib import Path
import queue
import sys
import threading
import tkinter as tk
from tkinter import filedialog, ttk

import mod_converter
import warnings


def _chinese_system() -> bool:
    """Best-effort system-language detection; unknown locales fall back to English."""
    candidates = []
    try:
        candidates.append(locale.getlocale()[0])
    except (ValueError, TypeError):
        pass
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", DeprecationWarning)
                candidates.append(locale.getdefaultlocale()[0])
    except (ValueError, TypeError, AttributeError):
        pass
    candidates.append(os.environ.get("LANG"))
    candidates.append(os.environ.get("LANGUAGE"))
    for value in candidates:
        if value and str(value).lower().replace("-", "_").startswith(("zh", "chinese")):
            return True
    return False


# Auto-detected interface language: Chinese systems get Chinese, everything else English.
CHINESE_UI = _chinese_system()


def T(zh: str, en: str) -> str:
    """Localize a literal for the current interface language."""
    return zh if CHINESE_UI else en


# Sentinel for the "auto" combo entries, localized for display but compared by identity.
AUTO = T("自动", "Auto")


def readable_report(output: str) -> str:
    """Put actionable results before the many per-resource inventory records."""
    try:
        value = json.loads(output)
    except (ValueError, TypeError):
        return output
    if not isinstance(value, dict):
        return output
    status = value.get("status", "unknown")
    labels = {"converted": T("转换完成", "Conversion completed"),
              "inspected": T("只读检查完成", "Inspection completed"),
              "blocked": T("已停止，需处理以下问题", "Stopped; resolve the following issues")}
    lines = [labels.get(status, str(status)), ""]
    urgent = [issue for issue in value.get("issues", []) if issue.get("severity") == "error"] if status == "blocked" else []
    for issue in urgent:
        lines += [f"[{issue.get('code', '')}] {issue.get('message', '')}", ""]
    stats = value.get("stats", {})
    if value.get("source"):
        lines += [T("输入：", "Input: ") + value["source"], ""]
    for field, label in (("inputAssets", T("输入资源", "Input assets")),
                         ("graphNodes", T("依赖资源", "Dependency resources")),
                         ("privateResources", T("独立资源", "Private resources")),
                         ("sharedResources", T("复用游戏原始资源", "Reused game resources"))):
        if field in stats:
            lines.append(label + T("：", ": ") + str(stats[field]))
    parts = stats.get("autoPartDependencyChecks", {})
    if parts:
        lines.append(T("已验证部位：", "Verified parts: ") + T("、", ", ").join(sorted(parts)))
    for item in stats.get("texturePromotions", []):
        if item.get("promoted"):
            dimensions = item.get("streamingResolution", [])
            lines.append(T("高清纹理：", "High-res texture: ") + " × ".join(map(str, dimensions))
                         + T("，已完整保留", ", fully preserved"))
    issues = value.get("issues", [])
    for severity, label in (("error", T("错误", "Error")), ("warning", T("注意", "Notice"))):
        if severity == "error" and urgent:
            continue
        selected = [issue for issue in issues if issue.get("severity") == severity]
        if selected:
            lines += ["", label + T("（", " (") + str(len(selected)) + T("）：", "): ")]
        for issue in selected:
            lines.append(f"[{issue.get('code', '')}] {issue.get('message', '')}")
            if issue.get("path"):
                lines.append("  " + issue["path"])
    if status == "converted":
        lines += ["", T("完整诊断保存在输出目录的 conversion-report.json 和 CONVERSION-REPORT.md。",
                        "Full diagnostics are saved as conversion-report.json and CONVERSION-REPORT.md in the output folder.")]
    elif status == "inspected":
        lines += ["", T("此步骤只检查输入；点击“开始转换”后才会从游戏读取依赖并验证完整转换。",
                        "This step only inspects the input; dependencies and the full conversion are verified after you click Start conversion.")]
    if stats.get("blockedReport"):
        lines += ["", T("诊断目录：", "Diagnostics folder: ") + stats["blockedReport"]]
    return "\n".join(lines)


class ConverterWindow:
    BG = "#121212"
    PANEL = "#1d1f24"
    TEXT = "#f2f4f7"
    MUTED = "#b8c0cc"
    ACCENT = "#56b4ff"
    ERROR = "#ff8d8d"
    OK = "#8cdaa5"

    def __init__(self, root: tk.Tk):
        self.root = root
        root.title(T("OWOTS 衣橱 MOD 转换器", "OWOTS Wardrobe MOD Converter"))
        root.geometry("900x680")
        root.minsize(760, 560)
        root.configure(bg=self.BG)
        root.option_add("*Font", ("Segoe UI", 10))
        root.option_add("*Foreground", self.TEXT)
        root.option_add("*Background", self.PANEL)
        root.option_add("*Entry.InsertBackground", self.TEXT)
        root.option_add("*Entry.InsertForeground", self.TEXT)
        root.option_add("*TCombobox*Listbox*Background", self.PANEL)
        root.option_add("*TCombobox*Listbox*Foreground", self.TEXT)
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.busy = False
        self.vars = {name: tk.StringVar() for name in
                     ("input", "output", "game", "prefab", "catalog", "native", "id")}
        self.category = tk.StringVar(value=AUTO)
        self.part = tk.StringVar(value=AUTO)
        self.allow_crc = tk.BooleanVar(value=False)
        self.static_only = tk.BooleanVar(value=False)
        self.advanced_visible = False
        self.advanced_window: tk.Toplevel | None = None
        self._build()
        self.root.after(100, self._drain)

    def _build(self) -> None:
        outer = ttk.Frame(self.root, padding=20)
        outer.pack(fill="both", expand=True)
        title = tk.Label(outer, text=T("OWOTS 普通 MOD → 独立衣橱 MOD", "OWOTS normal MOD → standalone wardrobe MOD"), anchor="w",
                         bg=self.BG, fg=self.TEXT, font=("Segoe UI", 17, "bold"))
        title.pack(fill="x")
        subtitle = tk.Label(outer, text=T("支持松散目录和普通 KPKA PAK。原始游戏目录只读参考，不会被修改。", "Supports loose folders and plain KPKA PAKs. The original game directory is read-only and is never modified."),
                            anchor="w", bg=self.BG, fg=self.MUTED, font=("Segoe UI", 10))
        subtitle.pack(fill="x", pady=(4, 16))

        form = ttk.Frame(outer)
        form.pack(fill="x")
        self._path_row(form, 0, T("输入 MOD", "Input MOD"), "input", T("选择 MOD 文件夹或 .pak", "Choose a MOD folder or a .pak"), False)
        self._path_row(form, 1, T("输出目录", "Output folder"), "output", T("浏览时选择父目录，工具会建议新的子目录", "Pick a parent folder; a new subfolder is suggested"), True)
        self._path_row(form, 2, T("游戏原始安装目录", "Original game install"), "game", T("可选：Steam 游戏根目录（只读按需解包）", "Optional: Steam game root (read-only, unpacked on demand)"), False)

        basic = ttk.LabelFrame(outer, text=T("自动识别", "Auto-detect"), padding=10)
        basic.pack(fill="x", pady=(12, 0))
        self._labeled_combo(basic, 0, T("分类（可选）", "Category (optional)"), self.category,
                            (AUTO, "body", "cloak", "gauntlet", "weapon"), 28)
        ttk.Label(basic, text=T("普通 MOD 通常留“自动”；工具会按资源依赖选择 BODY/HEAD/HAIR 或武器部位。", "Normal MODs usually stay on Auto; the tool picks BODY/HEAD/HAIR or weapon parts from resource dependencies."),
                  foreground=self.MUTED).grid(row=1, column=0, columnspan=3, sticky="w", pady=(5, 0))

        self.advanced_toggle = ttk.Button(outer, text=T("显示高级选项 ▸", "Show advanced options ▸"), command=self._toggle_advanced)
        self.advanced_toggle.pack(fill="x", pady=(8, 0))

        actions = ttk.Frame(outer)
        actions.pack(fill="x", pady=(16, 8))
        self.inspect_button = ttk.Button(actions, text=T("只读检查", "Inspect (read-only)"), command=self.inspect)
        self.inspect_button.pack(side="left", padx=(0, 8), ipadx=12, ipady=4)
        self.convert_button = ttk.Button(actions, text=T("开始转换", "Start conversion"), command=self.convert)
        self.convert_button.pack(side="left", ipadx=12, ipady=4)
        self.status = tk.Label(actions, text=T("状态：等待输入", "Status: waiting for input"), anchor="e", bg=self.BG, fg=self.MUTED)
        self.status.pack(side="right", fill="x", expand=True)

        report_frame = ttk.LabelFrame(outer, text=T("诊断报告", "Diagnostics"), padding=8)
        report_frame.pack(fill="both", expand=True, pady=(4, 0))
        self.report = tk.Text(report_frame, wrap="word", height=12, state="disabled",
                              bg="#0d0f12", fg=self.TEXT, insertbackground=self.TEXT,
                              relief="flat", padx=10, pady=10)
        scrollbar = ttk.Scrollbar(report_frame, orient="vertical", command=self.report.yview)
        self.report.configure(yscrollcommand=scrollbar.set)
        self.report.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")
        self.root.bind("<Return>", lambda _event: self.convert() if not self.busy else None)

    def _toggle_advanced(self) -> None:
        if self.advanced_window is not None and self.advanced_window.winfo_exists():
            self.advanced_window.destroy()
            self.advanced_window = None
            self.advanced_visible = False
            self.advanced_toggle.configure(text=T("显示高级选项 ▸", "Show advanced options ▸"))
            return
        window = self.advanced_window = tk.Toplevel(self.root)
        self.advanced_visible = True
        window.title(T("OWOTS 衣橱转换器 · 高级选项", "OWOTS Wardrobe Converter · Advanced"))
        window.geometry("720x410")
        window.minsize(640, 360)
        window.configure(bg=self.BG)
        window.transient(self.root)
        options = ttk.LabelFrame(window, text=T("高级衣橱配置", "Advanced wardrobe configuration"), padding=12)
        options.pack(fill="both", expand=True, padx=12, pady=12)
        self._labeled_combo(options, 0, T("部位（可选）", "Part (optional)"), self.part,
                            (AUTO, "BODY", "BODY_SUB", "HEAD", "HAIR", "CLOAK", "GAUNTLET",
                             "WEAPON", "SHEATH", "WEAPON_SUB", "SHEATH_SUB", "BOW"), 28)
        self._text_row(options, 1, "MOD ID", "id", T("例如 scarlet.hat；留空自动生成", "e.g. scarlet.hat; blank auto-generates"))
        self._text_row(options, 2, T("原始 PFB", "Source PFB"), "prefab", T("mesh MOD 没有 PFB 时填写逻辑路径", "Logical path when a mesh MOD has no PFB"))
        self._text_row(options, 3, T("原始 catalog", "Source catalog"), "catalog", T("PlayerPartsList USER 逻辑路径", "PlayerPartsList USER logical path"))
        self._text_row(options, 4, T("原生 ID", "Native ID"), "native", T("目录多行时用于精确选择", "Used to pick the exact row when the catalog has several"))
        check = ttk.Checkbutton(options, text=T("实验：允许已报告 CRC mismatch 的结构化资源写回（报告会标记）", "Experimental: allow structured-resource write-back reported as CRC mismatch (flagged in the report)"),
                                variable=self.allow_crc)
        check.grid(row=5, column=0, columnspan=3, sticky="w", pady=(10, 0))
        static_check = ttk.Checkbutton(
            options,
            text=T("实验：接受静态转换（省略 Lua/原生插件，动态行为不等价）", "Experimental: accept static conversion (Lua/native plugins omitted; dynamic behavior is not equivalent)"),
            variable=self.static_only,
        )
        static_check.grid(row=6, column=0, columnspan=3, sticky="w", pady=(7, 0))

        def closed() -> None:
            self.advanced_visible = False
            self.advanced_window = None
            self.advanced_toggle.configure(text=T("显示高级选项 ▸", "Show advanced options ▸"))
            window.destroy()

        window.protocol("WM_DELETE_WINDOW", closed)
        self.advanced_toggle.configure(text=T("关闭高级选项 ▾", "Hide advanced options ▾"))

    def _path_row(self, parent: ttk.Frame, row: int, label: str, name: str,
                  hint: str, save: bool) -> None:
        ttk.Label(parent, text=label, width=14).grid(row=row, column=0, sticky="w", pady=5)
        entry = ttk.Entry(parent, textvariable=self.vars[name])
        entry.grid(row=row, column=1, sticky="ew", padx=(8, 8), pady=5, ipady=3)
        if name == "input":
            buttons = ttk.Frame(parent)
            buttons.grid(row=row, column=2, padx=(0, 6), pady=3)
            ttk.Button(buttons, text=T("选择 PAK", "Choose PAK"), command=self._browse_pak).pack(side="left", padx=(0, 4), ipady=2)
            ttk.Button(buttons, text=T("选择文件夹", "Choose folder"), command=self._browse_input_directory).pack(side="left", ipady=2)
        elif save:
            ttk.Button(parent, text=T("选择父目录", "Choose parent folder"), command=self._browse_output).grid(row=row, column=2,
                                                                                         padx=(0, 6), pady=5,
                                                                                         ipadx=8, ipady=2)
        else:
            ttk.Button(parent, text=T("浏览…", "Browse…"), command=lambda: self._browse_directory(name)).grid(row=row, column=2,
                                                                                                  padx=(0, 6), pady=5,
                                                                                                  ipadx=8, ipady=2)
        ttk.Label(parent, text=hint, foreground=self.MUTED).grid(row=row, column=3, sticky="w", pady=5)
        parent.grid_columnconfigure(1, weight=1)

    def _text_row(self, parent: ttk.Frame, row: int, label: str, name: str, hint: str) -> None:
        ttk.Label(parent, text=label, width=14).grid(row=row, column=0, sticky="w", pady=4)
        ttk.Entry(parent, textvariable=self.vars[name]).grid(row=row, column=1, sticky="ew", padx=(8, 8),
                                                              pady=4, ipady=2)
        ttk.Label(parent, text=hint, foreground=self.MUTED).grid(row=row, column=2, sticky="w", pady=4)
        parent.grid_columnconfigure(1, weight=1)

    def _labeled_combo(self, parent: ttk.Frame, row: int, label: str, variable: tk.StringVar,
                       values: tuple[str, ...], width: int) -> None:
        ttk.Label(parent, text=label, width=14).grid(row=row, column=0, sticky="w", pady=4)
        combo = ttk.Combobox(parent, textvariable=variable, values=values, state="readonly", width=width)
        combo.grid(row=row, column=1, sticky="w", padx=(8, 8), pady=4, ipady=2)

    def _browse_pak(self) -> None:
        value = filedialog.askopenfilename(
            title=T("选择普通 PAK MOD", "Choose a normal PAK MOD"),
            filetypes=((T("PAK 文件", "PAK files"), "*.pak"), (T("所有文件", "All files"), "*.*")),
        )
        if value:
            self.vars["input"].set(value)

    def _browse_input_directory(self) -> None:
        value = filedialog.askdirectory(title=T("选择已解包 MOD 文件夹", "Choose an unpacked MOD folder"))
        if value:
            self.vars["input"].set(value)

    def _browse_directory(self, name: str) -> None:
        value = filedialog.askdirectory(title=T("选择游戏原始安装目录（只读）", "Choose the original game install (read-only)"))
        if value:
            self.vars[name].set(value)

    def _browse_output(self) -> None:
        parent = filedialog.askdirectory(title=T("选择输出父目录；工具会创建新的子目录", "Choose the output parent folder; a new subfolder is created"))
        if not parent:
            return
        raw_name = self.vars["id"].get().strip() or Path(self.vars["input"].get().strip() or "converted-mod").stem
        child_name = mod_converter.safe_id(raw_name) + "-wardrobe"
        candidate = Path(parent) / child_name
        number = 2
        while candidate.exists():
            candidate = Path(parent) / f"{child_name}-{number}"
            number += 1
        self.vars["output"].set(str(candidate))

    def _set_report(self, text: str) -> None:
        self.report.configure(state="normal")
        self.report.delete("1.0", "end")
        self.report.insert("1.0", text)
        self.report.configure(state="disabled")

    def _args(self, command: str) -> argparse.Namespace:
        values = [command, "--input", self.vars["input"].get()]
        if command == "convert":
            values += ["--output", self.vars["output"].get()]
            optional = (("--id", "id"), ("--prefab", "prefab"), ("--catalog", "catalog"),
                        ("--native-id", "native"))
            selected_category = self.category.get().strip()
            selected_part = self.part.get().strip()
            if selected_category and selected_category != AUTO:
                values += ["--category", selected_category]
            if selected_part and selected_part != AUTO:
                values += ["--part", selected_part]
            for flag, name in optional:
                if self.vars[name].get().strip():
                    values += [flag, self.vars[name].get().strip()]
            if self.allow_crc.get():
                values.append("--allow-crc-mismatch")
            if self.static_only.get():
                values.append("--experimental-static-only")
        if self.vars["game"].get().strip():
            values += ["--game-root", self.vars["game"].get().strip()]
        return mod_converter.make_parser().parse_args(values)

    def inspect(self) -> None:
        self._start("inspect")

    def convert(self) -> None:
        self._start("convert")

    def _start(self, command: str) -> None:
        if self.busy:
            return
        if not self.vars["input"].get().strip():
            self._set_report(T("[错误] 请先选择输入 MOD 文件夹或 PAK。", "[Error] Choose an input MOD folder or PAK first."))
            self.status.configure(text=T("状态：缺少输入", "Status: input missing"), fg=self.ERROR)
            return
        try:
            # Capture every Tk variable on the UI thread.  The worker only
            # receives an immutable argparse Namespace and never touches Tk.
            args = self._args(command)
        except (SystemExit, ValueError, OSError) as error:
            self._set_report(T("[错误] 参数无效：", "[Error] Invalid arguments: ") + (str(error) or T("请检查输入", "check the input")))
            self.status.configure(text=T("状态：参数无效", "Status: invalid arguments"), fg=self.ERROR)
            return
        if command == "convert":
            if not str(getattr(args, "output", "")).strip():
                self._set_report(T("[错误] 请先选择一个新的输出目录。", "[Error] Choose a new output folder first."))
                self.status.configure(text=T("状态：缺少输出目录", "Status: output folder missing"), fg=self.ERROR)
                return
            input_path = args.input.resolve()
            output_path = args.output.resolve()
            if output_path.exists():
                self._set_report(T("[错误] 输出目录已存在，请用“选择父目录”生成新的子目录，或手动填写新路径。", "[Error] The output folder already exists; use Choose parent folder to create a subfolder, or enter a new path."))
                self.status.configure(text=T("状态：输出目录已存在", "Status: output folder exists"), fg=self.ERROR)
                return
            if output_path == input_path or output_path.is_relative_to(input_path):
                self._set_report(T("[错误] 输出目录不能与输入相同或位于输入目录内。", "[Error] The output folder must not equal or be inside the input folder."))
                self.status.configure(text=T("状态：输出路径无效", "Status: invalid output path"), fg=self.ERROR)
                return
        self.busy = True
        self.inspect_button.configure(state="disabled")
        self.convert_button.configure(state="disabled")
        self.status.configure(text=T("状态：正在检查/转换，请稍候…", "Status: inspecting/converting, please wait…"), fg=self.ACCENT)
        self._set_report(T("正在处理大型 PAK 或结构化资源，请不要关闭窗口…", "Processing a large PAK or structured resources; do not close the window…"))
        thread = threading.Thread(target=self._worker, args=(command, args), daemon=True)
        thread.start()

    def _worker(self, command: str, args: argparse.Namespace) -> None:
        try:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = mod_converter.run(args)
            output = stdout.getvalue() or stderr.getvalue()
            self.events.put(("done", (command, code, output)))
        except Exception as error:  # UI boundary: show an actionable error.
            self.events.put(("error", str(error)))

    def _drain(self) -> None:
        try:
            while True:
                kind, value = self.events.get_nowait()
                self.busy = False
                self.inspect_button.configure(state="normal")
                self.convert_button.configure(state="normal")
                if kind == "done":
                    command, code, output = value  # type: ignore[misc]
                    self._set_report(readable_report(str(output)))
                    if code == 0 and command == "inspect":
                        self.status.configure(text=T("状态：只读检查完成，未生成可安装包", "Status: inspection complete; no installable package was produced"), fg=self.OK)
                    elif code == 0:
                        self.status.configure(text=T("状态：完成，可把输出目录内容合并到游戏目录", "Status: done; merge the output folder into the game directory"), fg=self.OK)
                    else:
                        self.status.configure(text=T("状态：已阻止，请按报告修正输入", "Status: blocked; fix the input as described by the report"), fg=self.ERROR)
                else:
                    self._set_report(T("[错误] ", "[Error] ") + str(value))
                    self.status.configure(text=T("状态：发生错误", "Status: error"), fg=self.ERROR)
        except queue.Empty:
            pass
        self.root.after(100, self._drain)


def smoke_test(argv: list[str]) -> int:
    parser = mod_converter.make_parser()
    args = parser.parse_args(["inspect", *argv])
    return mod_converter.run(args)


def gui_self_test() -> int:
    """Build every window off-screen and fail loudly if the interface cannot start.

    The release EXE is windowed, so a startup exception is invisible to the build
    script without an explicit check.  This catches module-level and widget
    construction regressions (and frozen-build data problems) before shipping.
    """
    try:
        root = tk.Tk()
        root.withdraw()
        window = ConverterWindow(root)
        window.vars["input"].set(str(Path.cwd() / "gui-self-test.pak"))
        window.vars["output"].set(str(Path.cwd() / "gui-self-test-output"))
        automatic = window._args("convert")
        if automatic.category is not None or automatic.part is not None:
            raise AssertionError("the Auto sentinel leaked into the CLI arguments")
        window.category.set("body")
        selected = window._args("convert")
        if selected.category != "body" or selected.part is not None:
            raise AssertionError("the selected category did not reach the CLI arguments")
        window._toggle_advanced()
        window._toggle_advanced()
        root.destroy()
    except Exception as error:  # Build gate: report the reason instead of a traceback dialog.
        print(f"GUI self-test failed: {error}")
        return 1
    print("GUI self-test OK")
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "--cli":
        try:
            args = mod_converter.make_parser().parse_args(argv[1:])
        except SystemExit as error:
            return int(error.code or 0)
        return mod_converter.run(args)
    if argv and argv[0] == "--smoke-test":
        return smoke_test(argv[1:])
    if argv and argv[0] == "--self-test":
        return gui_self_test()
    root = tk.Tk()
    # ttk's default theme keeps native keyboard/focus behavior; only colors
    # and spacing are customized for readable dark-mode contrast.
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass
    style.configure("TFrame", background=ConverterWindow.BG)
    style.configure("TLabelframe", background=ConverterWindow.PANEL, foreground=ConverterWindow.TEXT)
    style.configure("TLabelframe.Label", background=ConverterWindow.PANEL, foreground=ConverterWindow.TEXT)
    style.configure("TLabel", background=ConverterWindow.PANEL, foreground=ConverterWindow.TEXT)
    style.configure("TButton", padding=(12, 7), foreground=ConverterWindow.TEXT, background="#2b4055")
    style.map("TButton", background=[("active", ConverterWindow.ACCENT)])
    style.configure("TEntry", fieldbackground="#0d0f12", foreground=ConverterWindow.TEXT)
    style.configure("TCombobox", fieldbackground="#0d0f12", background="#0d0f12",
                    foreground=ConverterWindow.TEXT, arrowcolor=ConverterWindow.TEXT)
    style.map("TCombobox",
              fieldbackground=[("readonly", "#0d0f12"), ("focus", "#161b22")],
              background=[("readonly", "#0d0f12"), ("active", "#243243")],
              foreground=[("readonly", ConverterWindow.TEXT), ("disabled", ConverterWindow.MUTED)])
    ConverterWindow(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
