"""Player UI; conversion decisions and resource reports belong to batch_converter."""
from __future__ import annotations
import contextlib
import io
import json
import os
from pathlib import Path
import queue
import re
import sys
import tempfile
import threading
import tkinter as tk
from tkinter import filedialog, ttk
from tkinterdnd2 import DND_FILES, TkinterDnD
from batch_converter import BatchConverter
from mod_converter import T


def describe_error(error):
    code = getattr(error, 'code', '')
    if code.startswith('ACTOR_SKELETON_'):
        return T('这个 Mod 修改了角色骨架，超出当前服装系统的支持范围，无法完整转换。', 'This mod changes the actor skeleton beyond the wardrobe system’s supported scope.')
    if code == 'ARCHIVE_READER_MISSING':
        return T('解压组件缺失，请重新解压转换器。', 'The archive reader is missing. Extract the converter package again.')
    if code == 'RSZ_TEMPLATE_CRC_OVERRIDE_REQUIRED' or code == 'RSZ_TEMPLATE_LAYOUT_MISMATCH':
        return T('暂时无法读取这个 Mod 使用的配置格式。请保留原 Mod，等待转换器更新。', 'This mod uses a configuration format the converter cannot read yet.')
    if code == 'RESOURCE_VERSION_UNSUPPORTED':
        return T('这个 Mod 的资源版本暂不受支持。', 'This mod uses an unsupported resource version.')
    return str(error)


def settings_path():
    return Path(os.environ.get('LOCALAPPDATA', Path.home()/'.config'))/'OWOTS-ModConverter'/'settings.json'


def discover_game():
    steam = []
    if os.name == 'nt':
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam') as key:
                steam.append(Path(winreg.QueryValueEx(key, 'SteamPath')[0]))
        except OSError: pass
    for base in (os.environ.get('ProgramFiles(x86)'), os.environ.get('ProgramFiles')):
        if base: steam.append(Path(base)/'Steam')
    libraries = list(steam)
    for directory in steam:
        manifest = directory/'steamapps/libraryfolders.vdf'
        try:
            if manifest.stat().st_size < 1024*1024:
                libraries.extend(Path(path.replace('\\\\', '\\')) for path in re.findall(r'"path"\s*"([^"]+)"', manifest.read_text(encoding='utf-8')))
        except OSError: pass
    for directory in libraries:
        game = directory/'steamapps/common/OnimushaWotS'
        if any(game.glob('re_chunk_*.pak')): return str(game)
    return ''


class App:
    def __init__(self, root, *, configuration=None, engine=BatchConverter):
        self.root, self.engine = root, engine
        self.configuration = configuration or settings_path()
        self.events, self.pending, self.rows = queue.Queue(), [], {}
        self.busy, self.closing = False, False
        self.cancelled = threading.Event()
        self.detail_windows = set()
        self.poll_id = None
        try:
            values = json.loads(self.configuration.read_text(encoding='utf-8'))
            if not isinstance(values, dict): values = {}
        except (OSError, ValueError): values = {}
        self.game = tk.StringVar(root, str(values.get('game', '')) or discover_game())
        output = str(values.get('output', ''))
        if values.get('version', 1) == 1 and output == str(Path.home()/'Documents'/'OWOTS Mods'):
            output = ''
        self.output = tk.StringVar(root, output)
        self.status, self.directory_error = tk.StringVar(root), tk.StringVar(root)
        self._build()
        root.protocol('WM_DELETE_WINDOW', self.close)
        root.bind('<Control-o>', lambda _: self.choose_files())
        root.bind('<Escape>', lambda _: self.cancel())
        self.poll_id = root.after(80, self._poll)

    def _build(self):
        root = self.root
        root.title(T('鬼武者 · Mod 转换器', 'Onimusha · Mod Converter'))
        root.geometry('860x640')
        root.minsize(700, 580)
        root.configure(bg='#f5f6f8')
        style = ttk.Style(root)
        style.theme_use('clam')
        style.configure('.', font=('Microsoft YaHei UI', 10), foreground='#1f2937', background='#f5f6f8')
        style.configure('TButton', padding=(14, 9), background='#ffffff', borderwidth=1)
        style.map('TButton', background=[('active', '#e9eef5'), ('disabled', '#edf0f3')])
        style.configure('Primary.TButton', foreground='#ffffff', background='#235db6', borderwidth=0)
        style.map('Primary.TButton', background=[('active', '#18488f'), ('disabled', '#91a6c5')])
        style.configure('TEntry', padding=8, fieldbackground='#ffffff')
        style.configure('Treeview', rowheight=38, background='#ffffff', fieldbackground='#ffffff', borderwidth=0)
        style.configure('Treeview.Heading', font=('Microsoft YaHei UI', 10, 'bold'), padding=9, background='#eef1f5')
        style.map('Treeview', background=[('selected', '#deebff')], foreground=[('selected', '#173a6a')])
        outer = ttk.Frame(root, padding=20)
        outer.pack(fill='both', expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(5, weight=1)
        ttk.Label(outer, text=T('Mod 转换器', 'Mod Converter'), font=('Microsoft YaHei UI', 22, 'bold')).grid(row=0, column=0, sticky='w', pady=(0, 12))
        directories = ttk.Frame(outer)
        directories.grid(row=1, column=0, sticky='ew')
        directories.columnconfigure(1, weight=1)
        self.directory_controls = []
        for row, (text, variable) in enumerate(((T('游戏目录', 'Game folder'), self.game), (T('输出目录（可选）', 'Output folder (optional)'), self.output))):
            ttk.Label(directories, text=text).grid(row=row, column=0, sticky='w', padx=(0, 14), pady=5)
            entry = ttk.Entry(directories, textvariable=variable)
            entry.grid(row=row, column=1, sticky='ew', pady=5)
            entry.bind('<FocusOut>', lambda _: self._directories_changed())
            entry.bind('<Return>', lambda _: self._directories_changed())
            button = ttk.Button(directories, text=T('选择…', 'Browse…'), command=lambda v=variable: self.choose_directory(v))
            button.grid(row=row, column=2, padx=(10, 0), pady=5)
            self.directory_controls.extend((entry, button))
        ttk.Label(outer, textvariable=self.directory_error, foreground='#a32924').grid(row=2, column=0, sticky='w')
        self.drop = tk.Frame(outer, bg='#ffffff', highlightbackground='#b8c6d9', highlightthickness=1, height=124)
        self.drop.grid(row=3, column=0, sticky='ew', pady=(8, 12))
        self.drop.pack_propagate(False)
        prompt = tk.Label(self.drop, text=T('把 Mod 拖到这里', 'Drop your mods here'), bg='#ffffff', fg='#253b5b', font=('Microsoft YaHei UI', 16, 'bold'))
        prompt.pack(pady=(15, 12))
        choices = tk.Frame(self.drop, bg='#ffffff')
        choices.pack()
        ttk.Button(choices, text=T('选择文件', 'Choose files'), style='Primary.TButton', command=self.choose_files).pack(side='left', padx=5)
        ttk.Button(choices, text=T('选择文件夹', 'Choose folder'), command=self.choose_folder).pack(side='left', padx=5)
        for target in (root, self.drop, prompt):
            target.drop_target_register(DND_FILES)
            target.dnd_bind('<<Drop>>', self.on_drop)
        result_bar = ttk.Frame(outer)
        result_bar.grid(row=4, column=0, sticky='ew', pady=(0, 8))
        ttk.Label(result_bar, text=T('转换结果', 'Results'), font=('Microsoft YaHei UI', 11, 'bold')).pack(side='left')
        self.clear_button = ttk.Button(result_bar, text=T('清空', 'Clear'), command=self.clear)
        self.clear_button.pack(side='right')
        tree_frame = ttk.Frame(outer)
        tree_frame.grid(row=5, column=0, sticky='nsew')
        self.tree = ttk.Treeview(tree_frame, columns=('name', 'result'), show='headings', selectmode='browse', height=1)
        self.tree.heading('name', text='Mod')
        self.tree.heading('result', text=T('结果', 'Result'))
        self.tree.column('name', width=440, minwidth=200)
        self.tree.column('result', width=210, minwidth=180, stretch=False)
        scroll = ttk.Scrollbar(tree_frame, orient='vertical', command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side='left', fill='both', expand=True)
        scroll.pack(side='right', fill='y')
        self.tree.bind('<<TreeviewSelect>>', lambda _: self._selection_changed())
        self.tree.bind('<Double-1>', lambda _: self.show_details())
        self.tree.bind('<Return>', lambda _: self.show_details())
        self.tree.tag_configure('error', foreground='#a32924')
        self.tree.tag_configure('warning', foreground='#86520b')
        self.progress = ttk.Progressbar(outer, mode='indeterminate')
        self.progress.grid(row=6, column=0, sticky='ew', pady=(10, 9))
        self.progress.grid_remove()
        bottom = ttk.Frame(outer)
        bottom.grid(row=7, column=0, sticky='ew', pady=(12, 0))
        ttk.Label(bottom, textvariable=self.status).pack(side='left')
        self.open_button = ttk.Button(bottom, text=T('打开位置', 'Open folder'), command=self.open_result, state='disabled')
        self.open_button.pack(side='right')
        self.details_button = ttk.Button(bottom, text=T('查看', 'View'), command=self.show_details, state='disabled')
        self.details_button.pack(side='right', padx=8)
        self.cancel_button = ttk.Button(bottom, text=T('取消', 'Cancel'), command=self.cancel, state='disabled')
        self.cancel_button.pack(side='right')

    def choose_directory(self, variable):
        path = filedialog.askdirectory(parent=self.root, initialdir=variable.get() or None)
        if path:
            variable.set(path)
            self._directories_changed()

    def choose_files(self):
        self.add_inputs(filedialog.askopenfilenames(parent=self.root, filetypes=[(T('Mod 文件', 'Mod files'), '*.zip *.rar *.7z *.pak')]))

    def choose_folder(self):
        path = filedialog.askdirectory(parent=self.root)
        if path: self.add_inputs([path])

    def on_drop(self, event):
        try: paths = self.root.tk.splitlist(event.data)
        except tk.TclError: return 'none'
        self.add_inputs(paths)
        return 'copy'

    def _directories_changed(self):
        if self.busy: return
        try:
            self.configuration.parent.mkdir(parents=True, exist_ok=True)
            staging = self.configuration.with_suffix('.tmp')
            staging.write_text(json.dumps({'version': 2, 'game': self.game.get(), 'output': self.output.get()}, ensure_ascii=False), encoding='utf-8')
            os.replace(staging, self.configuration)
        except OSError:
            self.directory_error.set(T('目录设置未能保存。', 'Folder settings could not be saved.'))
            return
        self._start()

    def add_inputs(self, paths):
        if self.closing: return
        for value in paths:
            path = Path(value)
            key = str(path.resolve()).casefold()
            if any(str(item['source'].resolve()).casefold() == key and item['state'] in ('waiting', 'running') for item in self.rows.values()): continue
            row = self.tree.insert('', 'end', values=(path.name, T('等待转换', 'Waiting')))
            self.rows[row] = {'source': path, 'state': 'waiting', 'result': None, 'error': None}
            self.pending.append(row)
        self._start()

    def _start(self):
        if self.busy or not self.pending or self.closing: return
        if not self.game.get().strip() or not Path(self.game.get()).is_dir():
            self.directory_error.set(T('请选择游戏目录。', 'Choose the game folder.'))
            return
        self.directory_error.set('')
        # All Tk state is captured on the UI thread.
        game = Path(self.game.get())
        output = Path(self.output.get().strip()) if self.output.get().strip() else None
        batch = [(row, self.rows[row]['source']) for row in self.pending]
        self.pending.clear()
        self.busy = True
        self.cancelled.clear()
        for row, _ in batch: self.rows[row]['state'] = 'running'
        for widget in self.directory_controls: widget.configure(state='disabled')
        self.cancel_button.configure(state='normal')
        self.clear_button.configure(state='disabled')
        self.progress.grid()
        self.progress.start(15)
        threading.Thread(target=self._work, args=(batch, game, output), daemon=True).start()

    def _work(self, batch, game, output):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                with self.engine(game, progress=lambda text: self.events.put(('progress', text)), cancelled=self.cancelled.is_set) as engine:
                    for row, source in batch:
                        if self.cancelled.is_set():
                            self.events.put(('cancelled', row))
                            continue
                        self.events.put(('running', row))
                        try: self.events.put(('result', row, engine.convert(source, output)))
                        except Exception as error:
                            if getattr(error, 'code', '') == 'CANCELLED': self.events.put(('cancelled', row))
                            else: self.events.put(('error', row, describe_error(error)))
            except Exception as error:
                for row, _ in batch: self.events.put(('error', row, describe_error(error)))
            finally: self.events.put(('done',))

    def _poll(self):
        while True:
            try: event = self.events.get_nowait()
            except queue.Empty: break
            kind = event[0]
            if kind == 'progress': self.status.set(event[1])
            elif kind == 'done':
                self.busy = False
                self.progress.stop()
                self.progress.grid_remove()
                self.progress.configure(value=0)
                self.status.set('')
                self.cancel_button.configure(state='disabled')
                self.clear_button.configure(state='normal')
                for widget in self.directory_controls: widget.configure(state='normal')
                if self.closing:
                    self._destroy()
                    return
                self._start()
            elif event[1] in self.rows:
                row, item = event[1], self.rows[event[1]]
                if kind == 'running':
                    self.tree.set(row, 'result', T('正在转换…', 'Converting…'))
                    self.tree.selection_set(row)
                elif kind == 'result':
                    result = event[2]
                    item.update(state='done', result=result)
                    label = T(f'已转换 · {len(result.entries)} 项', f'Converted · {len(result.entries)} items')
                    if result.notices: label += T(' · 需测试', ' · Test in game')
                    self.tree.set(row, 'result', label)
                    self.tree.item(row, tags=('warning',) if result.notices else ())
                elif kind == 'error':
                    item.update(state='error', error=event[2])
                    self.tree.set(row, 'result', T('未转换 · 查看原因', 'Failed · View reason'))
                    self.tree.item(row, tags=('error',))
                elif kind == 'cancelled':
                    item['state'] = 'cancelled'
                    self.tree.set(row, 'result', T('已取消', 'Cancelled'))
        self._selection_changed()
        self.poll_id = self.root.after(80, self._poll)

    def selected(self):
        rows = self.tree.selection()
        return self.rows.get(rows[0]) if rows else None

    def _selection_changed(self):
        selected = self.selected()
        self.open_button.configure(state='normal' if selected and selected.get('result') else 'disabled')
        self.details_button.configure(state='normal' if selected and (selected.get('result') or selected.get('error')) else 'disabled')

    def open_result(self):
        selected = self.selected()
        if selected and selected.get('result'):
            path = Path(selected['result'].output)
            if path.is_file(): os.startfile(str(path.parent))
            elif path.is_dir(): os.startfile(str(path))

    def show_details(self):
        item = self.selected()
        if not item or not (item.get('result') or item.get('error')): return
        window = tk.Toplevel(self.root)
        window.title(item['source'].name)
        window.geometry('670x410')
        window.minsize(500, 280)
        self.detail_windows.add(window)
        window.bind('<Destroy>', lambda event: self.detail_windows.discard(window) if event.widget == window else None)
        frame = ttk.Frame(window, padding=20)
        frame.pack(fill='both', expand=True)
        text = tk.Text(frame, wrap='word', font=('Microsoft YaHei UI', 10), padx=14, pady=12, relief='flat', bg='#ffffff', fg='#1f2937')
        scrollbar = ttk.Scrollbar(frame, command=text.yview)
        text.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side='right', fill='y')
        text.pack(fill='both', expand=True)
        lines = []
        if item.get('error'): lines.append(item['error'])
        else:
            result = item['result']
            for notice in result.notices:
                lines.extend([notice.message, ''])
                lines.extend(notice.paths[:20])
                if len(notice.paths) > 20: lines.append(T(f'另有 {len(notice.paths)-20} 项，详见输出报告。', f'{len(notice.paths)-20} more items in the output report.'))
                lines.append('')
            lines.append(T('已转换', 'Converted'))
            lines.extend(entry['name'] for entry in result.entries)
        text.insert('1.0', '\n'.join(lines))
        text.configure(state='disabled')
        ttk.Button(window, text=T('关闭', 'Close'), command=window.destroy).pack(pady=(0, 16))
        window.bind('<Escape>', lambda _: window.destroy())

    def cancel(self):
        self.cancelled.set()
        for row in self.pending:
            self.rows[row]['state'] = 'cancelled'
            self.tree.set(row, 'result', T('已取消', 'Cancelled'))
        self.pending.clear()
        if self.busy: self.status.set(T('正在取消…', 'Cancelling…'))

    def clear(self):
        if self.busy: return
        for row in self.tree.get_children(): self.tree.delete(row)
        self.rows.clear()
        self.pending.clear()
        self._selection_changed()

    def close(self):
        if self.busy:
            self.closing = True
            self.cancel()
            self.root.withdraw()
        else: self._destroy()

    def _destroy(self):
        if self.poll_id:
            self.root.after_cancel(self.poll_id)
            self.poll_id = None
        for window in tuple(self.detail_windows): window.destroy()
        self.root.destroy()


def gui_self_test():
    import time
    from batch_converter import Result, Notice
    from types import SimpleNamespace
    class FakeEngine:
        def __init__(self, *args, **kwargs): self.progress = kwargs['progress']
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def convert(self, source, output):
            assert output is None, 'Blank output must reach the engine as automatic location'
            self.progress('test')
            return Result(str(source), str(source.parent/'Test-衣橱.zip'), [{'name': 'Test outfit'}], [Notice('TEST', 'Test issue')])
    with tempfile.TemporaryDirectory(prefix='owots-gui-test-') as temporary:
        root = TkinterDnD.Tk()
        root.withdraw()
        app = App(root, configuration=Path(temporary)/'settings.json', engine=FakeEngine)
        assert app.output.get() == ''
        app.game.set(temporary)
        app._directories_changed()
        assert app.configuration.is_file()
        assert json.loads(app.configuration.read_text(encoding='utf-8'))['output'] == ''
        app.on_drop(SimpleNamespace(data=root.tk.call('list', str(Path(temporary)/'Mod with spaces.zip'))))
        deadline = time.monotonic()+5
        while app.busy and time.monotonic()<deadline:
            root.update()
            time.sleep(.01)
        assert not app.busy and len(app.rows) == 1
        row = next(iter(app.rows))
        root.update()
        app.tree.selection_set(row)
        output_file = Path(app.rows[row]['result'].output)
        output_file.write_bytes(b'archive fixture')
        opened = []
        original_startfile = os.startfile
        try:
            os.startfile = lambda path: opened.append(Path(path))
            app.open_result()
            assert opened == [output_file.parent]
        finally:
            os.startfile = original_startfile
        app.show_details()
        assert len(app.detail_windows) == 1
        for window in tuple(app.detail_windows): window.destroy()
        root.update()
        assert not app.detail_windows
        app.rows[row].update(result=None, error='A missing resource')
        app.show_details()
        assert app.detail_windows
        app.clear()
        assert not app.rows
        app.close()
        for settings, expected in (
            ({'output': str(Path.home()/'Documents'/'OWOTS Mods')}, ''),
            ({'output': temporary}, temporary),
            ({'version': 2, 'output': ''}, ''),
        ):
            configuration = Path(temporary)/'settings.json'
            configuration.write_text(json.dumps(settings), encoding='utf-8')
            root = TkinterDnD.Tk()
            root.withdraw()
            app = App(root, configuration=configuration)
            assert app.output.get() == expected
            app.close()
        entered, release_first = threading.Event(), threading.Event()
        seen = []
        class QueueEngine(FakeEngine):
            def convert(self, source, output):
                assert output is None
                seen.append(source.name)
                if source.name == 'First Mod.zip':
                    entered.set()
                    assert release_first.wait(5), 'Batch append test timed out'
                if source.name == 'Broken Mod.rar':
                    raise ValueError('Unreadable mod fixture')
                return Result(str(source), str(source.parent/(source.name+'-衣橱.zip')), [{'name': source.name}])
        root = TkinterDnD.Tk()
        root.withdraw()
        app = App(root, configuration=Path(temporary)/'queue.json', engine=QueueEngine)
        app.game.set(temporary)
        names = ['First Mod.zip', 'Broken Mod.rar', '第三个 Mod 文件夹']
        paths = [str(Path(temporary)/name) for name in names]
        app.on_drop(SimpleNamespace(data=root.tk.call('list', *paths)))
        try:
            deadline = time.monotonic()+5
            while not entered.is_set() and time.monotonic()<deadline:
                root.update()
                time.sleep(.01)
            assert entered.is_set()
            later = str(Path(temporary)/'Later Mod.7z')
            app.on_drop(SimpleNamespace(data=root.tk.call('list', paths[0], later)))
            assert len(app.rows) == 4 and len(app.pending) == 1
        finally:
            release_first.set()
        deadline = time.monotonic()+5
        while app.busy and time.monotonic()<deadline:
            root.update()
            time.sleep(.01)
        assert not app.busy and not app.pending
        assert seen == names + ['Later Mod.7z']
        states = {item['source'].name: item['state'] for item in app.rows.values()}
        assert states == {name: 'error' if name == 'Broken Mod.rar' else 'done' for name in seen}
        app.close()
    return 0


def main():
    if '--self-test' in sys.argv: return gui_self_test()
    if len(sys.argv)>1 and sys.argv[1] == '--batch':
        import batch_converter
        return batch_converter.main(sys.argv[2:])
    if len(sys.argv)>1 and sys.argv[1] == '--cli':
        import mod_converter
        return mod_converter.run(mod_converter.make_parser().parse_args(sys.argv[2:]))
    root = TkinterDnD.Tk()
    app = App(root)
    if len(sys.argv)>1: root.after(150, lambda: app.add_inputs(sys.argv[1:]))
    root.mainloop()
    return 0


if __name__ == '__main__': raise SystemExit(main())
