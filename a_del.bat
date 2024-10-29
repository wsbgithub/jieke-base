@echo off
echo 正在删除所有 HTML 文件...
 for /r %f in (*.html) do del "%f"

echo 正在删除所有 MP3 文件...
 for /r %f in (*.mp3) do del "%f"

echo 文件删除完成。
pause
