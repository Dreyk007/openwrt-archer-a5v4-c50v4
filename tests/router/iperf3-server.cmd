@echo off
rem iperf3 server of the unattended router tests (autolab.sh): restarted after every test (-1),
rem so that a broken test cannot leave it stuck. Started with Windows by the task scheduler
rem (a task "iperf3-5203" at logon). Keep it next to iperf3.exe in C:\iperf3.
cd /d "%~dp0"
:loop
iperf3.exe -s -p 5203 -1
ping -n 2 127.0.0.1 >nul
goto loop
