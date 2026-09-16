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
from pathlib import Path
import queue
import sys
import threading
import tkinter as tk
from tkinter import filedialog, ttk

import mod_converter


def readable_report(output: str) -> str:
    """Put actionable results before the many per-resource inventory records."""
    try:
        value = json.loads(output)
    except (ValueError, TypeError):
        return output
    if not isinstance(value, dict):
        return output
    status = value.get("status", "unknown")
    labels = {"converted": "转换完成", "inspected": "只读检查完成", "blocked": "已停止，需处理以下问题"}
    lines = [labels.get(status, str(status)), ""]
    urgent = [issue for issue in value.get("issues", []) if issue.get("severity") == "error"] if status == "blocked" else []
    for issue in urgent:
        lines += [f"[{issue.get('code', '')}] {issue.get('message', '')}", ""]
    stats = value.get("stats", {})
    if value.get("source"):
        lines += ["输入：" + value["source"], ""]
    for field, label in (("inputAssets", "输入资源"), ("graphNodes", "依赖资源"),
                         ("privateResources", "独立资源"), ("sharedResources", "复用游戏原始资源")):
        if field in stats:
            lines.append(f"{label}：{stats[field]}")
    parts = stats.get("autoPartDependencyChecks", {})
    if parts:
        lines.append("已验证部位：" + "、".join(sorted(parts)))
    for item in stats.get("texturePromotions", []):
        if item.get("promoted"):
            dimensions = item.get("streamingResolution", [])
            lines.append("高清纹理：" + " × ".join(map(str, dimensions)) + "，已完整保留")
    issues = value.get("issues", [])
    for severity, label in (("error", "错误"), ("warning", "注意")):
        if severity == "error" and urgent:
            continue
        selected = [issue for issue in issues if issue.get("severity") == severity]
        if selected:
            lines += ["", f"{label}（{len(selected)}）："]
        for issue in selected:
            lines.append(f"[{issue.get('code', '')}] {issue.get('message', '')}")
            if issue.get("path"):
                lines.append("  " + issue["path"])
    if status == "converted":
        lines += ["", "完整诊断保存在输出目录的 conversion-report.json 和 CONVERSION-REPORT.md。"]
    elif status == "inspected":
        lines += ["", "此步骤只检查输入；点击“开始转换”后才会从游戏读取依赖并验证完整转换。"]
    if stats.get("blockedReport"):
        lines += ["", "诊断目录：" + stats["blockedReport"]]
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
        root.title("OWOTS 衣橱 MOD 转换器")
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
        self.category = tk.StringVar(value="自动")
        self.part = tk.StringVar(value="自动")
        self.allow_crc = tk.BooleanVar(value=False)
        self.static_only = tk.BooleanVar(value=False)
        self.advanced_visible = False
        self.advanced_window: tk.Toplevel | None = None
        self._build()
        self.root.after(100, self._drain)

    def _build(self) -> None:
        outer = ttk.Frame(self.root, padding=20)
        outer.pack(fill="both", expand=True)
        title = tk.Label(outer, text="OWOTS 普通 MOD → 独立衣橱 MOD", anchor="w",
                         bg=self.BG, fg=self.TEXT, font=("Segoe UI", 17, "bold"))
        title.pack(fill="x")
        subtitle = tk.Label(outer, text="支持松散目录和普通 KPKA PAK。原始游戏目录只读参考，不会被修改。",
                            anchor="w", bg=self.BG, fg=self.MUTED, font=("Segoe UI", 10))
        subtitle.pack(fill="x", pady=(4, 16))

        form = ttk.Frame(outer)
        form.pack(fill="x")
        self._path_row(form, 0, "输入 MOD", "input", "选择 MOD 文件夹或 .pak", False)
        self._path_row(form, 1, "输出目录", "output", "浏览时选择父目录，工具会建议新的子目录", True)
        self._path_row(form, 2, "游戏原始安装目录", "game", "可选：Steam 游戏根目录（只读按需解包）", False)

        basic = ttk.LabelFrame(outer, text="自动识别", padding=10)
        basic.pack(fill="x", pady=(12, 0))
        self._labeled_combo(basic, 0, "分类（可选）", self.category,
                            ("自动", "body", "cloak", "gauntlet", "weapon"), 28)
        ttk.Label(basic, text="普通 MOD 通常留“自动”；工具会按资源依赖选择 BODY/HEAD/HAIR 或武器部位。",
                  foreground=self.MUTED).grid(row=1, column=0, columnspan=3, sticky="w", pady=(5, 0))

        self.advanced_toggle = ttk.Button(outer, text="显示高级选项 ▸", command=self._toggle_advanced)
        self.advanced_toggle.pack(fill="x", pady=(8, 0))

        actions = ttk.Frame(outer)
        actions.pack(fill="x", pady=(16, 8))
        self.inspect_button = ttk.Button(actions, text="只读检查", command=self.inspect)
        self.inspect_button.pack(side="left", padx=(0, 8), ipadx=12, ipady=4)
        self.convert_button = ttk.Button(actions, text="开始转换", command=self.convert)
        self.convert_button.pack(side="left", ipadx=12, ipady=4)
        self.status = tk.Label(actions, text="状态：等待输入", anchor="e", bg=self.BG, fg=self.MUTED)
        self.status.pack(side="right", fill="x", expand=True)

        report_frame = ttk.LabelFrame(outer, text="诊断报告", padding=8)
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
            self.advanced_toggle.configure(text="显示高级选项 ▸")
            return
        window = self.advanced_window = tk.Toplevel(self.root)
        self.advanced_visible = True
        window.title("OWOTS 衣橱转换器 · 高级选项")
        window.geometry("720x410")
        window.minsize(640, 360)
        window.configure(bg=self.BG)
        window.transient(self.root)
        options = ttk.LabelFrame(window, text="高级衣橱配置", padding=12)
        options.pack(fill="both", expand=True, padx=12, pady=12)
        self._labeled_combo(options, 0, "部位（可选）", self.part,
                            ("自动", "BODY", "BODY_SUB", "HEAD", "HAIR", "CLOAK", "GAUNTLET",
                             "WEAPON", "SHEATH", "WEAPON_SUB", "SHEATH_SUB", "BOW"), 28)
        self._text_row(options, 1, "MOD ID", "id", "例如 scarlet.hat；留空自动生成")
        self._text_row(options, 2, "原始 PFB", "prefab", "mesh MOD 没有 PFB 时填写逻辑路径")
        self._text_row(options, 3, "原始 catalog", "catalog", "PlayerPartsList USER 逻辑路径")
        self._text_row(options, 4, "原生 ID", "native", "目录多行时用于精确选择")
        check = ttk.Checkbutton(options, text="实验：允许已报告 CRC mismatch 的结构化资源写回（报告会标记）",
                                variable=self.allow_crc)
        check.grid(row=5, column=0, columnspan=3, sticky="w", pady=(10, 0))
        static_check = ttk.Checkbutton(
            options,
            text="实验：接受静态转换（省略 Lua/原生插件，动态行为不等价）",
            variable=self.static_only,
        )
        static_check.grid(row=6, column=0, columnspan=3, sticky="w", pady=(7, 0))

        def closed() -> None:
            self.advanced_visible = False
            self.advanced_window = None
            self.advanced_toggle.configure(text="显示高级选项 ▸")
            window.destroy()

        window.protocol("WM_DELETE_WINDOW", closed)
        self.advanced_toggle.configure(text="关闭高级选项 ▾")

    def _path_row(self, parent: ttk.Frame, row: int, label: str, name: str,
                  hint: str, save: bool) -> None:
        ttk.Label(parent, text=label, width=14).grid(row=row, column=0, sticky="w", pady=5)
        entry = ttk.Entry(parent, textvariable=self.vars[name])
        entry.grid(row=row, column=1, sticky="ew", padx=(8, 8), pady=5, ipady=3)
        if name == "input":
            buttons = ttk.Frame(parent)
            buttons.grid(row=row, column=2, padx=(0, 6), pady=3)
            ttk.Button(buttons, text="选择 PAK", command=self._browse_pak).pack(side="left", padx=(0, 4), ipady=2)
            ttk.Button(buttons, text="选择文件夹", command=self._browse_input_directory).pack(side="left", ipady=2)
        elif save:
            ttk.Button(parent, text="选择父目录", command=self._browse_output).grid(row=row, column=2,
                                                                                         padx=(0, 6), pady=5,
                                                                                         ipadx=8, ipady=2)
        else:
            ttk.Button(parent, text="浏览…", command=lambda: self._browse_directory(name)).grid(row=row, column=2,
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
            title="选择普通 PAK MOD",
            filetypes=(("PAK 文件", "*.pak"), ("所有文件", "*.*")),
        )
        if value:
            self.vars["input"].set(value)

    def _browse_input_directory(self) -> None:
        value = filedialog.askdirectory(title="选择已解包 MOD 文件夹")
        if value:
            self.vars["input"].set(value)

    def _browse_directory(self, name: str) -> None:
        value = filedialog.askdirectory(title="选择游戏原始安装目录（只读）")
        if value:
            self.vars[name].set(value)

    def _browse_output(self) -> None:
        parent = filedialog.askdirectory(title="选择输出父目录；工具会创建新的子目录")
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
            if selected_category and selected_category != "自动":
                values += ["--category", selected_category]
            if selected_part and selected_part != "自动":
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
            self._set_report("[错误] 请先选择输入 MOD 文件夹或 PAK。")
            self.status.configure(text="状态：缺少输入", fg=self.ERROR)
            return
        try:
            # Capture every Tk variable on the UI thread.  The worker only
            # receives an immutable argparse Namespace and never touches Tk.
            args = self._args(command)
        except (SystemExit, ValueError, OSError) as error:
            self._set_report("[错误] 参数无效：" + (str(error) or "请检查输入"))
            self.status.configure(text="状态：参数无效", fg=self.ERROR)
            return
        if command == "convert":
            if not str(getattr(args, "output", "")).strip():
                self._set_report("[错误] 请先选择一个新的输出目录。")
                self.status.configure(text="状态：缺少输出目录", fg=self.ERROR)
                return
            input_path = args.input.resolve()
            output_path = args.output.resolve()
            if output_path.exists():
                self._set_report("[错误] 输出目录已存在，请用“选择父目录”生成新的子目录，或手动填写新路径。")
                self.status.configure(text="状态：输出目录已存在", fg=self.ERROR)
                return
            if output_path == input_path or output_path.is_relative_to(input_path):
                self._set_report("[错误] 输出目录不能与输入相同或位于输入目录内。")
                self.status.configure(text="状态：输出路径无效", fg=self.ERROR)
                return
        self.busy = True
        self.inspect_button.configure(state="disabled")
        self.convert_button.configure(state="disabled")
        self.status.configure(text="状态：正在检查/转换，请稍候…", fg=self.ACCENT)
        self._set_report("正在处理大型 PAK 或结构化资源，请不要关闭窗口…")
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
                        self.status.configure(text="状态：只读检查完成，未生成可安装包", fg=self.OK)
                    elif code == 0:
                        self.status.configure(text="状态：完成，可把输出目录内容合并到游戏目录", fg=self.OK)
                    else:
                        self.status.configure(text="状态：已阻止，请按报告修正输入", fg=self.ERROR)
                else:
                    self._set_report("[错误] " + str(value))
                    self.status.configure(text="状态：发生错误", fg=self.ERROR)
        except queue.Empty:
            pass
        self.root.after(100, self._drain)


def smoke_test(argv: list[str]) -> int:
    parser = mod_converter.make_parser()
    args = parser.parse_args(["inspect", *argv])
    return mod_converter.run(args)


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
