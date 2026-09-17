@echo off
rem 本文件以 GBK(936) 保存 —— 中文 Windows 的 cmd 原生码页，中文才不乱码。
rem 下面这行强制码页，防止控制台被人改成 65001 后中文变乱码。
chcp 936 >nul
setlocal
cd /d "%~dp0"

set P_PROTO=8123
set P_SHOT=8124

rem =====================================================================
rem  LumenEdit 原型预览 —— 一键起服务
rem
rem    start-preview.cmd          起服务并打开默认浏览器
rem    start-preview.cmd nobrowser  只起服务，不开浏览器
rem    start-preview.cmd stop     关掉这两个服务
rem    start-preview.cmd status   查看两个服务的运行状态（端口 / 进程 / HTTP）
rem
rem  说明：端口已在监听就**直接复用**，不会重复起进程。
rem        服务跑在各自的最小化窗口里，关掉那个窗口即停止。
rem =====================================================================

if /i "%~1"=="stop" goto do_stop
if /i "%~1"=="status" goto do_status

where python >nul 2>nul
if errorlevel 1 (
  echo.
  echo   [x] 找不到 python。请先安装 Python 并把它加进 PATH。
  echo.
  pause
  exit /b 1
)

echo.
echo   LumenEdit 原型预览
echo   ------------------------------------------------------------

call :ensure %P_PROTO% "prototype" "原型页面"
call :ensure %P_SHOT%  "shots"     "截图目录"

echo   ------------------------------------------------------------
echo.
echo     原型    http://127.0.0.1:%P_PROTO%/index.html
echo     截图    http://127.0.0.1:%P_SHOT%/
echo.
echo   ------------------------------------------------------------
echo   服务跑在各自的最小化窗口里；关掉那个窗口，或运行
echo       start-preview.cmd stop
echo   即可停止。
echo.

if /i "%~1"=="nobrowser" (
  echo   已跳过打开浏览器。
  echo.
  exit /b 0
)

start "" "http://127.0.0.1:%P_PROTO%/index.html"
echo   已打开默认浏览器。本窗口可以直接关掉（服务继续运行）。
echo.
pause >nul
exit /b 0


rem ---------------------------------------------------------------- 启动
:ensure
setlocal
set PT=%~1
set DIR=%~2
set NAME=%~3

call :listening %PT%
if not errorlevel 1 (
  echo   [=] %NAME% 已在端口 %PT% 运行，直接复用
  endlocal
  exit /b 0
)

echo   [^>] 启动 %NAME%（端口 %PT%，目录 %DIR%）...
pushd "%~dp0%DIR%"
start "LumenEdit preview %PT%" /min cmd /c "python -m http.server %PT% --bind 127.0.0.1"
popd

set /a TRY=0

:ensure_wait
set /a TRY+=1
call :listening %PT%
if not errorlevel 1 (
  echo   [v] %NAME% 就绪
  endlocal
  exit /b 0
)
if %TRY% geq 25 (
  echo   [!] %NAME% 5 秒内没起来，请手动检查（端口是否被占用 / python 是否可用）
  endlocal
  exit /b 1
)
ping -n 1 -w 200 127.0.0.1 >nul
goto ensure_wait


rem ------------------------------------------------------------ 停止服务
:do_stop
echo.
echo   LumenEdit 原型预览 - 停止服务
echo   ------------------------------------------------------------
call :kill %P_PROTO% "原型页面"
call :kill %P_SHOT%  "截图目录"
echo   ------------------------------------------------------------
echo.
pause
exit /b 0

:kill
setlocal
set PT=%~1
set NAME=%~2
call :listening %PT%
if errorlevel 1 (
  echo   [=] %NAME% 本来就没在跑（端口 %PT%）
  endlocal
  exit /b 0
)
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /c:"LISTENING" ^| findstr /c:":%PT% "') do (
  taskkill /f /pid %%p >nul 2>nul
)
echo   [x] 已停止 %NAME%（端口 %PT%）
endlocal
exit /b 0


rem ------------------------------------------------------------ 查看状态
:do_status
echo.
echo   LumenEdit 原型预览 - 运行状态
echo   ------------------------------------------------------------
call :show %P_PROTO% "index.html" "原型页面"
call :show %P_SHOT%  ""           "截图目录"
echo   ------------------------------------------------------------
echo   说明：HTTP 200 = 服务正常；000 / 超时 = 没起来或端口被占用。
echo         修复：双击 start-preview.cmd 重新拉起；或 stop 后再起。
echo.
exit /b 0

:show
setlocal
set PT=%~1
set SUB=%~2
set NAME=%~3

rem —— 端口是否在监听 + 是哪个进程 ——
set PID=
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /c:"LISTENING" ^| findstr /c:":%PT% "') do set PID=%%p
if "%PID%"=="" (
  echo   [x] %NAME%（端口 %PT%）: 未监听 —— 服务没起来
  endlocal
  exit /b 0
)
for /f "tokens=1" %%n in ('tasklist /fi "PID eq %PID%" /nh 2^>nul') do set PNAME=%%n
echo   [v] %NAME%  端口 %PT%  监听中   进程 %PNAME%（PID %PID%）

rem —— HTTP 是否真的可用（端口活着不代表页面能打开）——
rem 注意：set 不能写在 ( ) 块里 —— 右括号前的空格会混进变量值，
rem URL 尾部多个空格就会被 curl 判成 malformed（HTTP 000）。
set U=http://127.0.0.1:%PT%/%SUB%
if "%SUB%"=="" set U=http://127.0.0.1:%PT%/
curl -s -o nul -w "%%{http_code}" --max-time 5 "%U%" > "%TEMP%\le_http.txt" 2>nul
set /p HTTPCODE=<"%TEMP%\le_http.txt"
del "%TEMP%\le_http.txt" >nul 2>nul
if "%HTTPCODE%"=="200" (
  echo       HTTP %HTTPCODE%   %U%
) else (
  echo       HTTP %HTTPCODE%   %U%   [!] 异常
)
endlocal
exit /b 0


rem -------------------------------------------------- 端口是否已被监听
rem  返回码 0 = 在监听；1 = 没在监听
:listening
setlocal
netstat -ano | findstr /c:"LISTENING" | findstr /c:":%~1 " >nul
endlocal & exit /b %errorlevel%
