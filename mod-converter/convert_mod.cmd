@echo off
setlocal EnableExtensions
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
echo OWOTS 普通 MOD 到衣橱 MOD 转换器
echo.
set "INPUT="
set /p "INPUT=输入 MOD 文件夹或 .pak 路径: "
if not defined INPUT (
  echo [错误] 必须提供输入路径。
  exit /b 2
)
set "OUTPUT="
set /p "OUTPUT=新的输出目录（不能已存在）: "
if not defined OUTPUT (
  echo [错误] 必须提供输出目录。
  exit /b 2
)
set "GAME="
set /p "GAME=原始游戏目录或已解包 natives/stm（可留空）: "
set "RUNNER="
where py >nul 2>nul
if %errorlevel%==0 set "RUNNER=py -3"
if not defined RUNNER (
  where python >nul 2>nul
  if %errorlevel%==0 set "RUNNER=python"
)
if not defined RUNNER (
  echo [错误] 未找到 Python 3。请安装 Python 3.10+，或使用发行版 EXE。
  exit /b 2
)
if defined GAME (
  %RUNNER% "%SCRIPT_DIR%mod_converter.py" convert --input "%INPUT%" --output "%OUTPUT%" --game-root "%GAME%"
) else (
  %RUNNER% "%SCRIPT_DIR%mod_converter.py" convert --input "%INPUT%" --output "%OUTPUT%"
)
set "CODE=%errorlevel%"
echo.
if not "%CODE%"=="0" echo 转换被阻止。请打开输出目录中的 conversion-report.json 和 CONVERSION-REPORT.md。
if "%CODE%"=="0" echo 转换完成。把输出目录内容合并到游戏目录后，在衣橱菜单中刷新。
exit /b %CODE%
