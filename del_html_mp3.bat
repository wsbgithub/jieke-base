@echo off
setlocal

:: 设置目标文件夹路径
set "target_folder=E:\source\jieke-base"

:: 删除所有 .html 文件
for /r "%target_folder%" %%f in (*.html) do (
    del "%%f"
    echo Deleted: %%f
)

:: 删除所有 .mp3 文件
for /r "%target_folder%" %%f in (*.mp3) do (
    del "%%f"
    echo Deleted: %%f
)

for /r "%target_folder%" %%f in (*.mp4) do (
    del "%%f"
    echo Deleted: %%f
)
for /r "%target_folder%" %%f in (*.m4a) do (
    del "%%f"
    echo Deleted: %%f
)
echo All .html and .mp3 files have been deleted.
endlocal
pause
