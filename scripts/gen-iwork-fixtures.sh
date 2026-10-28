#!/bin/bash
# Creates iWork samples (and Office exports of them) with the locally installed
# Pages / Keynote / Numbers. Requires granting Automation permission on first run.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/fixtures/iwork"; OFF="$PWD/fixtures/office"
mkdir -p "$OUT" "$OFF"

osascript <<APPLESCRIPT
set outDir to "$OUT"
set offDir to "$OFF"
-- Pages: several pages of Chinese text
if not (do shell script "test -e " & quoted form of (outDir & "/sample.pages") & " && echo y || echo n") is "y" then
tell application id "com.apple.Pages"
    set d to make new document
    set body text of d to "Loupe iWork 测试文稿" & return & return
    repeat with i from 1 to 6
        set body text of d to (body text of d) & "第 " & i & " 章" & return & "这是第 " & i & " 章的正文。床前明月光，疑是地上霜。举头望明月，低头思故乡。" & return & return
        tell d to set body text to (body text) & (character id 12)
    end repeat
    save d in POSIX file (outDir & "/sample.pages")
    try
        with timeout of 60 seconds
            export d to POSIX file (offDir & "/from-pages.docx") as Microsoft Word
        end timeout
    end try
    close d saving no
end tell
end if
-- Keynote: three slides
tell application id "com.apple.Keynote"
    set k to make new document
    tell k
        set t to first slide
        tell t
            try
                set object text of default title item to "Loupe 演示"
                set object text of default body item to "第一页"
            end try
        end tell
        repeat with i from 2 to 3
            set s to make new slide
            tell s
                try
                    set object text of default title item to "第 " & i & " 页"
                end try
            end tell
        end repeat
    end tell
    save k in POSIX file (outDir & "/sample.key")
    try
        with timeout of 60 seconds
            export k to POSIX file (offDir & "/from-keynote.pptx") as Microsoft PowerPoint
        end timeout
    end try
    close k saving no
end tell
-- Numbers: a small table
tell application id "com.apple.Numbers"
    set n to make new document
    tell table 1 of sheet 1 of n
        set value of cell "A1" to "城市"
        set value of cell "B1" to "营业额"
        set value of cell "A2" to "上海"
        set value of cell "B2" to 12345
        set value of cell "A3" to "北京"
        set value of cell "B3" to 23456
    end tell
    save n in POSIX file (outDir & "/sample.numbers")
    try
        with timeout of 60 seconds
            export n to POSIX file (offDir & "/from-numbers.xlsx") as Microsoft Excel
        end timeout
    end try
    close n saving no
end tell
APPLESCRIPT
ls -la "$OUT" "$OFF"
